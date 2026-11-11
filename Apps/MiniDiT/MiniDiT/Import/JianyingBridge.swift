import AppKit
import AVFoundation
import MiniDiTCore

/// 交给剪映专业版：视频放进与 MiniDiT 项目同名草稿的素材区，没有就新建。剪映没有脚本接口，草稿文件就是交接方式。
enum JianyingBridge {
    /// 冻结交接内容：草稿名和每个片段的时长、尺寸、帧率（读不到的按 0，剪映打开时会自己重新读取）。
    static func payload(name: String, clips: [URL]) async throws -> Data {
        var items: [JianyingDraft.Clip] = []
        for url in clips {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            var width = 0, height = 0
            var fps: Double?
            if let track = try? await asset.loadTracks(withMediaType: .video).first {
                let (size, transform, rate) = (try? await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)) ?? (.zero, .identity, Float(0))
                let shown = size.applying(transform)
                width = Int(abs(shown.width).rounded()); height = Int(abs(shown.height).rounded())
                fps = rate > 0 ? Double(rate) : nil
            }
            items.append(.init(path: url.path, duration: duration.isFinite ? duration : 0, width: width, height: height, fps: fps))
        }
        return try JSONEncoder().encode(JianyingDraft.Handoff(name: name, clips: items))
    }

    static func deliver(_ payload: Data, id: UUID, root: URL) throws -> (folder: URL, outcome: JianyingDraft.Outcome) {
        try JianyingDraft.deliver(try JSONDecoder().decode(JianyingDraft.Handoff.self, from: payload), id: id, in: root)
    }

    /// 剪映没开就在后台打开，首页的「本地草稿」里就能看到草稿；已经开着时不打扰正在进行的剪辑。
    @MainActor static func launchIfNeeded() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: JianyingDraft.bundleID).isEmpty,
              let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: JianyingDraft.bundleID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in }
    }
}
