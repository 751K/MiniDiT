import Foundation

/// 只负责筛选，不改变机内星级、文件或导入记录。
public struct MediaFilter: Sendable, Equatable {
    public enum Mark: String, CaseIterable, Sendable {
        case all, marked, rated, twoStars, threeStars, fourStars, fiveStars, shotMark, rejected
        public var title: String {
            switch self {
            case .all: "全部"
            case .marked: "有星级或 Shot Mark"
            case .rated: "照片：至少 1 星"
            case .twoStars: "照片：至少 2 星"
            case .threeStars: "照片：至少 3 星"
            case .fourStars: "照片：至少 4 星"
            case .fiveStars: "照片：5 星"
            case .shotMark: "视频：有 Shot Mark"
            case .rejected: "照片：机内删除标记"
            }
        }
        public var shortTitle: String {
            switch self {
            case .all: "标记"
            case .marked: "星级 / Shot Mark"
            case .rated: "≥1 星"
            case .twoStars: "≥2 星"
            case .threeStars: "≥3 星"
            case .fourStars: "≥4 星"
            case .fiveStars: "5 星"
            case .shotMark: "Shot Mark"
            case .rejected: "删除标记"
            }
        }
        public var menuTitle: String {
            switch self {
            case .all: "全部"
            case .marked: "有星级或 Shot Mark"
            case .rated: "至少 1 星"
            case .twoStars: "至少 2 星"
            case .threeStars: "至少 3 星"
            case .fourStars: "至少 4 星"
            case .fiveStars: "至少 5 星"
            case .shotMark: "有 Shot Mark"
            case .rejected: "删除标记"
            }
        }
    }
    public var query = ""
    public var mark: Mark = .all
    public init() {}
    public var needsMetadata: Bool { mark != .all }
    public var isActive: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || needsMetadata }

    public func accepts(names: [String], isVideo: Bool, rating: Int?, hasShotMark: Bool) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard words.allSatisfy({ word in names.contains { $0.localizedStandardContains(String(word)) } }) else { return false }
        switch mark {
        case .all: return true
        case .marked: return isVideo ? hasShotMark : (rating ?? 0) > 0
        case .rated: return !isVideo && (rating ?? 0) >= 1
        case .twoStars: return !isVideo && (rating ?? 0) >= 2
        case .threeStars: return !isVideo && (rating ?? 0) >= 3
        case .fourStars: return !isVideo && (rating ?? 0) >= 4
        case .fiveStars: return !isVideo && (rating ?? 0) >= 5
        case .shotMark: return isVideo && hasShotMark
        case .rejected: return !isVideo && rating == -1
        }
    }
}
