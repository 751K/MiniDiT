import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
import SwiftUI
@testable import MiniDiT

@main struct JournalChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            if let previous { defaults.setPersistentDomain(previous, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        defaults.removePersistentDomain(forName: domain)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "minidit-journal-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let originalHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = originalHistory }
        let journalURL = root.appending(path: "journal.json")
        let model = AppModel(startServices: false, journalURL: journalURL)
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.sessions = []
        model.captureOneMode = .off; model.openAfterImport = .none
        model.sendToFCP = false; model.sendToResolve = false
        model.importProxies = true; model.deleteAfterImport = false
        model.importContent = .all; model.onlyNew = false
        model.showPhotos = true; model.showRaw = true; model.showVideo = true
        model.autoRefresh = false; model.mediaFilter = .init()
        model.destination = root.appending(path: "photos")
        model.videoDestination = root.appending(path: "videos")
        model.photoFolderLayout = .session; model.videoFolderLayout = .session
        let target = root.appending(path: "backup")
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        model.backupFolder = target; model.backupEnabled = true
        model.backupFollowsOrganization = true
        let card = root.appending(path: "card")
        for path in ["DCIM/100MSDCF", "PRIVATE/M4ROOT/CLIP", "PRIVATE/M4ROOT/SUB"] {
            try fm.createDirectory(at: card.appending(path: path), withIntermediateDirectories: true)
        }
        let photo = Data(repeating: 0x41, count: 4096), video = Data(repeating: 0x42, count: 8192)
        try photo.write(to: card.appending(path: "DCIM/100MSDCF/JOURNAL001.JPG"))
        try video.write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        try Data("<NonRealTimeMeta/>".utf8).write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/C0001M01.XML"))
        try Data(repeating: 0x43, count: 2048).write(to: card.appending(path: "PRIVATE/M4ROOT/SUB/C0001S03.MP4"))
        model.sourceKind = .card; model.cardRoot = card; model.connectedName = "测试卡"
        model.library = LocalCardLibrary(root: card)
        await model.loadAll()
        let project = ShootSession(day: "20260101", event: "跨天项目", name: "跨天项目")
        model.sessions = [project]; model.currentSessionID = project.id
        model.selectAll(in: Set(model.days.map(\.id)))
        precondition(model.selectedFiles().count == 2)
        // User elected to import now and add the unavailable backup later.
        model.noBackupThisTime = true
        model.importToCurrentSession()
        try await wait { model.importTask == nil }
        let batch = try require(model.importJournal.records(for: project.id).first)
        precondition(batch.state == .completed && batch.savedCount == 2)
        precondition(batch.files.allSatisfy { file in
            guard let importedAt = file.importedAt, let finished = batch.finishedAt else { return false }
            return importedAt >= batch.startedAt && importedAt <= finished
        }, "每个成功文件都应记录其导入时间")
        let importTimes = batch.files.map(\.importedAt)
        precondition(batch.files.allSatisfy { $0.sourceIdentity?.kind == .directory && $0.sourceIdentity?.cardID != nil })
        let sourceIdentities = batch.files.map(\.sourceIdentity)
        precondition(batch.backupRequested && batch.backupRoot == target.path)
        precondition(batch.files.allSatisfy { file in
            guard let address = file.sourceAddress else { return false }
            return URL(filePath: address).resolvingSymlinksInPath().path.hasPrefix(card.resolvingSymlinksInPath().path + "/")
        })
        let sourceAddresses = batch.files.map(\.sourceAddress)
        precondition(batch.files.flatMap(\.assets).count == 4, "视频 XML 和代理必须逐文件记录")
        precondition(batch.files.flatMap(\.assets).allSatisfy { $0.copies.count == 1 })
        precondition(model.sessions[0].files.count == 2)
        let reopened = ImportJournalStore(url: journalURL)
        model.importJournal = reopened
        precondition(reopened.records(for: project.id).first == batch)
        try fm.removeItem(at: card)
        model.library = nil; model.phase = .idle
        // Resume with no source card; all four actual files must be copied and verified.
        reopened.repair(batch.id, root: target, changeTarget: false)
        try await wait { reopened.repairTask == nil }
        precondition(reopened.repairErrors.isEmpty, reopened.repairErrors.joined(separator: ";"))
        let repaired = try require(reopened.records(for: project.id).first)
        precondition(repaired.files.map(\.importedAt) == importTimes, "补备份不能改写导入时间")
        precondition(repaired.files.map(\.sourceAddress) == sourceAddresses, "原卡移除后仍应保留来源地址")
        precondition(repaired.files.map(\.sourceIdentity) == sourceIdentities, "补备份不改变来源身份快照")
        precondition(repaired.files.flatMap(\.assets).allSatisfy { $0.copies.contains { $0.role == .backup && $0.verifiedAt != nil } })
        for asset in repaired.files.flatMap(\.assets) {
            let backup = try require(asset.copies.last(where: { $0.role == .backup }))
            let hash = try await FileOps.hash(URL(filePath: backup.path))
            precondition(XXH64.hex(hash) == asset.xxh64)
        }
        precondition(!repaired.reports.isEmpty)
        let currentPhotos = ImportHistory.shared.records
        precondition(currentPhotos.allSatisfy { $0.backupPath != nil })
        // One unreadable/changed file must not erase the other successful copies.
        let damagedAsset = try require(repaired.files.flatMap(\.assets).first)
        let damagedWorking = URL(filePath: try require(damagedAsset.copies.first(where: { $0.role == .working })).path)
        let damagedBackup = URL(filePath: try require(damagedAsset.copies.first(where: { $0.role == .backup })).path)
        let unchangedBytes = try Data(contentsOf: damagedWorking)
        try fm.removeItem(at: damagedBackup)
        try Data(repeating: 0xFF, count: unchangedBytes.count).write(to: damagedWorking)
        reopened.repair(batch.id, root: target, changeTarget: false)
        try await wait { reopened.repairTask == nil }
        precondition(reopened.repairErrors.count == 1)
        let failedReload = ImportJournalStore(url: journalURL)
        precondition(failedReload.records(for: project.id)[0].pendingBackupCount == 1)
        precondition(failedReload.records(for: project.id)[0].files.flatMap(\.assets).filter { $0.backupError != nil }.count == 1)
        try unchangedBytes.write(to: damagedWorking)
        reopened.repair(batch.id, root: target, changeTarget: false)
        try await wait { reopened.repairTask == nil }
        precondition(reopened.repairErrors.isEmpty)
        precondition(reopened.records(for: project.id)[0].pendingBackupCount == 0)
        precondition(reopened.records(for: project.id)[0].files.map(\.importedAt) == importTimes, "再次核验不能改写导入时间")
        // A retry must not duplicate content, and an offline target must preserve successes.
        let copies = repaired.files.flatMap(\.assets).flatMap(\.copies).map(\.path)
        reopened.repair(batch.id, root: target, changeTarget: false)
        try await wait { reopened.repairTask == nil }
        precondition(reopened.records(for: project.id)[0].files.flatMap(\.assets).flatMap(\.copies).map(\.path) == copies)
        let disconnected = root.appending(path: "disconnected-backup")
        try fm.moveItem(at: target, to: disconnected)
        reopened.repair(batch.id, root: target, changeTarget: false)
        precondition(reopened.repairTask == nil && !reopened.repairErrors.isEmpty)
        precondition(!fm.fileExists(atPath: target.path))
        // A subsequent delivery receipt belongs to its persisted batch even after the UI changes.
        let nextID = UUID(); model.deliveryID = nextID
        model.updateDelivery("DaVinci Resolve", message: "此批次的软件接收结果", id: batch.id)
        precondition(model.deliveryMessages.isEmpty)
        precondition(model.importJournal.records(for: project.id)[0].delivery["DaVinci Resolve"] != nil)
        // A primary checkpoint happens before backup cancellation and survives it.
        let cancellationCard = root.appending(path: "cancel-card/DCIM/100MSDCF")
        try fm.createDirectory(at: cancellationCard, withIntermediateDirectories: true)
        try photo.write(to: cancellationCard.appending(path: "CANCEL001.JPG"))
        let cancellationLibrary = LocalCardLibrary(root: cancellationCard.deletingLastPathComponent().deletingLastPathComponent())
        let cancellationFolder = try await require(cancellationLibrary.folders().first)
        let cancellationHandle = try await require(cancellationLibrary.handles(in: cancellationFolder).first)
        let cancellationItem = try await cancellationLibrary.item(cancellationHandle)
        let cancelledPrimary = root.appending(path: "cancel-work")
        let cancelledBackup = root.appending(path: "cancel-backup")
        var primaryWasRecorded = false
        let cancellationImporter = FileImporter(library: cancellationLibrary, root: cancelledPrimary, camera: nil, backupRoot: cancelledBackup)
        let cancelledTask = Task { @MainActor in
            try await cancellationImporter.importItem(cancellationItem, into: cancelledPrimary,
                progress: { _ in }, stage: { _ in }, primarySaved: { url, _, _ in
                    primaryWasRecorded = fm.fileExists(atPath: url.path)
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do { _ = try await cancelledTask.value; fatalError("expected cancellation") }
        catch is CancellationError { }
        precondition(primaryWasRecorded && !fm.fileExists(atPath: cancelledBackup.path))
        // Crash recovery changes running to interrupted without fabricating success.
        let recovering = ImportJournalStore(url: root.appending(path: "interrupted.json"))
        var pending = ImportedFileRecord(id: "unfinished", projectID: project.id, filename: "missing.JPG", source: "测试卡")
        pending.state = .pending
        precondition(recovering.begin(.init(files: [pending], backupRequested: true, backupRoot: target.path)))
        let restored = ImportJournalStore(url: root.appending(path: "interrupted.json"))
        precondition(restored.batches[0].state == .interrupted && restored.batches[0].files[0].state == .pending)
        // Legacy migration is idempotent and leaves verification time unspecified.
        let legacy = ShootSession(day: "20260101", name: "旧项目", files: ["/tmp/old.JPG"])
        restored.includeLegacy(project: legacy, history: [])
        restored.includeLegacy(project: legacy, history: [])
        precondition(restored.records(for: legacy.id).count == 1)
        precondition(restored.records(for: legacy.id)[0].files[0].assets[0].copies[0].verifiedAt == nil)
        let corruptURL = root.appending(path: "corrupt.json")
        try Data("not valid json".utf8).write(to: corruptURL)
        let corrupt = ImportJournalStore(url: corruptURL)
        precondition(!corrupt.begin(batch))
        let preservedCorruptData = try Data(contentsOf: corruptURL)
        precondition(preservedCorruptData == Data("not valid json".utf8))
        let bulkURL = root.appending(path: "bulk.sqlite")
        let bulk = ImportJournalStore(url: bulkURL)
        let bulkBatch = ImportBatchRecord(files: (0..<5000).map { index in
            ImportedFileRecord(id: "bulk-\(index)", projectID: project.id, filename: "\(index).JPG", source: "批量测试")
        }, backupRequested: false, backupRoot: nil)
        precondition(bulk.begin(bulkBatch))
        let checkpointStart = Date()
        for index in 0..<50 {
            precondition(bulk.update(bulkBatch.id) { b in b.files[index].state = .failed; b.files[index].message = "测试异常" })
        }
        let bulkReload = ImportJournalStore(url: bulkURL)
        precondition(bulkReload.batches[0].files.count == 5000)
        precondition(bulkReload.batches[0].files.filter { $0.state == .failed }.count == 50)
        print("PASS: 5,000-file journal; 50 incremental checkpoints in \(Date().timeIntervalSince(checkpointStart)) seconds; reload preserved all records")
        print("PASS: real photo/video import; four files including proxy/XML; frozen backup intention; source-card-free repair; readback; repeat without duplication; unavailable target; delivery receipt isolation; restart recovery; legacy migration; corrupt journal preservation")
        if CommandLine.arguments.contains("--render") {
            try await render(project: model.sessions[0], model: model, root: URL(filePath: "/tmp/minidit-journal-ui"))
        }
    }

    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<1000 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("operation timed out")
    }
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    @MainActor static func render(project: ShootSession, model: AppModel, root: URL) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, width, appearance) in [("results", 880.0, NSAppearance.Name.aqua),
                                          ("results-minimum", 740.0, .aqua), ("results-dark", 880.0, .darkAqua)] {
            let host = NSHostingView(rootView: ProjectImportResults(project: project).environment(model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            precondition(abs(host.bounds.width - width) < 1, "结果页不能撑开最小窗口")
            let bitmap = try require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try require(bitmap.representation(using: .png, properties: [:])).write(to: root.appending(path: name + ".png"))
            window.orderOut(nil)
        }
        print("PASS: result layouts at minimum/default widths and dark appearance")
    }
}
