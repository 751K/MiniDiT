import Foundation
import MiniDiTCore
import SonyRemoteKit

/// 导入记录：导过的文件不再默认选中，并记下它在本地的位置（再次导入时直接用，不重新下载）。
/// Wi-Fi 和读卡器共用一份；匹配规则见 `HistoryIndex`。
@MainActor
final class ImportHistory {
    static let shared = ImportHistory()
    private var index: HistoryIndex
    private let url: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SonyImport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "history.json")
        if let data = try? Data(contentsOf: url), let records = try? JSONDecoder().decode([ImportRecord].self, from: data) {
            index = HistoryIndex(records)
        } else {
            // 旧版：imported.json，键「文件名|大小|时间」→ 路径（更早的版本是字符串集合）。
            let legacy = dir.appending(path: "imported.json")
            let data = try? Data(contentsOf: legacy)
            var dict: [String: String] = [:]
            if let data, let d = try? JSONDecoder().decode([String: String].self, from: data) { dict = d }
            else if let data, let set = try? JSONDecoder().decode(Set<String>.self, from: data) { dict = Dictionary(uniqueKeysWithValues: set.map { ($0, "") }) }
            index = HistoryIndex(HistoryIndex.migrate(legacy: dict))
            if !dict.isEmpty { save() }
        }
    }

    func contains(_ item: CameraContentItem, camera: String?) -> Bool { index.contains(item, camera: camera) }

    /// 上次保存到本地的位置（文件还在、大小一致才返回）。
    func localFile(_ item: CameraContentItem, camera: String?) -> URL? {
        guard let p = index.find(item, camera: camera)?.path else { return nil }
        let u = URL(filePath: p)
        return Self.matches(u, item) ? u : nil
    }

    static func matches(_ url: URL, _ item: CameraContentItem) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else { return false }
        return size == item.size
    }

    func record(_ pairs: [(CameraContentItem, URL)], camera: String?) {
        for (i, u) in pairs {
            index.insert(ImportRecord(filename: i.filename, size: i.size, dateRaw: i.captureDateRaw, camera: camera, path: u.path))
        }
        save()
    }

    var count: Int { index.records.count }

    private func save() {
        if let d = try? JSONEncoder().encode(index.records) { try? d.write(to: url, options: .atomic) }
    }

    func clear() {
        index = HistoryIndex()
        save()
    }
}
