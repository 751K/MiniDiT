import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
import SwiftUI
@testable import MiniDiT

@main struct MultiBackupChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        let oldDefaults = defaults.persistentDomain(forName: domain)
        defer { if let oldDefaults { defaults.setPersistentDomain(oldDefaults, forName: domain) } else { defaults.removePersistentDomain(forName: domain) } }
        defaults.removePersistentDomain(forName: domain)
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-multi-backup-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = oldHistory }
        let card = root.appending(path: "card"), work = root.appending(path: "work")
        for path in ["DCIM/100MSDCF", "PRIVATE/M4ROOT/CLIP", "PRIVATE/M4ROOT/SUB"] { try fm.createDirectory(at: card.appending(path: path), withIntermediateDirectories: true) }
        let photo = Data(repeating: 0x41, count: 4096), video = Data(repeating: 0x42, count: 8192)
        try photo.write(to: card.appending(path: "DCIM/100MSDCF/MULTI001.JPG"))
        try video.write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/C0001.MP4"))
        try Data("<NonRealTimeMeta/>".utf8).write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/C0001M01.XML"))
        try Data(repeating: 0x43, count: 2048).write(to: card.appending(path: "PRIVATE/M4ROOT/SUB/C0001S03.MP4"))
        let targetRoots = ["A", "B", "C", "Disabled", "Changed"].map { root.appending(path: $0) }
        for path in targetRoots { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        let a = BackupDestination(name: "备份 A", root: targetRoots[0])
        let b = BackupDestination(name: "备份 B", root: targetRoots[1])
        let c = BackupDestination(name: "备份 C", root: targetRoots[2])
        let disabled = BackupDestination(name: "未启用", root: targetRoots[3], enabled: false)
        try fm.removeItem(at: c.root)
        let journalURL = root.appending(path: "journal.sqlite")
        let model = AppModel(startServices: false, journalURL: journalURL)
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.sessions = []; model.captureOneMode = .off; model.openAfterImport = .none
        model.sendToFCP = false; model.sendToResolve = false; model.importProxies = true
        model.autoRefresh = false; model.onlyNew = false; model.importContent = .all; model.mediaFilter = .init()
        model.photoFolderLayout = .session; model.videoFolderLayout = .session; model.splitVideoByRoll = false
        model.destination = work; model.videoDestination = root.appending(path: "video-work")
        model.backupFollowsOrganization = true; model.backupEnabled = true
        model.backupTargets = [a, b, c, disabled]; model.deleteAfterImport = true
        // Exercise the same bindings and removal action used by the settings menu.
        let aControls = BackupTargetBindings(model: model, id: a.id)
        let bControls = BackupTargetBindings(model: model, id: b.id)
        let cControls = BackupTargetBindings(model: model, id: c.id)
        bControls.required.wrappedValue = false
        precondition(model.backupTargets[0].required && !model.backupTargets[1].required)
        bControls.remove()
        precondition(model.backupTargets.map(\.id) == [a.id, c.id, disabled.id])
        precondition(!bControls.enabled.wrappedValue && !bControls.required.wrappedValue)
        bControls.enabled.wrappedValue = true
        bControls.required.wrappedValue = true
        precondition(model.backupTargets.map(\.id) == [a.id, c.id, disabled.id], "stale controls must not recreate a removed target")
        aControls.remove()
        cControls.enabled.wrappedValue = false
        precondition(model.backupTargets[0].id == c.id && !model.backupTargets[0].enabled && !model.backupTargets[1].enabled)
        model.updateBackupTarget(c.id) { $0.name = "更名后" }
        precondition(model.backupTargets[0].name == "更名后")
        aControls.remove() // Repeated menu action after the row has disappeared.
        cControls.remove()
        BackupTargetBindings(model: model, id: disabled.id).remove()
        precondition(model.backupTargets.isEmpty && AppModel.loadBackupTargets().isEmpty)
        precondition(fm.fileExists(atPath: a.root.path) && fm.fileExists(atPath: b.root.path))
        model.backupTargets = [a, b, c, disabled]
        print("PASS: settings menu removes middle/first/last targets without exclusivity conflicts; retained row bindings follow IDs after index shifts, ignore removed rows, preserve other targets and directories, and persist the resulting list")
        model.sourceKind = .card; model.cardRoot = card; model.connectedName = "多目标检查卡"
        model.library = LocalCardLibrary(root: card)
        await model.loadAll()
        let project = model.createSession(day: "20261109", event: "多目标")
        precondition(!model.backupAvailable)
        model.backupTargets[2].required = false
        precondition(model.backupAvailable, "可选目标离线不能阻止普通导入")
        model.backupTargets[2].required = true
        let before = model.backupTargets.count
        model.addBackupTarget(a.root)
        precondition(model.backupTargets.count == before && model.errorMessage != nil)
        model.errorMessage = nil
        model.addBackupTarget(a.root.appending(path: "nested"))
        precondition(model.backupTargets.count == before)
        model.errorMessage = nil
        model.selectAll(in: Set(model.days.map(\.id)))
        precondition(model.selectedFiles().count == 2)
        model.beginImport(checkBackup: false)
        precondition(model.progress != nil)
        // Changes made after the task starts must apply only to later imports.
        model.backupTargets = [.init(name: "下一次", root: targetRoots[4])]
        model.backupEnabled = false
        try await wait { model.importTask == nil }
        var batch = try require(model.importJournal.records(for: project.id).first)
        precondition(batch.savedCount == 2 && batch.targets.map(\.id) == [a.id, b.id, c.id])
        precondition(batch.files.flatMap(\.assets).count == 4)
        precondition(batch.verifiedCount(for: a) == 4 && batch.verifiedCount(for: b) == 4 && batch.verifiedCount(for: c) == 0)
        precondition(batch.pendingBackupCount == 4 && !batch.requiredBackupsComplete)
        precondition(batch.files.flatMap(\.assets).allSatisfy { $0.error(for: c) != nil && $0.error(for: a) == nil && $0.error(for: b) == nil })
        precondition(!fm.fileExists(atPath: c.path), "离线目标不得被替代目录冒充")
        let disabledFiles = try fm.contentsOfDirectory(atPath: targetRoots[3].path)
        let changedFiles = try fm.contentsOfDirectory(atPath: targetRoots[4].path)
        precondition(disabledFiles.isEmpty && changedFiles.isEmpty)
        precondition(fm.fileExists(atPath: card.appending(path: "DCIM/100MSDCF/MULTI001.JPG").path), "必需备份失败时必须保留原片")
        precondition(model.lastResult?.needsAttention == true)
        precondition(model.lastResult?.backupTargets.map(\.verified) == [4, 4, 0])
        precondition(batch.reports.contains { $0.hasPrefix(a.path + "/") } && batch.reports.contains { $0.hasPrefix(b.path + "/") })
        let aCopies = batch.files.flatMap(\.assets).flatMap(\.copies).filter { $0.targetID == a.id }
        let bCopies = batch.files.flatMap(\.assets).flatMap(\.copies).filter { $0.targetID == b.id }
        for asset in batch.files.flatMap(\.assets) {
            for copy in asset.copies where copy.role == .backup {
                let digest = try await FileOps.hash(URL(filePath: copy.path))
                precondition(XXH64.hex(digest) == asset.xxh64)
            }
        }
        print("PASS: two independent target records complete photo/video/proxy/XML copies; third offline target fails alone; disabled target skipped; no replacement offline directory; required failure retains source; per-target MHL; frozen config; duplicate/nested roots rejected")
        let reportOptions = HandoffReport.Options(projectID: project.id, projectName: project.name, scope: "一次真实导入的隔离检查", preparedBy: "MiniDiT 检查", notes: "A、B 完成，C 离线。")
        let exportRoot = root.appending(path: "handoff-exports")
        try fm.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        let firstReport = try HandoffReport.snapshot(batches: [batch], options: reportOptions)
        let firstReportURL = try HandoffPackage.write(firstReport, to: exportRoot)
        let firstReportData = try Data(contentsOf: firstReportURL.appending(path: "manifest.json"))
        let reportDecoder = JSONDecoder(); reportDecoder.dateDecodingStrategy = .iso8601
        let exportedReport = try reportDecoder.decode(HandoffReport.self, from: firstReportData)
        precondition(exportedReport.needsAttention && exportedReport.assetCount == 4 && exportedReport.rows.count == 16)
        precondition(exportedReport.targets.first { $0.id == c.id.uuidString }?.pending == 4)
        precondition(exportedReport.rows.contains { $0.media == "video" && !$0.roll.isEmpty })
        precondition(exportedReport.rows.contains { $0.assetKind == "metadata" && $0.filename.hasSuffix(".XML") && $0.importItemFilename == "C0001.MP4" })
        precondition(exportedReport.manifests.allSatisfy { $0.status == "included" })
        if CommandLine.arguments.contains("--render") {
            let samples = URL(filePath: "/tmp/minidit-handoff-samples")
            try fm.createDirectory(at: samples, withIntermediateDirectories: true)
            try fm.copyItem(at: firstReportURL, to: samples.appending(path: firstReportURL.lastPathComponent))
            print("REPORT_SAMPLE: " + samples.appending(path: firstReportURL.lastPathComponent).path)
        }
        if CommandLine.arguments.contains("--render") {
            let configuration = model.backupTargets
            model.backupTargets = batch.targets + [disabled]
            try await render(model: model, project: project, app: app)
            model.backupTargets = configuration
        }
        // All working files and the card disappear; a different verified backup can repair C.
        try fm.removeItem(at: card)
        for copy in batch.files.flatMap(\.assets).flatMap(\.copies).filter({ $0.role == .working }) { try fm.removeItem(at: URL(filePath: copy.path)) }
        model.library = nil; model.phase = .idle
        model.importJournal = ImportJournalStore(url: journalURL)
        try fm.createDirectory(at: c.root, withIntermediateDirectories: true)
        model.importJournal.repair(batch.id, root: c.root, changeTarget: false, targetID: c.id)
        try await wait { model.importJournal.repairTask == nil }
        precondition(model.importJournal.repairErrors.isEmpty, model.importJournal.repairErrors.joined(separator: ";"))
        batch = try require(model.importJournal.records(for: project.id).first)
        precondition(batch.pendingBackupCount == 0 && batch.requiredBackupsComplete && batch.verifiedCount(for: c) == 4)
        precondition(batch.files.flatMap(\.assets).flatMap(\.copies).filter { $0.targetID == a.id } == aCopies)
        precondition(batch.files.flatMap(\.assets).flatMap(\.copies).filter { $0.targetID == b.id } == bCopies)
        let repairedReport = try HandoffReport.snapshot(batches: [batch], options: reportOptions)
        let repairedReportURL = try HandoffPackage.write(repairedReport, to: exportRoot)
        precondition(repairedReportURL != firstReportURL)
        precondition(repairedReport.targets.first { $0.id == c.id.uuidString }?.pending == 0)
        let oldReportAfterRepair = try Data(contentsOf: firstReportURL.appending(path: "manifest.json"))
        precondition(oldReportAfterRepair == firstReportData)
        print("PASS: actual photo/video/proxy/XML handoff package includes per-target missing rows, real MHL history and persisted roll metadata; source-free repair generates a new snapshot and leaves old report untouched")
        // Retry is readback + verification, not a duplicate copy.
        let cCount = batch.files.flatMap(\.assets).flatMap(\.copies).filter { $0.targetID == c.id }.count
        model.importJournal.repair(batch.id, root: c.root, changeTarget: false, targetID: c.id)
        try await wait { model.importJournal.repairTask == nil }
        batch = try require(model.importJournal.records(for: project.id).first)
        precondition(batch.files.flatMap(\.assets).flatMap(\.copies).filter { $0.targetID == c.id }.count == cCount)
        let extraRoot = root.appending(path: "Extra")
        try fm.createDirectory(at: extraRoot, withIntermediateDirectories: true)
        model.importJournal.repair(batch.id, root: extraRoot, changeTarget: true, addingTarget: true)
        try await wait { model.importJournal.repairTask == nil }
        batch = try require(model.importJournal.records(for: project.id).first)
        precondition(batch.targets.count == 4 && batch.pendingBackupCount == 0)
        let relocated = root.appending(path: "B-relocated")
        try fm.createDirectory(at: relocated, withIntermediateDirectories: true)
        model.importJournal.repair(batch.id, root: relocated, changeTarget: true, targetID: b.id)
        try await wait { model.importJournal.repairTask == nil }
        batch = try require(model.importJournal.records(for: project.id).first)
        precondition(batch.targets.first { $0.id == b.id }!.path == relocated.resolvingSymlinksInPath().path)
        precondition(batch.verifiedCount(for: batch.targets.first { $0.id == b.id }!) == 4)
        precondition(bCopies.allSatisfy { fm.fileExists(atPath: $0.path) }, "更换一个目标不能删除历史副本")
        print("PASS: restart preserves target identities/errors; no source card or work copy needed; repairs C from another verified backup; A/B facts unchanged; retry deduplicates; add fourth target; relocate only B and retain history")
        // Cancellation during a target copy must preserve working files and earlier verified targets.
        let cancelCard = root.appending(path: "cancel-card")
        try fm.createDirectory(at: cancelCard.appending(path: "DCIM/100MSDCF"), withIntermediateDirectories: true)
        let cancelFile = cancelCard.appending(path: "DCIM/100MSDCF/CANCEL001.JPG")
        try Data(repeating: 0x55, count: 128 * 1024 * 1024).write(to: cancelFile)
        let cancelA = root.appending(path: "cancel-A"), cancelB = root.appending(path: "cancel-B")
        try fm.createDirectory(at: cancelA, withIntermediateDirectories: true)
        try fm.createDirectory(at: cancelB, withIntermediateDirectories: true)
        let cancelModel = AppModel(startServices: false, journalURL: root.appending(path: "cancel.sqlite"))
        cancelModel.sessionRecordURL = root.appending(path: "cancel-projects.json")
        cancelModel.sessions = []; cancelModel.captureOneMode = .off; cancelModel.openAfterImport = .none
        cancelModel.autoRefresh = false; cancelModel.onlyNew = false; cancelModel.importContent = .photos
        cancelModel.sendToFCP = false; cancelModel.sendToResolve = false
        cancelModel.destination = root.appending(path: "cancel-work"); cancelModel.photoFolderLayout = .session
        cancelModel.backupEnabled = true; cancelModel.backupFollowsOrganization = true
        cancelModel.backupTargets = [.init(name: "先完成", root: cancelA), .init(name: "中途取消", root: cancelB)]
        cancelModel.deleteAfterImport = true
        cancelModel.sourceKind = .card; cancelModel.cardRoot = cancelCard; cancelModel.connectedName = "取消检查卡"
        cancelModel.library = LocalCardLibrary(root: cancelCard)
        await cancelModel.loadAll()
        let cancelProject = cancelModel.createSession(day: "20261109", event: "取消")
        cancelModel.selectAll(in: Set(cancelModel.days.map(\.id)))
        cancelModel.beginImport()
        for _ in 0..<3000 {
            if cancelModel.progress?.current.contains("中途取消") == true { cancelModel.cancelImport(); break }
            if cancelModel.importTask == nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try await wait { cancelModel.importTask == nil }
        let cancelled = try require(cancelModel.importJournal.records(for: cancelProject.id).first)
        precondition(cancelled.state == .cancelled && cancelled.savedCount == 1)
        precondition(cancelled.verifiedCount(for: cancelled.targets[0]) == 1)
        precondition(cancelled.pendingCount(for: cancelled.targets[1]) == 1)
        precondition(fm.fileExists(atPath: cancelFile.path))
        let workCopy = cancelled.files[0].assets[0].copies.first { $0.role == .working }!
        precondition(fm.fileExists(atPath: workCopy.path))
        print("PASS: cancel during second target keeps primary and first verified backup, records second pending, and retains original card file")

    }
    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<1500 { if done() { return }; try await Task.sleep(for: .milliseconds(20)) }
        fatalError("Multi-target operation timed out")
    }
    static func require<T>(_ value: T?) throws -> T { guard let value else { throw CocoaError(.fileReadCorruptFile) }; return value }
    @MainActor static func render(model: AppModel, project: ShootSession, app: NSApplication) async throws {
        let output = URL(filePath: "/tmp/minidit-multi-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for (name, host) in [
            ("targets", NSHostingView(rootView: AnyView(BackupSettings().environment(model).frame(width: 600, height: 560).preferredColorScheme(.light)))),
            ("targets-dark", NSHostingView(rootView: AnyView(BackupSettings().environment(model).frame(width: 600, height: 560).preferredColorScheme(.dark)))),
            ("results", NSHostingView(rootView: AnyView(ProjectImportResults(project: project).environment(model).preferredColorScheme(.light)))),
            ("export", NSHostingView(rootView: AnyView(HandoffExportSheet(project: project, records: model.importJournal.records(for: project.id), selectedBatch: model.importJournal.records(for: project.id).first?.id).preferredColorScheme(.light))))
        ] as [(String, NSView)] {
            let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: name.hasPrefix("targets") ? 600 : 1000, height: name.hasPrefix("targets") ? 560 : 800), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            if name == "export" { window.setContentSize(host.fittingSize) }
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: name + ".png"))
            window.orderOut(nil)
        }
    }
}
