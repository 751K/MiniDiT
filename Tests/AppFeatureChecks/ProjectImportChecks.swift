import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
@testable import MiniDiT

@main struct ProjectImportChecks {
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
        let root = fm.temporaryDirectory.appending(path: "minidit-project-required-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = oldHistory }
        let card = root.appending(path: "card")
        let photoBytes = Data(repeating: 0x41, count: 1024)
        let videoBytes = Data(repeating: 0x42, count: 2048)
        for path in ["DCIM/100MSDCF", "PRIVATE/M4ROOT/CLIP"] {
            try fm.createDirectory(at: card.appending(path: path), withIntermediateDirectories: true)
        }
        try photoBytes.write(to: card.appending(path: "DCIM/100MSDCF/PROJECT001.JPG"))
        try videoBytes.write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/PROJECT001.MP4"))
        let model = AppModel(startServices: false, journalURL: root.appending(path: "journal.sqlite"))
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.captureOneMode = .off; model.openAfterImport = .none
        model.sendToFCP = false; model.sendToResolve = false; model.deleteAfterImport = false
        model.autoRefresh = false; model.onlyNew = false; model.importContent = .all
        model.photoFolderLayout = .session; model.videoFolderLayout = .session; model.splitVideoByRoll = false
        model.destination = root.appending(path: "photos")
        model.videoDestination = root.appending(path: "videos")
        model.sourceKind = .card; model.cardRoot = card; model.connectedName = "项目检查卡"
        model.library = LocalCardLibrary(root: card)
        model.backupEnabled = true; model.backupFolder = nil
        let existing = ShootSession(day: "20000101", name: "用户选定的项目")
        let other = ShootSession(day: "20000102", name: "另一项目")
        model.sessions = [existing, other]; model.currentSessionID = nil
        await model.loadAll()
        for mode in CaptureOneMode.allCases {
            model.captureOneMode = mode
            for scope in ImportContent.allCases {
                model.importContent = scope
                model.selectAll(in: Set(model.days.map(\.id)))
                let selection = model.grid.selected
                precondition(!selection.isEmpty)
                model.beginImport()
                precondition(model.newSessionPrompt?.importAfter == true)
                precondition(model.currentSession == nil && model.sessions.count == 2)
                precondition(model.progress == nil && model.importTask == nil && model.importJournal.batches.isEmpty)
                precondition(model.grid.selected == selection)
                precondition(!model.backupMissingPrompt && model.lightroomPrompt == nil,
                             "必须先选项目，不能先跳备份或后期软件提示")
                model.newSessionPrompt = nil  // 用户取消：不创建项目、不写文件。
                precondition(!fm.fileExists(atPath: model.destination.path))
                precondition(model.currentSessionJob() == nil, "自动导入也不能生成无项目任务")
            }
        }
        model.importContent = .all; model.captureOneMode = .off
        model.selectAll(in: Set(model.days.map(\.id)))
        let selected = model.selectedFiles()
        precondition(selected.count == 2)
        model.currentSessionID = UUID() // 已不存在的目标不能绕过检查。
        model.beginImport()
        precondition(model.newSessionPrompt?.importAfter == true && model.importTask == nil)
        model.newSessionPrompt = nil; model.currentSessionID = nil
        model.startImport(session: nil)
        precondition(model.newSessionPrompt?.importAfter == true && model.importTask == nil)
        model.newSessionPrompt = nil
        model.importToCurrentSession()
        precondition(model.newSessionPrompt?.importAfter == true && model.importTask == nil)
        model.newSessionPrompt = nil
        let orphan = AppModel.ImportJob(key: "all", files: selected, session: nil)
        let pending = AppModel.Interrupted(done: 0, total: selected.count, jobs: [orphan])
        model.interrupted = pending
        model.startImport(jobs: [orphan], grouping: .single)
        precondition(model.errorMessage != nil && model.importJournal.batches.isEmpty)
        precondition(model.interrupted != nil, "被拒绝的任务不能清掉原有续传状态")
        var invalid = orphan; invalid.appSession = UUID()
        model.errorMessage = nil
        model.startImport(jobs: [invalid], grouping: .single)
        precondition(model.errorMessage != nil && model.importTask == nil)
        model.errorMessage = nil; model.interrupted = nil

        // Finder 文件 promise 使用同一条 FileExport 路径，无需项目、不产生项目导入记录。
        let photo = selected.first { $0.kind == .jpeg }!
        let desktop = root.appending(path: "Desktop")
        try fm.createDirectory(at: desktop, withIntermediateDirectories: true)
        let exported = desktop.appending(path: photo.filename)
        try await FileExportQueue().write(FileExport(item: photo, library: model.library), to: exported)
        let exportedBytes = try Data(contentsOf: exported)
        precondition(exportedBytes == photoBytes && model.importJournal.batches.isEmpty)
        precondition(model.currentSession == nil && model.sessions.count == 2)
        print("PASS: all photo/video scopes and downstream modes require an explicit project; cancel keeps files/selection untouched; no anonymous low-level jobs; direct Finder export still works")

        model.currentSessionID = existing.id
        model.beginImport()
        precondition(model.backupMissingPrompt && model.newSessionPrompt == nil && model.importTask == nil,
                     "选好项目后仍必须经过备份检查")
        model.backupMissingPrompt = false; model.backupEnabled = false
        let frozenJob = model.currentSessionJob()!
        model.beginImport()
        try await wait { model.importTask == nil }
        let batch = model.importJournal.records(for: existing.id).first!
        precondition(batch.savedCount == 2 && batch.files.allSatisfy { $0.projectID == existing.id })
        precondition(model.sessions.first { $0.id == existing.id }!.files.count == 2)
        precondition(model.sessions.first { $0.id == other.id }!.files.isEmpty)
        precondition(fm.fileExists(atPath: model.destination.appending(path: existing.name + "/PROJECT001.JPG").path))
        precondition(fm.fileExists(atPath: model.videoDestination.appending(path: existing.name + "/PROJECT001.MP4").path))

        // 续传任务的项目已经显式冻结；侧栏切到另一项目也不能重定向它。
        model.currentSessionID = other.id
        model.interrupted = .init(done: 0, total: frozenJob.files.count, jobs: [frozenJob])
        model.continueImport()
        try await wait { model.importTask == nil }
        precondition(model.importJournal.records(for: other.id).isEmpty)
        precondition(model.importJournal.records(for: existing.id).count == 2)
        model.currentSessionID = existing.id
        model.removeSession(existing.id)
        precondition(model.currentSessionID == nil && model.sessions.map(\.id) == [other.id],
                     "移除所选项目后不能自动改选另一个项目")
        print("PASS: explicit project records photo/video files across dates; backup checks retained; resume keeps original project; removing target does not auto-select another")
    }

    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<600 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("Import timed out")
    }
}
