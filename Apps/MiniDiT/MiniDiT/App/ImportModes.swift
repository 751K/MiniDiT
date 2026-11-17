import Foundation

enum CaptureOneMode: String, CaseIterable, Identifiable {
    case newSession, c1Settings, inPlace, lightroom, off
    var id: String { rawValue }
    /// 导入时要给每组照片起名字（C1 会话 / LrC 收藏夹）。
    var namesGroups: Bool { self == .newSession || self == .lightroom }
    var title: String {
        switch self {
        case .newSession: String(localized: "新建 C1 会话（日期 + 事件），直接存入 Capture 文件夹")
        case .lightroom: String(localized: "导入到 Lightroom Classic（按收藏夹整理）")
        case .off: String(localized: "不导入，仅下载至文件夹")
        case .c1Settings: String(localized: "按 Capture One 的导入设置导入")
        case .inPlace: String(localized: "就地添加（不复制文件，仅添加到目录）")
        }
    }
}

/// 工作流程：按自己的拍摄事件整理，或按团队的素材交接流程整理。
/// 两种流程共用全部功能，只提供不同的默认建议。
enum UsageMode: String, CaseIterable, Identifiable {
    case personal
    // 保留已有“专业”设置的存储值，升级后沿用用户选择。
    case team = "pro"
    var id: String { rawValue }
    var title: String { self == .personal ? String(localized: "个人") : String(localized: "团队") }
    var detail: String {
        switch self {
        case .personal: String(localized: "自己整理和后期，推荐按日期、事件存放视频。所有功能均可设置。")
        case .team: String(localized: "素材交给团队后期，推荐按卷号整理、手动导入并保留原卡。所有功能均可设置。")
        }
    }
    /// 团队交接时，每卷一个子文件夹；个人流程也可使用这一模板。
    static let teamVideoTemplate = "{M}.{D}-{事件}/{卷号}"
}

/// 按文件夹管理照片的软件：「只下载」导入完成后用它打开下载的文件夹。
enum FolderApp: String, CaseIterable, Identifiable {
    case none, finder, bridge, dxo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: String(localized: "不打开")
        case .finder: String(localized: "访达")
        case .bridge: "Adobe Bridge"
        case .dxo: "DxO PhotoLab"
        }
    }

    /// 对应「设置 › 软件」里的哪一个（访达不用找）。
    var appKind: AppInfo.Kind? {
        switch self {
        case .bridge: .bridge
        case .dxo: .dxo
        default: nil
        }
    }

    /// 装了才能选（访达总是有）。
    var isAvailable: Bool { appKind.map { AppInfo.find($0).isInstalled } ?? true }
}
