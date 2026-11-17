import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
@testable import MiniDiT

/// 佳能的存储卡：照片（CR3 / CR2 / JPG / HIF）和视频（MP4 / MOV / CRM）都在 DCIM/100CANON 这类文件夹里，
/// 没有索尼的 M01.XML，也没有代理。
@main struct CanonCardChecks {
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
        let root = fm.temporaryDirectory.appending(path: "minidit-canon-card-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = oldHistory }

        let card = root.appending(path: "card")
        let dir = card.appending(path: "DCIM/100CANON")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: card.appending(path: "MISC"), withIntermediateDirectories: true)
        let files: [String: Data] = [
            "IMG_0001.CR3": Data(repeating: 0x41, count: 3072), "IMG_0001.JPG": Data(repeating: 0x42, count: 1024),
            "IMG_0002.CR2": Data(repeating: 0x43, count: 2048), "MVI_0003.MP4": Data(repeating: 0x44, count: 4096),
            "MVI_0004.CRM": Data(repeating: 0x45, count: 5120),
        ]
        for (name, data) in files { try data.write(to: dir.appending(path: name)) }
        try Data(repeating: 0, count: 64).write(to: card.appending(path: "MISC/CANONMSC.DAT"))

        precondition(LocalCardLibrary.looksLikeCard(card), "只有 DCIM 的佳能卡要被认成存储卡")
        let library = LocalCardLibrary(root: card)
        let folder = try await library.folders()[0]
        var items: [String: CameraContentItem] = [:]
        for h in try await library.handles(in: folder) { let i = try await library.item(h); items[i.filename] = i }
        precondition(Set(items.keys) == Set(files.keys), "卡上的佳能文件都要列出来：\(items.keys.sorted())")
        precondition(items["IMG_0001.CR3"]!.kind == .raw && items["IMG_0002.CR2"]!.kind == .raw && items["IMG_0001.JPG"]!.kind == .jpeg)
        precondition(items["MVI_0003.MP4"]!.kind == .video && items["MVI_0004.CRM"]!.kind == .video, "CRM 是视频")
        precondition(ProjectMedia.forPath("/x/MVI_0004.CRM") == .videos && ProjectMedia.forPath("/x/IMG_0001.CR3") == .photos)
        print("PASS: Canon card recognized from DCIM; CR3 / CR2 listed as RAW, MP4 and Cinema RAW Light CRM as video")

        let model = AppModel(startServices: false, journalURL: root.appending(path: "journal.sqlite"))
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.captureOneMode = .off; model.openAfterImport = .none
        model.sendToFCP = false; model.sendToResolve = false; model.deleteAfterImport = false
        model.autoRefresh = false; model.onlyNew = false; model.importProxies = true
        model.photoFolderLayout = .session; model.videoFolderLayout = .session; model.splitVideoByRoll = false
        model.destination = root.appending(path: "photos")
        model.videoDestination = root.appending(path: "videos")
        model.sourceKind = .card; model.cardRoot = card; model.connectedName = "EOS R6 Mark II"
        model.library = library
        model.backupEnabled = false; model.backupFolder = nil
        let project = ShootSession(day: "20261117", name: "佳能检查", content: .all)
        model.sessions = [project]; model.currentSessionID = project.id
        await model.loadAll()
        precondition(!model.days.isEmpty)
        model.selectAll(in: Set(model.days.map(\.id)))
        precondition(model.selectedFiles().count == files.count, "RAW + JPG 合成一格，但五个文件都要导：\(model.selectedFiles().count)")
        model.beginImport()
        try await wait { model.importTask == nil }
        let videos = model.videoDestination.appending(path: project.name)
        let photos = model.destination.appending(path: project.name)
        for (name, data) in files {
            let base = ["MP4", "CRM"].contains((name as NSString).pathExtension) ? videos : photos
            precondition((try? Data(contentsOf: base.appending(path: name))) == data, "\(name) 要原样存到\(base == videos ? "视频" : "照片")目录")
        }
        let batch = model.importJournal.records(for: project.id).first!
        precondition(batch.savedCount == files.count, "五项都要记成已保存：\(batch.savedCount)")
        print("PASS: importing a Canon card saves CR3 + JPG and CR2 to the photo folder and MP4 / CRM to the video folder")
    }

    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<600 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("Import timed out")
    }
}
