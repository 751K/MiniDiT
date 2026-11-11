import Foundation
import SonyRemoteKit

/// 导入记录里的一条：哪台相机的哪个文件，存到了本地哪里。
public struct ImportRecord: Codable, Hashable, Sendable {
    public var filename: String
    public var size: UInt64
    /// 相机本地时间，格式 yyyyMMdd'T'HHmmss（Wi-Fi 和读卡器都用这个格式）。
    public var dateRaw: String
    /// 机身 ID（型号#序列号）；读卡器或拿不到序列号时为 nil。
    public var camera: String?
    /// 本地路径；旧版记录没有。
    public var path: String?
    public var importedAt: Date?
    /// 导入时算的 xxHash64（16 位十六进制）；v0.3 以前的记录没有。
    public var xxh64: String?
    /// 第二份（备份盘上）的路径；没有备份时为 nil。
    public var backupPath: String?
    public var backupPaths: [String]?

    public init(filename: String, size: UInt64, dateRaw: String, camera: String?, path: String?, importedAt: Date? = Date(),
                xxh64: String? = nil, backupPath: String? = nil, backupPaths: [String]? = nil) {
        self.filename = filename
        self.size = size
        self.dateRaw = dateRaw
        self.camera = camera
        self.path = path
        self.importedAt = importedAt
        self.xxh64 = xxh64
        self.backupPath = backupPath
        self.backupPaths = backupPaths
    }
}

/// 判断一个文件有没有导入过。
///
/// 规则：文件名、大小相同；机身 ID 相同（任一方不知道时不比）；拍摄时间相差不超过 `timeWindow`。
/// 时间放宽是因为读卡器读到的是文件修改时间，可能和相机给的拍摄时间差一两秒。
/// 宁可多导一次（重复），也不要把没导过的当成导过（丢片）。
public struct HistoryIndex: Sendable {
    public static let timeWindow: TimeInterval = 120

    public private(set) var records: [ImportRecord] = []
    private var byKey: [String: [Int]] = [:]

    public init(_ records: [ImportRecord] = []) {
        for r in records { insert(r) }
    }

    private static func key(_ name: String, _ size: UInt64) -> String { "\(name.uppercased())|\(size)" }

    public mutating func insert(_ r: ImportRecord) {
        let k = Self.key(r.filename, r.size)
        // 同一个文件再导一次：更新位置，不重复记。
        if let i = byKey[k]?.first(where: { Self.same(records[$0], r.camera, r.dateRaw) }) {
            records[i].path = r.path ?? records[i].path
            records[i].camera = records[i].camera ?? r.camera
            records[i].importedAt = r.importedAt ?? records[i].importedAt
            records[i].xxh64 = r.xxh64 ?? records[i].xxh64
            records[i].backupPath = r.backupPath ?? records[i].backupPath
            let paths = Array(Set((records[i].backupPaths ?? []) + (r.backupPaths ?? []) + [r.backupPath].compactMap { $0 })).sorted()
            if !paths.isEmpty { records[i].backupPaths = paths }
            return
        }
        records.append(r)
        byKey[k, default: []].append(records.count - 1)
    }

    public func find(_ item: CameraContentItem, camera: String?, matchingIdentityExactly: Bool = false) -> ImportRecord? {
        if let list = byKey[Self.key(item.filename, item.size)],
           let found = list.lazy.map({ records[$0] }).first(where: { (!matchingIdentityExactly || $0.camera == camera) && Self.same($0, camera, item.captureDateRaw) }) {
            return found
        }
        // 大小未知（≥4GB 的文件，ObjectInfo 里是 0xFFFFFFFF）：记录里存的可能是实际大小，
        // 按文件名 + 机身 + 拍摄时间再找一次。机身必须一致，避免把另一台相机的同名片段当成已导入。
        guard !item.sizeKnown else { return nil }
        let name = item.filename.uppercased()
        return records.lazy.first {
            $0.filename.uppercased() == name && $0.camera == camera && Self.same($0, camera, item.captureDateRaw)
        }
    }

    public func contains(_ item: CameraContentItem, camera: String?) -> Bool { find(item, camera: camera) != nil }

    static func same(_ r: ImportRecord, _ camera: String?, _ dateRaw: String) -> Bool {
        if let a = r.camera, let b = camera, a != b { return false }
        if r.dateRaw == dateRaw { return true }
        guard let a = parse(r.dateRaw), let b = parse(dateRaw) else { return r.dateRaw.isEmpty && dateRaw.isEmpty }
        return abs(a.timeIntervalSince(b)) <= timeWindow
    }

    /// 只当作「墙上时间」比较，不涉及时区。
    static func parse(_ raw: String) -> Date? {
        let digits = raw.prefix(15)
        guard digits.count == 15 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        return f.date(from: String(digits))
    }

    /// 旧版记录：键「文件名|大小|时间」，值是路径（可能为空）。
    public static func migrate(legacy: [String: String]) -> [ImportRecord] {
        legacy.compactMap { k, v in
            let parts = k.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let size = UInt64(parts[1]) else { return nil }
            return ImportRecord(filename: parts[0], size: size, dateRaw: parts[2...].joined(separator: "|"),
                                camera: nil, path: v.isEmpty ? nil : v, importedAt: nil)
        }
    }
}
