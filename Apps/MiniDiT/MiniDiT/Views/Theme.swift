import AppKit
import SwiftUI

/// 全软件统一的视觉，规则见 docs/MiniDiT-DESIGN.md。
/// 白底，一个主题色（和图标同一种蓝，Assets 里的 AccentColor），图标用主题色或灰色的线条符号；
/// 控件、按钮一律用系统的，不自己画；字号只用下面四级。
enum Theme {
    /// 主题色：可操作、选中。
    static let accent = Color.accentColor
    /// 需要注意的警告（备份盘未连接、只存了一份、离线）。正常状态不上色。
    static let warning = Color.orange
    /// 底色：浅色模式下是白色。
    static let surface = Color(nsColor: .textBackgroundColor)
    /// 卡片、分组的边框。
    static let border = Color.primary.opacity(0.1)
    static let radius: CGFloat = 10

    /// 四级字号。
    enum Font {
        /// 页面标题（向导每一步、选择来源）。
        static let title = SwiftUI.Font.system(size: 22, weight: .bold)
        /// 强调：分组标题、卡片名称、数量。
        static let headline = SwiftUI.Font.headline
        /// 正文：选项、按钮、列表。
        static let body = SwiftUI.Font.body
        /// 说明：路径、状态、次要信息。
        static let caption = SwiftUI.Font.subheadline
    }
}

/// 别的软件的图标。macOS 26 把旧格式的图标（.icns，不是 Icon Composer 做的）交给别的软件时，
/// 会缩小放进一个灰色圆角方块里（程序坞里不会），Capture One 就是这样。
/// 所以有自带 .icns、又没有新格式图标（CFBundleIconName）的软件，直接读它的 .icns。
enum AppIcon {
    @MainActor private static var cache: [URL: NSImage] = [:]

    @MainActor
    static func image(for app: URL) -> NSImage {
        if let i = cache[app] { return i }
        var img = NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false))
        if let info = Bundle(url: app)?.infoDictionary, info["CFBundleIconName"] == nil,
           var name = info["CFBundleIconFile"] as? String {
            if !name.hasSuffix(".icns") { name += ".icns" }
            let file = app.appending(path: "Contents/Resources/\(name)")
            if let own = NSImage(contentsOf: file) { img = own }
        }
        cache[app] = img
        return img
    }
}
