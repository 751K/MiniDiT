import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
@testable import MiniDiT

/// 大疆 Osmo Pocket 的存储卡：视频、照片、DNG 和同名 .LRF 代理都在 DCIM/DJI_001/ 下，
/// 没有索尼的 M01.XML，拍摄时间写在文件名里。
@main struct DJICardChecks {
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
        let root = fm.temporaryDirectory.appending(path: "minidit-dji-card-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = oldHistory }

        let card = root.appending(path: "card")
        let dir = card.appending(path: "DCIM/DJI_001")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: card.appending(path: "MISC"), withIntermediateDirectories: true)
        let video = Data(repeating: 0x42, count: 4096), lrf = Data(repeating: 0x43, count: 512)
        let jpeg = Data(repeating: 0x44, count: 1024), dng = Data(repeating: 0x45, count: 2048)
        try video.write(to: dir.appending(path: "DJI_20251115143000_0001_D.MP4"))
        try lrf.write(to: dir.appending(path: "DJI_20251115143000_0001_D.LRF"))
        try jpeg.write(to: dir.appending(path: "DJI_20251115143500_0002_D.JPG"))
        try dng.write(to: dir.appending(path: "DJI_20251115143500_0002_D.DNG"))
        try Data(repeating: 0, count: 64).write(to: card.appending(path: "MISC/IDX.DB"))

        precondition(LocalCardLibrary.looksLikeCard(card), "只有 DCIM 的大疆卡要被认成存储卡")
        let library = LocalCardLibrary(root: card)
        let folder = try await library.folders()[0]
        var items: [String: CameraContentItem] = [:]
        for h in try await library.handles(in: folder) { let i = try await library.item(h); items[i.filename] = i }
        precondition(Set(items.keys) == ["DJI_20251115143000_0001_D.MP4", "DJI_20251115143500_0002_D.JPG", "DJI_20251115143500_0002_D.DNG"],
                     "LRF 不能单独出现在列表里：\(items.keys.sorted())")
        let clip = items["DJI_20251115143000_0001_D.MP4"]!, raw = items["DJI_20251115143500_0002_D.DNG"]!
        precondition(clip.kind == .video && raw.kind == .raw && items["DJI_20251115143500_0002_D.JPG"]!.kind == .jpeg)
        precondition(clip.captureDateRaw == "20251115T143000", "视频拍摄时间来自文件名：\(clip.captureDateRaw)")
        precondition(raw.captureDateRaw == "20251115T143500", "没有 EXIF 的照片也用文件名：\(raw.captureDateRaw)")
        precondition(LocalCardLibrary.djiClock("DJI_0001.MP4") == nil && LocalCardLibrary.djiClock("C0001.MP4") == nil)
        let sidecars = await library.sidecars(clip.id)
        precondition(sidecars.count == 1 && sidecars[0].kind == .proxy && sidecars[0].url.pathExtension == "LRF")
        print("PASS: DJI card recognized from DCIM alone; MP4 / JPG / DNG listed with DNG as RAW, LRF hidden and attached as the clip's proxy; capture time read from DJI filenames")

        let model = AppModel(startServices: false, journalURL: root.appending(path: "journal.sqlite"))
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.captureOneMode = .off; model.openAfterImport = .none
        model.sendToFCP = false; model.sendToResolve = false; model.deleteAfterImport = false
        model.autoRefresh = false; model.onlyNew = false; model.importProxies = true
        model.photoFolderLayout = .session; model.videoFolderLayout = .session; model.splitVideoByRoll = false
        model.destination = root.appending(path: "photos")
        model.videoDestination = root.appending(path: "videos")
        model.sourceKind = .card; model.cardRoot = card; model.connectedName = "Osmo Pocket 3"
        model.library = library
        model.backupEnabled = false; model.backupFolder = nil
        let project = ShootSession(day: "20251115", name: "大疆检查", content: .all)
        model.sessions = [project]; model.currentSessionID = project.id
        await model.loadAll()
        precondition(!model.days.isEmpty)
        model.selectAll(in: Set(model.days.map(\.id)))
        precondition(model.selectedFiles().count == 3)
        model.beginImport()
        try await wait { model.importTask == nil }
        let videos = model.videoDestination.appending(path: project.name)
        let photos = model.destination.appending(path: project.name)
        func read(_ base: URL, _ path: String) -> Data? { try? Data(contentsOf: base.appending(path: path)) }
        precondition(read(videos, "DJI_20251115143000_0001_D.MP4") == video)
        precondition(read(videos, "Proxy/DJI_20251115143000_0001_D.MP4") == lrf, "LRF 要放进 Proxy/ 并改成 .MP4")
        precondition(!fm.fileExists(atPath: videos.appending(path: "Proxy/DJI_20251115143000_0001_D.LRF").path))
        precondition(read(photos, "DJI_20251115143500_0002_D.DNG") == dng)
        precondition(read(photos, "DJI_20251115143500_0002_D.JPG") == jpeg)
        let batch = model.importJournal.records(for: project.id).first!
        precondition(batch.savedCount == 3, "三项都要记成已保存：\(batch.savedCount)")
        print("PASS: importing a DJI card saves MP4, JPG and DNG; the LRF lands in Proxy/ renamed to .MP4 for Resolve and is journaled with the clip")
    }

    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<600 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("Import timed out")
    }
}
