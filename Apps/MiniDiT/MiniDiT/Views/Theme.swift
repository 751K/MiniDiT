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
    /// 侧栏里的分组底：浅色半透明，跟着侧栏的灰底走。
    static let sidebarGroup = Color.primary.opacity(0.05)
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

// MARK: - 浮层上的玻璃按钮（规范：浮在内容上面的底栏、提示条用系统玻璃样式）

extension View {
    /// 浮层上的按钮：macOS 26 起是系统玻璃（主按钮为蓝色玻璃），更早的系统用 bordered / borderedProminent。
    @ViewBuilder func glassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent { buttonStyle(.glassProminent) } else { buttonStyle(.glass) }
        } else {
            if prominent { buttonStyle(.borderedProminent) } else { buttonStyle(.bordered) }
        }
    }
}

/// 浮层上的开关按钮（「备份」「仅代理」）：打开时是蓝色玻璃，关着时是普通玻璃。用系统按钮样式，不自己画。
struct GlassToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Button(title) { isOn.toggle() }
            .glassButton(prominent: isOn)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .accessibilityValue(isOn ? "开" : "关")
    }
}

// MARK: - 分段选择（规范：灰色底槽 + 蓝色玻璃滑块）

/// 分段里每一格的高度（底槽再多 2 pt 边距）。
private let segmentHeight: CGFloat = 24

/// 选中格的底：主题蓝，macOS 26 起再叠一层透明玻璃的高光。
/// 玻璃自带的色调在窗口不在前台时会被系统去掉，所以蓝色用实心底，保证后台时也认得出选中的是哪格。
private struct SegmentThumb: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(Theme.accent).glassEffect(.clear.interactive(), in: shape)
        } else {
            shape.fill(Theme.accent)
        }
    }
}

private extension View {
    func segmentTrack() -> some View {
        padding(2).background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }
}

/// 一格的文字：名称，后面可跟一个灰色数字（「卡 1  1045」）。
private struct SegmentLabel: View {
    let title: String
    let count: String?
    let on: Bool
    var body: some View {
        HStack(spacing: 4) {
            Text(title).fontWeight(on ? .semibold : .regular).foregroundStyle(on ? Color.white : Color.secondary)
            if let count { Text(count).monospacedDigit().foregroundStyle(on ? Color.white.opacity(0.8) : Color.secondary) }
        }
        .font(Theme.Font.body)
        .lineLimit(1)
    }
}

/// 单选分段：选中的一格是一块会滑动的玻璃。
struct GlassSegment<T: Hashable>: View {
    struct Option { let title: String; var count: String? = nil; let value: T }
    let options: [Option]
    @Binding var selection: T
    /// 撑满整行，每格等宽。
    var fill = false
    @Environment(\.isEnabled) private var enabled
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { o in
                let on = selection == o.value
                Button { withAnimation(.snappy(duration: 0.28)) { selection = o.value } } label: {
                    SegmentLabel(title: o.title, count: o.count, on: on)
                        .padding(.horizontal, 10).frame(maxWidth: fill ? .infinity : nil).frame(height: segmentHeight)
                        .background { if on { SegmentThumb().matchedGeometryEffect(id: "on", in: ns) } }
                        .opacity(enabled || on ? 1 : 0.5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(o.title + (o.count.map { "，\($0)" } ?? ""))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .segmentTrack()
        .accessibilityElement(children: .contain)
    }
}

/// 多选分段（文件类型）：每格各自开关，打开的格子有一块玻璃。
struct GlassMultiSegment: View {
    struct Option { let title: String; let isOn: Binding<Bool> }
    let options: [Option]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { i in
                let o = options[i]
                Button { withAnimation(.snappy(duration: 0.2)) { o.isOn.wrappedValue.toggle() } } label: {
                    SegmentLabel(title: o.title, count: nil, on: o.isOn.wrappedValue)
                        .padding(.horizontal, 10).frame(height: segmentHeight)
                        .background { if o.isOn.wrappedValue { SegmentThumb() } }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(o.isOn.wrappedValue ? .isSelected : [])
            }
        }
        .segmentTrack()
        .accessibilityElement(children: .contain)
    }
}
