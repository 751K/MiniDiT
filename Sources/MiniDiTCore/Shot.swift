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
    public var badge: String {
        var parts: [String] = []
        if hasRaw { parts.append("RAW") }
        if kinds.contains(.heif) { parts.append("HIF") }
        if kinds.contains(.jpeg) { parts.append("JPG") }
        if isVideo { parts.append("视频") }
        return parts.joined(separator: "+")
    }
}

public enum ShotBuilder {
    /// 同一卡槽、同一文件名主体、拍摄时间相差不超过这么多秒的文件算同一次拍摄。
    public static let pairWindow: TimeInterval = 5

    /// 按传入顺序分组（保持第一个文件出现的位置）。
    public static func group(_ items: [CameraContentItem]) -> [Shot] {
        var shots: [Shot] = []
        var open: [String: [Int]] = [:]   // 键 → shots 下标
        var times: [Int: Date?] = [:]
        for item in items {
            let isVideo = item.kind == .video
            let key = "\(item.storageID)/\(item.baseName.uppercased())"
            if !isVideo, let candidates = open[key],
               let idx = candidates.first(where: { i in
                   !shots[i].isVideo && close(times[i] ?? nil, item.captureDate)
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

    /// 导入时按配对规则选出实际要下载的文件。
    public static func files(of shot: Shot, policy: PairPolicy, kindOf: (UInt32) -> CameraContentItem.Kind?) -> [UInt32] {
        shot.handles.filter { h in
            guard let k = kindOf(h) else { return false }
            switch policy {
            case .both: return true
            case .rawOnly: return !(shot.hasRaw && (k == .jpeg || k == .heif))
            case .jpegOnly: return !(shot.hasPhoto && k == .raw)
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
        case .both: "RAW 和 JPEG/HEIF 都导"
        case .rawOnly: "有 RAW 时只导 RAW"
        case .jpegOnly: "有 JPEG/HEIF 时只导 JPEG/HEIF"
        }
    }
}
