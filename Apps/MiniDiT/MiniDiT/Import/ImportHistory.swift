import AppKit
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
    /// 原文件读不出来、又没能另存时为 false：这时不写，免得盖掉原件。
    private var writable = true
    private var saveFailed = false

    init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: LegacyMigration.supportFolder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "history.json")
        if let data = try? Data(contentsOf: url), let records = try? JSONDecoder().decode([ImportRecord].self, from: data) {
            index = HistoryIndex(records)
        } else if FileManager.default.fileExists(atPath: url.path) {
            // 文件在但读不出来：不能当成「没有记录」，否则下一次保存会把它整个盖掉。
            // 先另存一份原件，再把还能读的记录逐条捞回来。
            let data = try? Data(contentsOf: url)
            let kept = (data.flatMap { try? JSONDecoder().decode([Salvaged].self, from: $0) } ?? []).compactMap(\.record)
            let copy = dir.appending(path: "history.damaged-\(Int(Date().timeIntervalSince1970)).json")
            do {
                try FileManager.default.copyItem(at: url, to: copy)
                AppLog.shared.add("导入记录文件读不出来，原件另存为 \(copy.lastPathComponent)，保留了 \(kept.count) 条还能读的记录")
            } catch {
                // 连原件都留不下来就不再写这个文件，宁可这次的记录不落盘。
                writable = false
                AppLog.shared.add("导入记录文件读不出来，也没能另存原件（\(error.localizedDescription)）；这次运行不再写入导入记录")
            }
            index = HistoryIndex(kept)
        } else {
            // 旧版：imported.json，键「文件名|大小|时间」→ 路径（更早的版本是字符串集合）。
            let legacy = dir.appending(path: "imported.json")
            let data = try? Data(contentsOf: legacy)
            var dict: [String: String] = [:]
            if let data, let d = try? JSONDecoder().decode([String: String].self, from: data) { dict = d }
            else if let data, let set = try? JSONDecoder().decode(Set<String>.self, from: data) { dict = Dictionary(uniqueKeysWithValues: set.map { ($0, "") }) }
            index = HistoryIndex(HistoryIndex.migrate(legacy: dict))
            if !dict.isEmpty { write() }
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

    private let saver = DeferredSave()

    /// 导入时每存一个文件都会走到这里，而每次都是整份重写：合并成最多每 2 秒一次。
    /// 这份文件只是「导过没有」的索引，真正的导入记录在日志库里（每个文件即时落盘）。
    private func save() {
        saver.schedule { [weak self] in self?.write() }
    }

    /// 把还没写的立刻写掉（一批导入结束时调用；退出应用前会自动补写）。
    func flush() { saver.flush() }

    private func write() {
        guard writable else { return }
        do {
            try JSONEncoder().encode(index.records).write(to: url, options: .atomic)
            saveFailed = false
        } catch {
            // 每个文件都会存一次，失败只在头一回记日志，免得刷屏。
            if !saveFailed { AppLog.shared.add("导入记录写入失败：\(error.localizedDescription)") }
            saveFailed = true
        }
    }

    /// 坏掉的记录文件里逐条解码：单条读不出来不影响其他条。
    private struct Salvaged: Decodable {
        let record: ImportRecord?
        init(from decoder: Decoder) throws { record = try? ImportRecord(from: decoder) }
    }

    func clear() {
        index = HistoryIndex()
        writable = true
        save()
        flush()
    }
}

/// 把频繁的「整份重写」合并起来：两秒内的多次请求只写最后一次。退出应用前补写。
@MainActor
final class DeferredSave {
    private var pending: (@MainActor () -> Void)?
    private var task: Task<Void, Never>?

    init() {
        _ = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    func schedule(_ write: @escaping @MainActor () -> Void) {
        pending = write
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush() {
        task?.cancel(); task = nil
        let write = pending
        pending = nil
        write?()
    }
}
