// 与 Debug App 的对象文件链接，覆盖 AppModel / AVPlayer / FCPXML，运行方式见开发说明。
import AppKit
import SonyRemoteKit
import SwiftUI
@testable import MiniDiT

@main struct FeatureChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        defaults.removePersistentDomain(forName: domain)
        let args = CommandLine.arguments
        guard args.count > 1 else { fatalError("需要一份临时测试卡路径") }
        let root = URL(filePath: args[1])
        let model = AppModel(startServices: false)
        model.onlyNew = false
        model.importContent = .all
        model.showPhotos = true; model.showRaw = true; model.showVideo = true
        model.mediaFilter = .init()
        model.autoRefresh = false
        model.sourceKind = .card; model.cardRoot = root; model.connectedName = "功能检查卡"
        model.library = LocalCardLibrary(root: root)
        await model.loadAll()
        precondition(model.items.count >= 3, "测试卡需要照片和一段可播放的视频")

        let photo = try require(model.items.values.first { $0.filename == "FEATURE001.JPG" })
        let originalID = try require(model.shotOfFile[photo.id])
        model.grid.replace(with: [originalID])
        let oldDay = model.shownDays
        let extra = root.appending(path: "DCIM/100MSDCF/FEATURE003.JPG")
        try? FileManager.default.removeItem(at: extra)
        try FileManager.default.copyItem(at: root.appending(path: "DCIM/100MSDCF/FEATURE002.JPG"), to: extra)
        model.refreshSources()
        for _ in 0..<200 where model.isRefreshingSources { try await Task.sleep(for: .milliseconds(50)) }
        precondition(!model.isRefreshingSources)
        precondition(model.grid.selected == [originalID], "刷新丢失了选择")
        precondition(model.shownDays == oldDay, "刷新改变了当前日期")
        precondition(model.items[photo.id]?.filename == photo.filename, "刷新改变了已有文件的身份")
        precondition(model.items.values.contains { $0.filename == "FEATURE003.JPG" }, "新增照片没有出现")

        model.mediaFilter.mark = .threeStars
        for _ in 0..<200 where model.metadataLoading { try await Task.sleep(for: .milliseconds(50)) }
        precondition(model.days.flatMap(\.shots).count == 1, "星级筛选没有读完整张卡")
        precondition(model.days.flatMap(\.shots).first == originalID)
        model.mediaFilter.mark = .shotMark
        for _ in 0..<200 where model.metadataLoading { try await Task.sleep(for: .milliseconds(50)) }
        precondition(model.days.flatMap(\.shots).count == 1, "Shot Mark 筛选不正确")
        model.mediaFilter = .init()

        let url = root.appending(path: "PRIVATE/M4ROOT/CLIP/C0001.MP4")
        let info = try require(ClipInfo.sidecar(for: url).flatMap(ClipInfo.read))
        precondition(info.timecode == "01:02:03:04")
        let xml = FCPXMLWriter.xml([.init(name: "功能检查", clips: [.init(url: url, proxy: nil)])])
        precondition(xml.contains("start=\"93079/25s\""), "FCPXML 未写入源时间码")
        precondition(xml.contains("tcFormat=\"NDF\""))
        precondition(xml.contains("start=\"2327600/625s\""), "Shot Mark 未加源时间码偏移")
        try xml.write(to: root.appending(path: "feature-check.fcpxml"), atomically: true, encoding: .utf8)

        let video = try require(model.allShots.first { model.items[$0.primary]?.filename == "C0001.MP4" })
        model.openPreview(video.id)
        for _ in 0..<200 where model.previewVideoURL == nil { try await Task.sleep(for: .milliseconds(50)) }
        precondition(model.previewVideoURL != nil, "本地视频预览未加载")
        await model.videoPlayback.load(url)
        for _ in 0..<100 where model.videoPlayback.loading { try await Task.sleep(for: .milliseconds(50)) }
        precondition(model.videoPlayback.failure == nil, "测试视频无法播放")
        precondition(abs(model.videoPlayback.duration - 3) < 0.1)
        model.videoPlayback.seek(1.2)
        precondition(abs(model.videoPlayback.position - 1.2) < 0.01)
        model.videoPlayback.toggle()
        try await Task.sleep(for: .milliseconds(500))
        precondition(model.videoPlayback.position > 1.2, "视频没有前进")
        model.closePreview()
        precondition(model.videoPlayback.player.currentItem == nil, "关闭后没有释放播放器")
        print("PASS: refresh identity/selection/date; full-card filters; source TC + FCPXML markers; AVPlayer play/seek/cleanup")

    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
