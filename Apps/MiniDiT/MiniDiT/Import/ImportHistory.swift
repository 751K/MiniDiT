import Foundation
import MiniDiTCore
import SonyRemoteKit

/// 导入记录：导过的文件不再默认选中，并记下它在本地的位置（再次导入时直接用，不重新下载）。
/// Wi-Fi 和读卡器共用一份；匹配规则见 `HistoryIndex`。
@MainActor
final class ImportHistory {
    static var shared = ImportHistory()
    private var index: HistoryIndex
    private let url: URL

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: LegacyMigration.supportFolder, directoryHint: .isDirectory)
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

    func contains(_ item: CameraContentItem, camera: String?) -> Bool { index.find(item, camera: camera, matchingIdentityExactly: true) != nil }

    /// 上次保存到本地的位置（文件还在、大小一致才返回）。
    func localFile(_ item: CameraContentItem, camera: String?) -> URL? {
        guard let p = index.find(item, camera: camera, matchingIdentityExactly: true)?.path else { return nil }
        let u = URL(filePath: p)
        return Self.matches(u, item) ? u : nil
    }

    func backupFiles(_ item: CameraContentItem, camera: String?) -> [URL] {
        guard let record = index.find(item, camera: camera, matchingIdentityExactly: true) else { return [] }
        return Set((record.backupPaths ?? []) + [record.backupPath].compactMap { $0 }).sorted().map { URL(filePath: $0) }
            .filter { Self.matches($0, item) }
    }
    func backupFile(_ item: CameraContentItem, camera: String?) -> URL? { backupFiles(item, camera: camera).first }

    nonisolated static func matches(_ url: URL, _ item: CameraContentItem) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 else { return false }
        // ≥4GB 的文件在 ObjectInfo 里是 0xFFFFFFFF，读出来是 sizeKnown == false、size == 0；
        // 这时只能确认文件非空，不能拿 0 去比。
        return item.sizeKnown ? size == item.size : size > 0
    }

    /// 导入记录（不碰磁盘）。需要核对文件在不在时，拿路径到后台去查，别在主线程 stat。
    func record(for item: CameraContentItem, camera: String?) -> ImportRecord? {
        index.find(item, camera: camera, matchingIdentityExactly: true)
    }

    struct Entry {
        var item: CameraContentItem
        var url: URL
        var xxh64: UInt64?
        var backup: URL?
        var backups: [URL] = []
    }

    func record(_ entries: [Entry], camera: String?) {
        for e in entries {
            let i = e.item
            // ≥4GB 的文件在 ObjectInfo 里没有大小（记成 0）；存实际大小，之后从读卡器再看到也能对上。
            let size = (try? FileManager.default.attributesOfItem(atPath: e.url.path))?[.size] as? UInt64 ?? i.size
            index.insert(ImportRecord(filename: i.filename, size: size, dateRaw: i.captureDateRaw, camera: camera, path: e.url.path,
                                      xxh64: e.xxh64.map(XXH64.hex), backupPath: e.backup?.path, backupPaths: e.backups.isEmpty ? nil : e.backups.map(\.path)))
        }
        save()
    }

    var records: [ImportRecord] { index.records }

    func recordBackup(primaryPath: String, backup: URL) {
        guard var record = index.records.first(where: { $0.path == primaryPath }) else { return }
        record.backupPath = record.backupPath ?? backup.path
        record.backupPaths = Array(Set((record.backupPaths ?? []) + [record.backupPath, backup.path].compactMap { $0 })).sorted()
        index.insert(record)
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
