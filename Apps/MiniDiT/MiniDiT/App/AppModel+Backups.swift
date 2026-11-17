import Foundation
import MiniDiTCore
import SonyRemoteKit

struct BackupTargetProgress: Identifiable {
    let target: BackupDestination
    var id: UUID { target.id }
    var verified = 0
    var failed = 0
    var total = 0
    var copying = false
}

extension AppModel {
    static func loadBackupTargets() -> [BackupDestination] {
        if let data = UserDefaults.standard.data(forKey: "backupDestinations"),
           let targets = try? JSONDecoder().decode([BackupDestination].self, from: data) { return targets }
        // Preserve this installation's configured location when introducing the target list.
        guard let root = UserDefaults.standard.url(forKey: "backupFolder") else { return [] }
        let result = [BackupDestination(name: root.lastPathComponent.isEmpty ? String(localized: "备份 \(1)") : root.lastPathComponent, root: root)]
        if let data = try? JSONEncoder().encode(result) { UserDefaults.standard.set(data, forKey: "backupDestinations") }
        return result
    }
    var enabledBackupTargets: [BackupDestination] { backupTargets.filter(\.enabled) }
    var missingRequiredBackupTargets: [BackupDestination] { enabledBackupTargets.filter { $0.required && $0.availability != .available } }
    var backupSummary: String {
        guard backupEnabled else { return String(localized: "未启用备份") }
        guard !enabledBackupTargets.isEmpty else { return String(localized: "尚未设置备份位置") }
        return enabledBackupTargets.map(\.name).joined(separator: String(localized: "、"))
    }
    func addBackupTarget(_ root: URL) {
        guard !backupTargets.contains(where: { BackupDestination.overlaps($0.root, root) }) else {
            errorMessage = String(localized: "备份位置相同或互相包含，请选择另一个独立位置。"); return
        }
        backupTargets.append(.init(name: root.lastPathComponent.isEmpty ? String(localized: "备份 \(backupTargets.count + 1)") : root.lastPathComponent, root: root))
    }
    func replaceBackupTarget(_ id: UUID, root: URL) {
        guard !backupTargets.contains(where: { $0.id != id && BackupDestination.overlaps($0.root, root) }),
              let index = backupTargets.firstIndex(where: { $0.id == id }) else {
            errorMessage = String(localized: "备份位置相同或互相包含，请选择另一个位置。"); return
        }
        let old = backupTargets[index]
        backupTargets[index] = .init(id: id, name: old.name, root: root, enabled: old.enabled, required: old.required)
    }
    /// Resolve by stable ID and commit a value copy so view callbacks cannot
    /// re-enter an array while one of its elements is being modified in place.
    func updateBackupTarget(_ id: UUID, _ update: (inout BackupDestination) -> Void) {
        var next = backupTargets
        guard let index = next.firstIndex(where: { $0.id == id }) else { return }
        update(&next[index])
        backupTargets = next
    }
    func removeBackupTarget(_ id: UUID) {
        var next = backupTargets
        guard next.contains(where: { $0.id == id }) else { return }
        next.removeAll { $0.id == id }
        backupTargets = next
    }
    var backupWorkRoots: [URL] {
        var roots: [URL] = []
        if importContent != .videos { roots.append(captureOneMode == .newSession ? sessionsFolder : destination) }
        if importContent != .photos { roots.append(videoDestination) }
        return roots
    }
    var backupDiskRoots: [URL] { backupWorkRoots + backupTargets.filter { $0.availability == .available }.map(\.root) }
    var backupDiskProbeKey: String {
        String(volumeVersion) + ":" + String(destinationVersion) + ":" + backupDiskRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }.sorted().joined(separator: "\n")
    }
    func refreshBackupDiskIdentities() async {
        let key = backupDiskProbeKey, roots = backupDiskRoots
        backupDiskIdentityKey = nil
        backupDiskIdentities = [:]
        let task = Task.detached(priority: .utility) { PhysicalDiskProbe.identities(for: roots) }
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, backupDiskProbeKey == key else { return }
        backupDiskIdentities = result
        backupDiskIdentityKey = key
    }
    func backupTargetNote(_ target: BackupDestination) -> String? {
        _ = volumeVersion
        switch target.availability {
        case .unavailable: return String(localized: "位置未连接")
        case .wrongVolume: return String(localized: "此位置的磁盘身份已变化，请重新选择")
        case .readOnly: return String(localized: "位置不可写入")
        case .available: break
        }
        let others = enabledBackupTargets.filter { $0.id != target.id && $0.availability == .available }
        // The cheap same-volume check remains useful before the hardware query completes.
        let sameWorkVolume = target.volumeID.map { volume in
            backupWorkRoots.contains { Self.volume(of: $0).flatMap(BackupRepair.volumeID(at:)) == volume }
        } ?? false
        let sameBackupVolume = target.volumeID.map { volume in others.contains { $0.volumeID == volume } } ?? false
        let volumeNote = sameWorkVolume ? String(localized: "与导入位置共用存储空间") : sameBackupVolume ? String(localized: "与其他备份位置共用存储空间") : nil
        guard backupDiskIdentityKey == backupDiskProbeKey else { return volumeNote }
        let identity = backupDiskIdentities[target.path] ?? .init()
        let work = backupWorkRoots.map { identity.relationship(to: backupDiskIdentities[$0.standardizedFileURL.resolvingSymlinksInPath().path] ?? .init()) }
        let backups = others.map { identity.relationship(to: backupDiskIdentities[$0.path] ?? .init()) }
        if work.contains(.shared) { return String(localized: "与导入位置位于同一块硬盘") }
        if backups.contains(.shared) { return String(localized: "与其他备份位置位于同一块硬盘") }
        if let volumeNote { return volumeNote }
        if work.contains(.unknown) || backups.contains(.unknown) { return String(localized: "无法确认是否与其他位置共用硬盘") }
        return nil
    }
    func updateBackupProgress(_ batchID: UUID, copying: UUID? = nil, final: Bool = false) {
        guard let batch = importJournal.batches.first(where: { $0.id == batchID }) else { return }
        if activeBackupBatchID != batchID || final {
            activeBackupBatchID = batchID
            let assets = batch.files.flatMap(\.assets)
            backupAssetIDs = Set(assets.map(\.id))
            for target in batch.targets {
                verifiedBackupAssets[target.id] = Set(assets.filter { $0.hasBackup(at: target) && $0.error(for: target) == nil }.map(\.id))
                failedBackupAssets[target.id] = Set(assets.filter { $0.error(for: target) != nil }.map(\.id))
            }
        }
        if final, !batch.targets.isEmpty, progress != nil {
            let count = batch.files.filter { file in
                file.state == .saved && !file.assets.isEmpty && file.assets.allSatisfy { asset in
                    batch.targets.allSatisfy { asset.hasBackup(at: $0) && asset.error(for: $0) == nil }
                }
            }.count
            progress?.backedUp = count
        }
        importBackupProgress = batch.targets.map { target in
            .init(target: target, verified: verifiedBackupAssets[target.id]?.count ?? 0,
                  failed: failedBackupAssets[target.id]?.count ?? 0,
                  total: max(batch.files.count, backupAssetIDs.count), copying: copying == target.id)
        }
    }
    /// Each target is independent. Only cancellation or a journal persistence failure stops the batch.
    func backupImportedFile(batchID: UUID, fileID: String, run: Bool) async {
        guard let batch = importJournal.batches.first(where: { $0.id == batchID }),
              let file = batch.files.first(where: { $0.id == fileID }) else { return }
        backupAssetIDs.formUnion(file.assets.map(\.id))
        guard run, !batch.targets.isEmpty else { updateBackupProgress(batchID); return }
        let worker = BackupRepair()
        for target in batch.targets {
            for original in file.assets {
                if Task.isCancelled || importJournal.persistenceError != nil { return }
                guard let current = importJournal.batches.first(where: { $0.id == batchID })?.files.first(where: { $0.id == fileID })?.assets.first(where: { $0.id == original.id }) else { continue }
                updateBackupProgress(batchID, copying: target.id)
                let name = current.copies.first.map { URL(filePath: $0.path).lastPathComponent } ?? file.filename
                progress?.current = String(localized: "备份至 \(target.name)：\(name)")
                let base = progress?.bytesDone ?? 0
                progress?.bytesTotal += current.size
                do {
                    let repaired = try await worker.repair(current, to: target.root, expectedVolume: target.volumeID, targetID: target.id,
                        progress: { count in Task { @MainActor in
                            if let value = self.progress?.bytesDone { self.progress?.bytesDone = max(value, base + count) }
                        } })
                    guard importJournal.update(batchID, { b in
                        if let f = b.files.firstIndex(where: { $0.id == fileID }), let a = b.files[f].assets.firstIndex(where: { $0.id == current.id }) { b.files[f].assets[a] = repaired }
                    }) else { importTask?.cancel(); return }
                    verifiedBackupAssets[target.id, default: []].insert(current.id)
                    failedBackupAssets[target.id]?.remove(current.id)
                    let completedBytes = max(progress?.bytesDone ?? 0, base + current.size)
                    progress?.bytesDone = completedBytes
                } catch is CancellationError { return }
                catch {
                    let message = error.localizedDescription
                    failedBackupAssets[target.id, default: []].insert(current.id)
                    verifiedBackupAssets[target.id]?.remove(current.id)
                    progress?.backupFailed.append("\(target.name)：\(name)")
                    log.add("备份失败 \(target.name)/\(name)：\(message)")
                    if !importJournal.update(batchID, { b in
                        if let f = b.files.firstIndex(where: { $0.id == fileID }), let a = b.files[f].assets.firstIndex(where: { $0.id == current.id }) {
                            if b.files[f].assets[a].targetErrors == nil { b.files[f].assets[a].targetErrors = [:] }
                            b.files[f].assets[a].targetErrors?[target.id.uuidString] = message
                        }
                    }) { importTask?.cancel(); return }
                }
                updateBackupProgress(batchID)
            }
        }
    }
}
