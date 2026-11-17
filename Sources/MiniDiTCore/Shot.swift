import Foundation
import SonyRemoteKit

/// 一次拍摄：同一张照片的 RAW + JPEG/HEIF 合成一格；视频单独一格。
public struct Shot: Identifiable, Hashable, Sendable {
    /// 用第一个文件的句柄当 ID。
    public let id: UInt32
    /// 这次拍摄的所有文件句柄。
    public var handles: [UInt32]
    /// 显示缩略图用的文件（优先 JPEG/HEIF，取缩略图更快）。
    public var primary: UInt32
    public var kinds: [CameraContentItem.Kind]

    public var hasRaw: Bool { kinds.contains(.raw) }
    public var hasPhoto: Bool { kinds.contains(.jpeg) || kinds.contains(.heif) }
    public var isVideo: Bool { kinds.contains(.video) }

    /// 角标，例如「RAW+HIF」「JPG」「视频」。
    public var badge: String { Self.badge(kinds) }

    /// 按给定的文件类型拼角标（界面上用筛选后实际要导入的那几种）。
    public static func badge(_ kinds: [CameraContentItem.Kind]) -> String {
        var parts: [String] = []
        if kinds.contains(.raw) { parts.append("RAW") }
        if kinds.contains(.heif) { parts.append("HIF") }
        if kinds.contains(.jpeg) { parts.append("JPG") }
        if kinds.contains(.video) { parts.append(String(localized: "视频", bundle: .miniDiT)) }
        return parts.joined(separator: "+")
    }
}

public enum ShotBuilder {
    /// 同一文件名主体、拍摄时间相差不超过这么多秒的文件算同一次拍摄。
    /// 不看卡槽：「分别记录」时 RAW 在卡 1、JPG/HIF 在卡 2；「同时记录」时两张卡上是同样的文件。
    public static let pairWindow: TimeInterval = 5

    /// 按传入顺序分组（保持第一个文件出现的位置）。
    public static func group(_ items: [CameraContentItem]) -> [Shot] {
        var shots: [Shot] = []
        var open: [String: [Int]] = [:]   // 键 → shots 下标
        var times: [Int: Date?] = [:]
        for item in items {
            let isVideo = item.kind == .video
            let key = item.baseName.uppercased()
            if let candidates = open[key],
               let idx = candidates.first(where: { i in
                   shots[i].isVideo == isVideo && close(times[i] ?? nil, item.captureDate)
               }) {
                shots[idx].handles.append(item.id)
                shots[idx].kinds.append(item.kind)
                if item.kind == .jpeg || item.kind == .heif, !shots[idx].primaryIsPhoto {
                    shots[idx].primary = item.id
                }
                continue
            }
            shots.append(Shot(id: item.id, handles: [item.id], primary: item.id, kinds: [item.kind]))
            let i = shots.count - 1
            times[i] = item.captureDate
            open[key, default: []].append(i)
        }
        return shots
    }

    private static func close(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) <= pairWindow
    }

    /// 导入时实际要下载的文件：先按 `include`（卡槽、类型筛选）留下，再按配对规则取舍；
    /// 同一个文件在两张卡上都有（同时记录）时只取一份。
    public static func files(of shot: Shot, policy: PairPolicy, kindOf: (UInt32) -> CameraContentItem.Kind?,
                             identity: (UInt32) -> String? = { _ in nil },
                             include: (UInt32) -> Bool = { _ in true },
                             preference: (UInt32) -> UInt32 = { _ in 0 }) -> [UInt32] {
        // 两张卡「同时记录」时同一个文件有两份，只留一份：按 preference 小的优先（卡 1 先于卡 2），
        // 每次留的都是同一份，不随列表顺序变。
        let accepted = shot.handles.filter(include).enumerated()
            .sorted { (preference($0.element), $0.offset) < (preference($1.element), $1.offset) }.map(\.element)
        let kinds = accepted.compactMap(kindOf)
        let hasRaw = kinds.contains(.raw), hasPhoto = kinds.contains(.jpeg) || kinds.contains(.heif)
        var seen = Set<String>()
        return accepted.filter { h in
            guard let k = kindOf(h) else { return false }
            if let id = identity(h), !seen.insert(id).inserted { return false }
            switch policy {
            case .both: return true
            case .rawOnly: return !(hasRaw && (k == .jpeg || k == .heif))
            case .jpegOnly: return !(hasPhoto && k == .raw)
            }
        }
    }
}

private extension Shot {
    var primaryIsPhoto: Bool {
        guard let i = handles.firstIndex(of: primary) else { return false }
        return kinds[i] == .jpeg || kinds[i] == .heif
    }
}

public enum PairPolicy: String, CaseIterable, Identifiable, Sendable {
    case both, rawOnly, jpegOnly
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .both: String(localized: "RAW 和 JPEG/HEIF 都导", bundle: .miniDiT)
        case .rawOnly: String(localized: "有 RAW 时只导 RAW", bundle: .miniDiT)
        case .jpegOnly: String(localized: "有 JPEG/HEIF 时只导 JPEG/HEIF", bundle: .miniDiT)
        }
    }
}
