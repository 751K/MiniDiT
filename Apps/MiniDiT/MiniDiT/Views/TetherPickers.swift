import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

// 联机拍摄底部参数条弹出的选择器：刻度条、曝光补偿、白平衡、斑马纹设置。由 TetherView 的参数条打开。

/// 横向刻度条（快门、光圈、ISO、曝光补偿）：每个可选值一条刻度，整档的长一些并标数字。指针移动或拖动时底部参数条显示指着的值，
/// 点按或拖动松手才发给相机。
/// ISO 的 AUTO 这类不在数轴上的选项放在刻度条上方，作为单独的按钮。
struct ScalePicker: View {
    let setting: CameraSetting
    @Binding var preview: Int64?
    /// 刚选、相机还没回读的值（滚轮连续调整时标记先跟着走）。
    var selected: Int64? = nil
    let choose: (Int64) -> Void
    @State private var hover: Int?

    struct Tick {
        let option: SettingOption; let major: Bool; let label: String?
        /// 扩展感光度（ISO 50–80、64000 以上）：刻度画淡一些。
        var extended = false
    }

    /// 数轴上的选项（按刻度条从左到右的顺序）和数轴外的选项（AUTO、BULB 等）。滚轮调整也按这个顺序走。
    static func layout(_ setting: CameraSetting) -> (ticks: [Tick], extras: [SettingOption]) {
        switch setting.kind {
        case .shutterSpeed:
            // 从快到慢（1/8000 … 30″）；BULB 等不在数轴上。整档：1/8000 … 1/2、1″、2″、4″、8″、15″、30″。
            func seconds(_ v: Int64) -> Double? {
                let u = UInt32(truncatingIfNeeded: v), num = Double(u >> 16), den = Double(u & 0xFFFF)
                return u == 0 || u == 0xFFFF_FFFF || den == 0 ? nil : num / den
            }
            let numeric = setting.options.compactMap { o in seconds(o.value).map { (o, $0) } }.sorted { $0.1 < $1.1 }
            let extras = setting.options.filter { seconds($0.value) == nil }
            let fractions: Set<Double> = [8000, 4000, 2000, 1000, 500, 250, 125, 60, 30, 15, 8, 4, 2]
            let whole: Set<Double> = [1, 2, 4, 8, 15, 30]
            var majorCount = 0
            return (numeric.map { o, sec in
                let label: String? = sec < 1 && fractions.contains((1 / sec).rounded()) && abs(1 / sec - (1 / sec).rounded()) < 0.01
                    ? String(Int((1 / sec).rounded()))
                    : whole.contains(sec) ? "\(Int(sec))″" : nil
                guard let label else { return Tick(option: o, major: false, label: nil) }
                // 整档都是长刻度，但数字隔一个标一次（8000、2000、500、125 …），刻度密时不挤在一起。
                defer { majorCount += 1 }
                return Tick(option: o, major: true, label: majorCount % 2 == 0 ? label : nil)
            }, extras)
        case .aperture:
            // F 值从小到大；整档 F1、1.4、2、2.8、4、5.6、8、11、16、22、32。
            let full: Set<Int64> = [100, 140, 200, 280, 400, 560, 800, 1100, 1600, 2200, 3200]
            return (setting.options.filter { $0.value > 0 }.sorted { $0.value < $1.value }.map { o in
                let major = full.contains(o.value)
                let label = o.value % 100 == 0 ? "\(o.value / 100)" : String(format: "%.1f", Double(o.value) / 100)
                return Tick(option: o, major: major, label: major ? label : nil)
            }, setting.options.filter { $0.value <= 0 })
        case .exposureCompensation:
            // 相机给的是 1/1000 EV，负数可能以无符号 16 位传来。
            let sorted = setting.options.map { ($0, Int(Int16(truncatingIfNeeded: $0.value))) }.sorted { $0.1 < $1.1 }
            return (sorted.map { o, ev in
                Tick(option: o, major: ev % 1000 == 0, label: ev % 1000 == 0 ? (ev == 0 ? "0" : String(format: "%+d", ev / 1000)) : nil)
            }, [])
        default:
            // ISO：低 24 位是感光度。高字节 0x10 是扩展感光度（α7 V 实测：50 = 0x10000032，64000 = 0x1000FA00），
            // 照样放在数轴上；AUTO（0xFFFFFF）和其他高位（多帧降噪等）不在数轴上。
            func iso(_ v: Int64) -> Int64? {
                let low = v & 0x00FF_FFFF, high = v >> 24
                return (high == 0 || high == 0x10) && low != 0x00FF_FFFF && low > 0 ? low : nil
            }
            let numeric = setting.options.compactMap { o in iso(o.value).map { (o, $0) } }.sorted { $0.1 < $1.1 }
            let extras = setting.options.filter { iso($0.value) == nil }
            return (numeric.map { o, v in
                let r = log2(Double(v) / 100)
                let major = abs(r - r.rounded()) < 0.01
                return Tick(option: o, major: major, label: major ? Self.isoText(v) : nil, extended: o.value >> 24 == 0x10)
            }, extras)
        }
    }

