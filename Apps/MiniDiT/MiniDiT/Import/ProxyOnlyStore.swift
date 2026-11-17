import Foundation
import SonyRemoteKit

/// 只导了代理（Wi-Fi「视频只导代理」）的片段：原片还在卡上，所以不算「已导入」，
/// 记在这里只为在缩略图上标出「仅代理」，以及知道代理放在哪。
/// 键是「文件名|大小」（不带机身：同一张卡插在读卡器上也要认得出来），值是代理的位置。
@MainActor
final class ProxyOnlyStore {
    static let shared = ProxyOnlyStore()

    private let url: URL
    private var map: [String: String]

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: LegacyMigration.supportFolder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "proxy-only.json")
        map = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    private static func key(_ item: CameraContentItem, camera: String?) -> String {
        "\(item.filename.uppercased())|\(item.size)"
    }

    /// 只导了代理，而且代理文件还在。
    func proxy(of item: CameraContentItem, camera: String?) -> URL? {
        guard let p = map[Self.key(item, camera: camera)], FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(filePath: p)
    }

    func record(_ item: CameraContentItem, camera: String?, proxy: URL) {
        map[Self.key(item, camera: camera)] = proxy.path
        if let data = try? JSONEncoder().encode(map) { try? data.write(to: url, options: .atomic) }
    }
}
