import Foundation
import SonyRemoteKit

/// 导入记录：导过的文件不再默认选中，并记下它存在本地的位置（再次导入时直接用，不重新下载）。
/// 键 = 文件名 | 大小 | 相机里的拍摄时间；值 = 本地路径（旧版记录没有路径，是空字符串）。
@MainActor
final class ImportHistory {
    static let shared = ImportHistory()
    private var entries: [String: String]
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SonyImport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "imported.json")
        let data = try? Data(contentsOf: url)
        if let data, let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            entries = dict
        } else if let data, let old = try? JSONDecoder().decode(Set<String>.self, from: data) {
            entries = Dictionary(uniqueKeysWithValues: old.map { ($0, "") })
        } else {
            entries = [:]
        }
    }

    static func key(_ item: CameraContentItem) -> String { "\(item.filename)|\(item.size)|\(item.captureDateRaw)" }

    func contains(_ item: CameraContentItem) -> Bool { entries[Self.key(item)] != nil }

    /// 上次保存到本地的位置（文件还在、大小一致才返回）。
    func localFile(_ item: CameraContentItem) -> URL? {
        guard let p = entries[Self.key(item)], !p.isEmpty else { return nil }
        return Self.matches(URL(filePath: p), item) ? URL(filePath: p) : nil
    }

    static func matches(_ url: URL, _ item: CameraContentItem) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else { return false }
        return size == item.size
    }

    func record(_ pairs: [(CameraContentItem, URL)]) {
        for (i, u) in pairs { entries[Self.key(i)] = u.path }
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(entries) { try? d.write(to: url, options: .atomic) }
    }

    func clear() {
        entries = [:]
        try? FileManager.default.removeItem(at: url)
    }
}