    private static func isoText(_ v: Int64) -> String {
        v < 10_000 ? "\(v)" : (v % 1000 == 0 ? "\(v / 1000)K" : String(format: "%.1fK", Double(v) / 1000))
    }

    var body: some View {
        let (ticks, extras) = Self.layout(setting)
        let currentIndex = ticks.firstIndex { $0.option.value == (selected ?? setting.currentValue) }
        // 快门有 50 多档：刻度密一点，弹出框不至于太宽（数字隔一个整档标一次，见 layout）。
        let spacing: CGFloat = ticks.count > 40 ? 8 : 12
        let width = max(CGFloat(ticks.count - 1) * spacing, 200)
        VStack(spacing: 12) {
            if !extras.isEmpty { HStack(spacing: 8) {
                Spacer()
                ForEach(extras) { o in
                    Button { choose(o.value) } label: {
                        Text(o.label).font(.system(size: 12, weight: .medium))
                            .lineLimit(1).fixedSize()
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(o.value == setting.currentValue ? Color.accentColor : Color.primary.opacity(0.1)))
                            .foregroundStyle(o.value == setting.currentValue ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            } }
            ZStack(alignment: .topLeading) {
                ForEach(Array(ticks.enumerated()), id: \.offset) { i, t in
                    let x = position(i, ticks.count, width)
                    Rectangle()
                        .fill(i == currentIndex ? Color.accentColor : Color.primary.opacity((t.major ? 0.7 : 0.35) * (t.extended ? 0.5 : 1)))
                        .frame(width: i == currentIndex ? 2 : 1, height: t.major ? 16 : 9)
                        .position(x: x, y: t.major ? 8 : 12)
                    if let label = t.label {
                        Text(label)
                            .font(.system(size: 10, weight: label == "0" || label == "100" ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(t.extended ? .tertiary : .secondary)
                            .fixedSize()
                            .position(x: x, y: 28)
                    }
                }
                if let c = currentIndex {
                    Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor)
                        .position(x: position(c, ticks.count, width), y: -6)
                }
                if let h = hover, h != currentIndex {
                    RoundedRectangle(cornerRadius: 1).fill(Color.primary).frame(width: 2, height: 18)
                        .position(x: position(h, ticks.count, width), y: 9)
                }
            }
            .frame(width: width, height: 34)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let i = index(at: g.location.x - 12, width: width, count: ticks.count)
                    hover = i
                    if ticks.indices.contains(i) { preview = ticks[i].option.value }
                }
                .onEnded { g in
                    let i = index(at: g.location.x - 12, width: width, count: ticks.count)
                    hover = nil
                    preview = nil
                    if ticks.indices.contains(i) { choose(ticks[i].option.value) }
                })
            // 指针在刻度上移动时，底部参数条就显示指着的值（点按才发给相机）；移开恢复。
            .onContinuousHover { phase in
                if case .active(let p) = phase {
                    let i = index(at: p.x - 12, width: width, count: ticks.count)
                    hover = i
                    preview = ticks.indices.contains(i) ? ticks[i].option.value : nil
                } else {
                    hover = nil
                    preview = nil
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(setting.kind.title)
            .accessibilityValue(setting.valueText)
            .accessibilityAdjustableAction { dir in
                let c = currentIndex ?? (dir == .increment ? -1 : ticks.count)
                let n = dir == .increment ? min(ticks.count - 1, c + 1) : max(0, c - 1)
                if ticks.indices.contains(n) { choose(ticks[n].option.value) }
            }
        }
        .frame(width: width + 24)
        .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
    }

    private func position(_ i: Int, _ count: Int, _ width: CGFloat) -> CGFloat {
        count > 1 ? CGFloat(i) / CGFloat(count - 1) * width : width / 2
    }

    private func index(at x: CGFloat, width: CGFloat, count: Int) -> Int {
        guard count > 1 else { return 0 }
        return min(count - 1, max(0, Int((x / width * CGFloat(count - 1)).rounded())))
    }
}

/// 曝光模式：一排方块（和白平衡弹出框同一种样式），字母在上、中文名在下。
struct ExposurePicker: View {
    let letters: [String]
    let current: String?
    let choose: (String) -> Void
    @State private var hover: String?

    var body: some View {
        HStack(spacing: 4) {
            ForEach(letters, id: \.self) { l in
                let on = l == current
                Button { choose(l) } label: {
                    VStack(spacing: 5) {
                        Text(l == "auto" ? "AUTO" : l.uppercased()).font(.system(size: 13, weight: .bold, design: .rounded)).frame(height: 18)
                        Text(Self.name(l)).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .frame(width: 54, height: 48)
                    .foregroundStyle(on ? Color.white : Color.primary)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(on ? Color.accentColor : Color.primary.opacity(hover == l ? 0.14 : 0.06)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { h in hover = h ? l : (hover == l ? nil : hover) }
                .accessibilityLabel(Self.name(l))
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(14)
    }

    static func name(_ l: String) -> String {
        switch l {
        case "auto": String(localized: "智能自动")
        case "p": String(localized: "程序自动")
        case "a": String(localized: "光圈优先")
        case "s": String(localized: "快门优先")
        default: String(localized: "手动曝光")
        }
    }
}

/// 白平衡弹出框：一排模式图标（和相机里一样按相机报告的顺序），选中色温时下面是色温刻度（低色温偏蓝在左，高色温偏暖在右）。
/// 悬停图标或刻度时底部参数条显示指着的值；点按才发给相机。A–B、G–M 微调在右侧栏。
struct WhiteBalancePicker: View {
    let setting: CameraSetting
    let temperature: SonyPropertyDesc?
    let enabled: Bool
    @Binding var preview: Int64?
    @Binding var tempPreview: Int64?
    var selected: Int64?
    var tempSelected: Int64?
    let choose: (Int64) -> Void
    let chooseTemp: (Int64) -> Void
    @State private var hoverTile: Int64?
    @State private var hoverTick: Int?

    private static let tileWidth: CGFloat = 54
    private static let tileGap: CGFloat = 4

    /// 模式图标的顺序：相机给的顺序，但色温（K）排在第二位（AWB 之后）。
    static func ordered(_ options: [SettingOption]) -> [SettingOption] {
        var list = options
        guard let i = list.firstIndex(where: { $0.value == 0x8012 }), list.count > 1 else { return list }
        let k = list.remove(at: i)
        list.insert(k, at: 1)
        return list
    }

    var body: some View {
        let current = selected ?? setting.currentValue
        let rowWidth = CGFloat(setting.options.count) * Self.tileWidth + CGFloat(max(0, setting.options.count - 1)) * Self.tileGap
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Self.tileGap) {
                ForEach(Self.ordered(setting.options)) { o in tile(o, on: o.value == current) }
            }
            if current == 0x8012, let t = temperature, case let .range(lo, hi, step) = t.form, hi > lo, step > 0 {
                temperatureScale(t, values: Array(stride(from: lo, through: hi, by: Int(step))), width: max(rowWidth, 420) - 24)
            }
        }
        .padding(14)
    }

    private func tile(_ o: SettingOption, on: Bool) -> some View {
        let (glyph, name) = Self.face(o)
        return Button { choose(o.value) } label: {
            VStack(spacing: 5) {
                glyph.frame(height: 18)
                Text(name).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: Self.tileWidth, height: 48)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(on ? Color.accentColor : Color.primary.opacity(hoverTile == o.value ? 0.14 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { h in
            hoverTile = h ? o.value : (hoverTile == o.value ? nil : hoverTile)
            preview = hoverTile
        }
        .help(o.label)
        .accessibilityLabel(o.label)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// 图标和短名：用 SF Symbols 里最接近相机图标的。
    static func face(_ o: SettingOption) -> (AnyView, String) {
        func symbol(_ n: String) -> AnyView { AnyView(Image(systemName: n).font(.system(size: 16))) }
        func badge(_ t: String) -> AnyView { AnyView(Text(t).font(.system(size: 13, weight: .bold, design: .rounded))) }
        switch o.value {
        case 0x0002: return (badge("AWB"), String(localized: "自动"))
        case 0x0004: return (symbol("sun.max"), String(localized: "日光"))
        case 0x8010: return (symbol("cloud"), String(localized: "阴天"))
        case 0x8011: return (symbol("house"), String(localized: "阴影"))
        case 0x0006: return (symbol("lightbulb"), String(localized: "白炽灯"))
        case 0x0005, 0x8001...0x8004: return (symbol("light.panel"), o.label.replacingOccurrences(of: "荧光灯 ", with: "荧光"))
        case 0x0007: return (symbol("bolt"), String(localized: "闪光灯"))
        case 0x8012: return (badge("K"), String(localized: "色温"))
        case 0x8020...0x8022: return (symbol("\(o.value - 0x8020 + 1).square"), String(localized: "自定义 \(o.value - 0x8020 + 1)"))
        case 0x8023: return (symbol("square.dashed"), String(localized: "自定义"))
        case 0x8030: return (symbol("drop"), String(localized: "水下"))
        default: return (badge("WB"), o.label)
        }
    }

    private func temperatureScale(_ t: SonyPropertyDesc, values: [Int64], width: CGFloat) -> some View {
        let current = tempSelected ?? t.intValue
        let ci = values.firstIndex { $0 == current }
        let active = enabled && t.isWritable
        func x(_ i: Int) -> CGFloat { values.count > 1 ? CGFloat(i) / CGFloat(values.count - 1) * width : width / 2 }
        func index(_ px: CGFloat) -> Int {
            guard values.count > 1 else { return 0 }
            return min(values.count - 1, max(0, Int((px / width * CGFloat(values.count - 1)).rounded())))
        }
        return ZStack(alignment: .topLeading) {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                let major = v % 1000 == 0
                Rectangle()
                    .fill(i == ci ? Color.accentColor : Color.primary.opacity(major ? 0.7 : 0.3))
                    .frame(width: i == ci ? 2 : 1, height: major ? 14 : 8)
                    .position(x: x(i), y: major ? 7 : 10)
                if major {
                    Text(verbatim: String(v)).font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        .fixedSize().position(x: x(i), y: 34)
                }
            }
            Capsule()
                .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.55, blue: 1), Color(white: 0.92), Color(red: 1, green: 0.72, blue: 0.25)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(width: width, height: 3).opacity(0.7)
                .position(x: width / 2, y: 20)
            if let ci {
                Image(systemName: "arrowtriangle.down.fill").font(.system(size: 8)).foregroundStyle(Color.accentColor)
                    .position(x: x(ci), y: -6)
            }
            if let h = hoverTick, h != ci {
                RoundedRectangle(cornerRadius: 1).fill(Color.primary).frame(width: 2, height: 16).position(x: x(h), y: 8)
            }
        }
        .frame(width: width, height: 42)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .opacity(active ? 1 : 0.4)
        .allowsHitTesting(active)
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in let i = index(g.location.x - 12); hoverTick = i; tempPreview = values[i] }
            .onEnded { g in hoverTick = nil; tempPreview = nil; chooseTemp(values[index(g.location.x - 12)]) })
        .onContinuousHover { phase in
            if case .active(let p) = phase { let i = index(p.x - 12); hoverTick = i; tempPreview = values[i] }
            else { hoverTick = nil; tempPreview = nil }
        }
        .help(active ? "色温：点按选择，或滚动鼠标滚轮调整" : "当前设置下色温由相机决定")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("色温")
        .accessibilityValue(current.map { "\($0)K" } ?? "—")
        .accessibilityAdjustableAction { dir in
            guard let c = ci else { return }
            let n = dir == .increment ? min(values.count - 1, c + 1) : max(0, c - 1)
            chooseTemp(values[n])
        }
    }
}

/// 斑马纹的自定义设置：拖滑块或直接输入百分比，改动立刻作用到取景上。
struct ZebraSettings: View {
    @Binding var mode: String
    @Binding var level: Int
    @Binding var center: Int
    @Binding var range: Int

    var body: some View {
        let lower = ViewfinderAidOptions.ZebraMode.lowerLimit.rawValue
        VStack(alignment: .leading, spacing: 12) {
            Picker("模式", selection: $mode) {
                Text("下限").tag(lower)
                Text("范围").tag(ViewfinderAidOptions.ZebraMode.range.rawValue)
            }
            .pickerStyle(.segmented).labelsHidden()
            if mode == lower {
                row("阈值", $level, 0...100, prefix: "")
                Text("亮度不低于 \(level)% 的地方显示斜纹").font(Theme.Font.caption).foregroundStyle(.secondary)
            } else {
                row("中心", $center, 0...100, prefix: "")
                row("宽度", $range, 1...25, prefix: "±")
                Text("亮度在 \(max(0, center - range))%–\(min(100, center + range))% 之间的地方显示斜纹")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func row(_ title: LocalizedStringKey, _ value: Binding<Int>, _ bounds: ClosedRange<Int>, prefix: String) -> some View {
        HStack(spacing: 8) {
            Text(title).frame(width: 30, alignment: .leading)
            Slider(value: Binding(get: { Double(value.wrappedValue) },
                                  set: { value.wrappedValue = Int($0.rounded()) }),
                   // 不传 step：macOS 会给每一步画一个刻度，101 个刻度挤成滑块下面的一条虚线。取整放在上面的 set 里。
                   in: Double(bounds.lowerBound)...Double(bounds.upperBound))
                .accessibilityLabel(title)
            Text(prefix).foregroundStyle(.secondary)
            TextField(title, value: Binding(get: { value.wrappedValue },
                                            set: { value.wrappedValue = min(bounds.upperBound, max(bounds.lowerBound, $0)) }),
                      format: .number)
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .frame(width: 44).labelsHidden()
            Text("%").foregroundStyle(.secondary)
        }
        .monospacedDigit()
    }
}
