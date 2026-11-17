import Foundation
import MiniDiTCore
import Observation

@MainActor @Observable
final class ImportJournalStore {
    private(set) var batches: [ImportBatchRecord] = []
    private(set) var persistenceError: String?
    private var database: JournalDatabase?
    private var readable = true
    var repairTask: Task<Void, Never>?
    var repairingBatch: UUID?
    var repairingTarget: UUID?
    var lastRepairTarget: UUID?
    var repairProgress = ""
    var repairErrors: [String] = []
    var repairSummary: String?
    var lastRepairBatch: UUID?

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "\(LegacyMigration.supportFolder)/import-journal.sqlite")
    }

    init(url: URL) {
        do {
            let database = try JournalDatabase(url: url)
            self.database = database
            batches = try database.load().map { batch in
                var b = batch
                if b.state == .running { b.state = .interrupted }
                b.videoDeliveries = b.videoDeliveries?.map(\.recovered)
                for record in b.videoDeliveries ?? [] { b.delivery[record.software.name] = record.message }
                return b
            }
        } catch {
            readable = false
            persistenceError = String(localized: "无法读取导入记录，原记录已保留：\(error.localizedDescription)")
        }
    }

    func records(for project: UUID) -> [ImportBatchRecord] {
        batches.filter { $0.files.contains { $0.projectID == project } }.sorted { $0.startedAt > $1.startedAt }
    }

    @discardableResult
    func begin(_ batch: ImportBatchRecord) -> Bool {
        commit { $0.append(batch) }
    }

    @discardableResult
    func update(_ id: UUID, _ body: (inout ImportBatchRecord) -> Void) -> Bool {
        commit { all in
            guard let i = all.firstIndex(where: { $0.id == id }) else { return }
            body(&all[i])
        }
    }

    private func commit(_ body: (inout [ImportBatchRecord]) -> Void) -> Bool {
        guard readable else { return false }
        var next = batches
        body(&next)
        do {
            guard let database else { return false }
            try database.save(previous: batches, next: next)
            batches = next
            persistenceError = nil
            return true
        } catch {
            persistenceError = String(localized: "导入记录未能保存：\(error.localizedDescription)")
            return false
        }
    }

    /// Legacy records retain their old evidence and never acquire a fabricated check date.
    func includeLegacy(project: ShootSession, history: [ImportRecord]) {
        let represented = Set(records(for: project.id).flatMap(\.files).flatMap(\.assets).flatMap(\.copies).map(\.path))
        let historyByPath = Dictionary(history.compactMap { record in record.path.map { ($0, record) } }, uniquingKeysWith: { a, _ in a })
        let files = project.files.filter { !represented.contains($0) }.map { path in
            let old = historyByPath[path]
            var file = ImportedFileRecord(id: UUID().uuidString, projectID: project.id,
                                          filename: URL(filePath: path).lastPathComponent, source: old?.camera ?? "旧版导入")
            file.state = .saved
            let category = ProjectMedia.forPath(path).folderName
            var copies = [ImportedCopyRecord(role: .working, path: path, evidence: .legacy)]
            if let backup = old?.backupPath { copies.append(.init(role: .backup, path: backup, evidence: .legacy)) }
            file.assets = [.init(kind: .original, size: old?.size ?? 0, xxh64: old?.xxh64,
                                 backupRelativePath: category + "/" + project.id.uuidString + "/" + file.filename, copies: copies)]
            return file
        }
        guard !files.isEmpty else { return }
        var batch = ImportBatchRecord(files: files, backupRequested: false, backupRoot: nil, state: .legacy)
        batch.startedAt = project.created
        _ = begin(batch)
    }

    func repair(_ id: UUID, root: URL, changeTarget: Bool, targetID: UUID? = nil, addingTarget: Bool = false) {
        guard repairTask == nil, let batch = batches.first(where: { $0.id == id }), batch.state != .running else { return }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        lastRepairBatch = id; repairErrors = []; repairSummary = nil
        var targets = batch.targets
        if let targetID, !targets.contains(where: { $0.id == targetID }) { repairErrors = [String(localized: "备份目标不存在。")]; return }
        let previous = addingTarget ? nil : targets.first(where: { $0.id == targetID }) ?? targets.first
        let target: BackupDestination
        if let previous, !changeTarget {
            guard previous.path == root.path else { repairErrors = [String(localized: "请使用原备份位置，或明确选择更换位置。")]; return }
            target = previous
        } else {
            target = .init(id: previous?.id ?? UUID(), name: previous?.name ?? (root.lastPathComponent.isEmpty ? String(localized: "备份") : root.lastPathComponent),
                           root: root, required: previous?.required ?? true)
        }
        lastRepairTarget = target.id
        guard !targets.contains(where: { $0.id != target.id && BackupDestination.overlaps($0.root, root) }) else {
            repairErrors = [String(localized: "备份位置相同或互相包含，请选择另一个位置。")]; return
        }
        guard target.availability == .available else {
            repairErrors = [target.availability == .wrongVolume ? BackupRepair.Failure.wrongVolume.localizedDescription : BackupRepair.Failure.targetUnavailable.localizedDescription]
            return
        }
        if let index = targets.firstIndex(where: { $0.id == target.id }) { targets[index] = target } else { targets.append(target) }
        guard update(id, { b in
            if let first = batch.targets.first {
                for f in b.files.indices { for a in b.files[f].assets.indices {
                    if b.files[f].assets[a].targetErrors == nil, let error = b.files[f].assets[a].backupError {
                        b.files[f].assets[a].targetErrors = [first.id.uuidString: error]
                    }
                } }
            }
            b.backupRequested = true; b.backupTargets = targets
            b.backupRoot = targets.first?.path; b.backupVolumeID = targets.first?.volumeID
        }) else { return }
        repairingBatch = id; repairingTarget = target.id
        let worker = BackupRepair(), assets = batch.files.flatMap(\.assets)
        repairTask = Task {
            var completed = 0, verifiedEntries: [MHLWriter.Entry] = []
            for (offset, original) in assets.enumerated() {
                if Task.isCancelled { break }
                let asset = batches.first(where: { $0.id == id })?.files.flatMap(\.assets).first(where: { $0.id == original.id }) ?? original
                let filename = asset.copies.first.map { URL(filePath: $0.path).lastPathComponent } ?? String(localized: "文件")
                repairProgress = "\(target.name)：\(offset + 1)/\(assets.count) · \(filename)"
                do {
                    var repaired = try await worker.repair(asset, to: root, expectedVolume: target.volumeID, targetID: target.id)
                    if targets.first?.id == target.id { repaired.backupError = nil }
                    guard update(id, { b in
                        for f in b.files.indices {
                            if let a = b.files[f].assets.firstIndex(where: { $0.id == asset.id }) { b.files[f].assets[a] = repaired }
                        }
                    }) else { break }
                    if let working = repaired.copies.first(where: { $0.role == .working }),
                       let backup = repaired.copies.last(where: { $0.targetID == target.id && $0.role == .backup }) {
                        ImportHistory.shared.recordBackup(primaryPath: working.path, backup: URL(filePath: backup.path))
                    }
                    if let copy = repaired.copies.last(where: { $0.targetID == target.id && $0.role == .backup }),
                       let hash = repaired.xxh64.flatMap({ UInt64($0, radix: 16) }) {
                        verifiedEntries.append(.init(url: URL(filePath: copy.path), xxh64: hash, action: .verified))
                    }
                    completed += 1
                } catch is CancellationError { break }
                catch {
                    repairErrors.append("\(filename)：\(error.localizedDescription)")
                    if !update(id, { b in
                        for f in b.files.indices {
                            if let a = b.files[f].assets.firstIndex(where: { $0.id == asset.id }) {
                                if b.files[f].assets[a].targetErrors == nil { b.files[f].assets[a].targetErrors = [:] }
                                b.files[f].assets[a].targetErrors?[target.id.uuidString] = error.localizedDescription
                                if targets.first?.id == target.id { b.files[f].assets[a].backupError = error.localizedDescription }
                            }
                        }
                    }) { break }
                }
            }
            if !verifiedEntries.isEmpty {
                do {
                    guard target.availability == .available else { throw BackupRepair.Failure.targetUnavailable }
                    let report = try MHLWriter.append(root: root, entries: verifiedEntries)
                    _ = update(id) { b in b.reports.append(report.path); b.backupReportErrors?.removeValue(forKey: target.id.uuidString) }
                } catch {
                    repairErrors.append(String(localized: "校验清单未能保存：\(error.localizedDescription)"))
                    _ = update(id) { b in
                        if b.backupReportErrors == nil { b.backupReportErrors = [:] }
                        b.backupReportErrors?[target.id.uuidString] = error.localizedDescription
                    }
                }
            }
            repairSummary = Task.isCancelled
                ? String(localized: "\(target.name)：\(completed)/\(assets.count) 个文件已核对并完成备份；已取消，其余文件可稍后继续。")
                : String(localized: "\(target.name)：\(completed)/\(assets.count) 个文件已核对并完成备份。")
            repairingBatch = nil; repairingTarget = nil; repairProgress = ""; repairTask = nil
        }
    }
}
