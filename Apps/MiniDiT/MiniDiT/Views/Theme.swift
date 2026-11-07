import AppKit
import SwiftUI

/// 全软件统一的视觉：白底，一个主题色（和图标同一种蓝，Assets 里的 AccentColor），
/// 图标用主题色的线条符号，不加彩色底块；分组用细边框区分，不用灰底。
enum Theme {
    /// 主题色：选中、按钮、图标。
    static let accent = Color.accentColor
    /// 底色：浅色模式下是白色。
    static let surface = Color(nsColor: .textBackgroundColor)
    /// 卡片、分组的边框。
    static let border = Color.primary.opacity(0.1)
    static let radius: CGFloat = 10
}
