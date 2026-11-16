import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

/// 联机拍摄窗口：左边是取景和相机式的参数条，右边是本次拍摄、图像设置和导入去向。关窗口即结束联机。
struct TetherWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let t = model.tether {
                TetherView(session: t)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("没有正在联机拍摄的相机").font(Theme.Font.headline)
                    Text("在来源页的相机上点右键，或在浏览已连接的索尼相机时选择“文件 > 联机拍摄”。")
                        .font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
        // 整个联机窗口用深色（和取景、参数条一致，看片时也不被浅色界面干扰）。
        .preferredColorScheme(.dark)
        .onDisappear { model.stopTether() }
        .onChange(of: model.tether == nil) { _, ended in if ended { dismissWindow(id: "tether") } }
    }
}

struct TetherView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: TetherSession
    @AppStorage("tetherGrid") private var grid = false
    @State private var hovered: CameraSettingKind?
    @State private var picking: CameraSettingKind?
    /// 在刻度条上拖动时的预览值：底部参数条直接显示它，松手才发给相机。
    @State private var preview: Int64?
    /// 已选、等相机回读的值（避免松手后底部先跳回旧值）。
    @State private var pending: (kind: CameraSettingKind, value: Int64)?
    /// 白平衡弹出框里色温刻度的悬停值、已选等回读的色温（K）。
    @State private var tempPreview: Int64?
    @State private var tempPending: Int64?
    @State private var scrollMonitor: Any?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                viewfinder
                controlBar
            }
            // 黑底只铺在内容区，不伸到标题栏下面。
            .background(Color.black, ignoresSafeAreaEdges: [])
            .environment(\.colorScheme, .dark)
            Divider()
            TetherSidebar(session: session).frame(width: 320)
        }
        .navigationTitle(session.cameraName)
        .navigationSubtitle(session.lost ? "已断开" : "联机拍摄")
        .toolbar {
            ToolbarItem(placement: .principal) { modePicker }
            ToolbarItem(placement: .primaryAction) { statusItems }
        }
        .onAppear(perform: installScrollMonitor)
        // 相机报告的值和刚选的一致后就不再需要占位（之后滚轮等改动照常显示）。
        .onChange(of: session.status.settings) { _, settings in
            if let p = pending, settings.first(where: { $0.kind == p.kind })?.currentValue == p.value { pending = nil }
        }
        .onChange(of: session.properties[0xD20F]?.intValue) { _, k in if k == tempPending { tempPending = nil } }
        .onDisappear { if let m = scrollMonitor { NSEvent.removeMonitor(m) }; scrollMonitor = nil }
    }

    // MARK: 顶部：拍照 / 录像 / S&Q、电量、存储卡

    private var modePicker: some View {
        let modes = availableModes
        return Picker("拍摄模式", selection: Binding(
            get: { session.shootingMode ?? .photo },
            set: { m in
                Task {
                    do { _ = try await session.switchMode(to: m) }
                    catch { session.message = (error as? AgentControlError)?.message ?? error.localizedDescription }
                }
            })) {
            ForEach(modes, id: \.self) { m in Text(TetherSession.modeTitle(m)).tag(m) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(session.lost || session.busy != nil || session.shootingMode == nil || session.status.isRecording)
        .help("切换拍照、录像、S&Q。相机拨杆位置不影响；需要时会临时改为电脑优先，结束联机时改回。")
    }

    private var availableModes: [SonyPropertyCatalog.ShootingMode] {
        let allowed = session.properties[SonyProperty.exposureProgramMode]?.allowedValues ?? []
        let list = SonyPropertyCatalog.ShootingMode.allCases.filter {
            allowed.isEmpty ? $0 != .sq : SonyPropertyCatalog.exposureProgram($0, exposure: "m", allowed: allowed) != nil
        }
        return list.isEmpty ? [.photo] : list
    }

    private var statusItems: some View {
        HStack(spacing: 14) {
            // 剩余张数只在拍照时有意义（录像时相机报 0）。
            ForEach([(1, UInt16(0xD249)), (2, UInt16(0xD257))], id: \.0) { slot, code in
                if session.shootingMode == .photo, let n = session.properties[code]?.intValue, n >= 0 {
                    Label("\(n)", systemImage: "sdcard")
                        .help("卡槽 \(slot) 还能拍约 \(n) 张")
                }
            }
            if let b = session.properties[0xD218]?.intValue, b >= 0 {
                Label("\(b)%", systemImage: b > 75 ? "battery.100" : b > 50 ? "battery.75" : b > 25 ? "battery.50" : "battery.25")
                    .foregroundStyle(b <= 15 ? Color.red : Color.primary)
                    .help("电量")
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
    }

    // MARK: 取景

    private var viewfinder: some View {
        ZStack {
            if let img = session.liveFrame {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .overlay { if grid { ThirdsGrid().stroke(.white.opacity(0.35), lineWidth: 0.5) } }
                    .overlay { touchLayer }
                    .accessibilityLabel("实时取景")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: session.lost ? "wifi.slash" : session.liveViewOn ? "camera.viewfinder" : "eye.slash")
                        .font(.system(size: 30, weight: .light))
                    Text(session.lost ? "相机已断开" : session.liveViewOn ? "正在等待取景画面…" : "实时取景已关闭")
                        .font(Theme.Font.caption)
                }
                .foregroundStyle(.white.opacity(0.55))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                if session.focusLocked || session.status.isFocused {
                    chip(session.status.isFocused ? "已合焦" : "对焦中", systemImage: "scope",
                         color: session.status.isFocused ? .green : .yellow)
                }
                Spacer()
                if session.status.isRecording { recordingChip }
                Spacer()
                if let b = session.busy {
                    chip(b, systemImage: nil, color: .white, progress: true)
                } else if let m = session.message {
                    chip(m, systemImage: "exclamationmark.triangle.fill", color: .orange)
                        .onTapGesture { session.message = nil }
                        .help("点按关闭")
                }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomTrailing) {
            if session.downloading || session.status.pendingTransfers > 0 {
                chip("正在接收照片", systemImage: nil, color: .white, progress: true).padding(10)
            }
        }
    }

    /// 点按取景画面对焦（覆盖在画面上，和画面同样大小，不含上下黑边）；点过的位置画对焦框。
    private var touchLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(coordinateSpace: .local) { loc in
                    guard geo.size.width > 0, geo.size.height > 0 else { return }
                    session.touch(CGPoint(x: loc.x / geo.size.width, y: loc.y / geo.size.height))
                }
                .contextMenu {
                    Button("取消触摸对焦") { session.cancelTouch() }.disabled(!session.canCancelTouch)
                }
            // 相机送来对焦框时照相机画：跟踪框、人脸框一直画；对焦框只画小的（自由点等）和合焦的，不画「广域」那种大框。
            // 相机没送时（较老的机身），在点过的位置画一个框。
            if let info = session.focalFrames {
                ForEach(Array(info.frames.enumerated()), id: \.offset) { _, f in
                    if f.kind != .focus || f.focused || f.w < 0.5 {
                        Rectangle()
                            .stroke(f.focused ? Color.green : Color.white, lineWidth: f.kind == .face ? 1 : 1.5)
                            .frame(width: max(f.w * geo.size.width, 12), height: max(f.h * geo.size.height, 12))
                            .shadow(color: .black.opacity(0.5), radius: 1)
                            .position(x: f.cx * geo.size.width, y: f.cy * geo.size.height)
                            .allowsHitTesting(false)
                    }
                }
            } else if let t = session.touchPoint {
                RoundedRectangle(cornerRadius: 2)
                    .stroke(session.status.isFocused ? Color.green : Color.white, lineWidth: 1.5)
                    .frame(width: 56, height: 56)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .position(x: t.x * geo.size.width, y: t.y * geo.size.height)
                    .allowsHitTesting(false)
            }
        }
        .help("点按画面对焦（按机身的触摸功能对焦或跟踪），Esc 或右键取消")
    }

    private var recordingChip: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = Int(ctx.date.timeIntervalSince(session.recordingSince ?? ctx.date))
            HStack(spacing: 6) {
                Circle().fill(.red).frame(width: 8, height: 8)
                Text(String(format: "REC %02d:%02d", s / 60, s % 60)).monospacedDigit()
            }
            .font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.black.opacity(0.6), in: Capsule())
        }
    }

    private func chip(_ text: String, systemImage: String?, color: Color, progress: Bool = false) -> some View {
        HStack(spacing: 6) {
            if progress { ProgressView().controlSize(.mini) }
            if let systemImage { Image(systemName: systemImage) }
            Text(text).lineLimit(2)
        }
        .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.6), in: Capsule())
        .frame(maxWidth: 360, alignment: .trailing)
    }

    // MARK: 底部参数条（相机屏幕底栏的排法）

    private var controlBar: some View {
        HStack(spacing: 4) {
            modeCell
            ForEach(session.status.settings) { s in settingCell(s) }
            if session.status.settings.isEmpty {
                Text("正在读取相机设置…").font(.system(size: 12)).foregroundStyle(.secondary).padding(.leading, 8)
            }
            Spacer(minLength: 12)
            barToggle(grid, "square.grid.3x3", "网格线") { grid.toggle() }
            barToggle(!session.liveViewOn, session.liveViewOn ? "eye" : "eye.slash", session.liveViewOn ? "关闭取景（照片接收更快）" : "打开取景") {
                session.liveViewOn.toggle()
            }
            barToggle(session.focusLocked, "scope", "锁定对焦：相当于半按快门（F）") { session.setFocusLock(!session.focusLocked) }
                .keyboardShortcut("f", modifiers: [])
            // Esc 取消触摸对焦（看不见的按钮，只为快捷键）。
            Button("取消触摸对焦") { session.cancelTouch() }
                .keyboardShortcut(.escape, modifiers: [])
                .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                .disabled(!session.canCancelTouch)
            recordButton.padding(.leading, 6)
            shutterButton.padding(.leading, 4)
        }
        .padding(.horizontal, 12)
        .frame(height: 76)
        .background(Color(white: 0.09))
        .disabled(session.lost)
    }

    private var modeCell: some View {
        // 只显示曝光字母（录像、S&Q 已在顶部的切换里体现）；不认识的模式显示相机给的名字。
        let raw = session.properties[SonyProperty.exposureProgramMode]?.intValue
        let letter = raw.flatMap(SonyPropertyCatalog.shootingMode)?.exposure
        let text = letter.map { $0 == "auto" ? "AUTO" : $0.uppercased() }
            ?? session.status.modeText.split(separator: " ").first.map(String.init) ?? "—"
        return VStack(spacing: 3) {
            Text("模式").font(.system(size: 10)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 17, weight: .semibold))
        }
        .frame(minWidth: 44)
        .padding(.horizontal, 6)
        .help(session.status.modeText)
    }

    private func settingCell(_ s: CameraSetting) -> some View {
        let isHovered = hovered == s.kind && s.isEditable
        return Button { picking = picking == s.kind ? nil : s.kind; preview = nil } label: {
            VStack(spacing: 3) {
                Text(s.kind.title).font(.system(size: 10)).foregroundStyle(.secondary)
                // 宽度按选项里最长的那个预留：值从 800 变成 51200 时，右边的格子不会跟着挪动。
                // 「多帧NR AUTO」这类很少用的长名字不算，真选中时格子才变宽。
                ZStack {
                    ForEach(reserveTexts(s), id: \.self) { Text($0).hidden() }
                    Text(cellValue(s))
                        .foregroundStyle(s.isEditable ? .primary : .tertiary)
                }
                .font(.system(size: 17, weight: .medium).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 64)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(isHovered || picking == s.kind ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!s.isEditable)
        .onHover { hovered = $0 ? s.kind : (hovered == s.kind ? nil : hovered) }
        .help(s.isEditable ? "\(s.kind.title)：点按选择，或把指针放在上面滚动调整" : "当前拍摄模式下\(s.kind.title)由相机决定")
        .accessibilityLabel(s.kind.title)
        .accessibilityValue(cellValue(s))
        .popover(isPresented: Binding(get: { picking == s.kind }, set: { if !$0 { picking = nil; preview = nil; tempPreview = nil } }), arrowEdge: .top) {
            if s.kind != .whiteBalance {
                // 快门、光圈、ISO、曝光补偿都是 1/3 档、选项多：用横向刻度条。
                ScalePicker(setting: s, preview: $preview, selected: pending?.kind == s.kind ? pending?.value : nil) { v in choose(s.kind, v) }
            } else {
                // 白平衡：一排模式图标；选中色温时下面是色温刻度。
                WhiteBalancePicker(setting: s, temperature: session.properties[0xD20F], enabled: !session.lost,
                                   preview: $preview, tempPreview: $tempPreview,
                                   selected: pending?.kind == s.kind ? pending?.value : nil, tempSelected: tempPending,
                                   choose: chooseWhiteBalance, chooseTemp: setTemperature)
            }
        }
    }

    private func choose(_ kind: CameraSettingKind, _ v: Int64) {
        pending = (kind, v)
        session.set(kind, value: v)
        picking = nil
        preview = nil
        // 相机没接受时 3 秒后恢复显示相机报告的值。
        Task { try? await Task.sleep(for: .seconds(3)); if pending?.kind == kind, pending?.value == v { pending = nil } }
    }

    /// 白平衡选色温时弹出框不关，下面出现色温刻度；选其它模式就关掉。
    private func chooseWhiteBalance(_ v: Int64) {
        pending = (.whiteBalance, v)
        session.set(.whiteBalance, value: v)
        preview = nil
        if v != 0x8012 { picking = nil }
        Task { try? await Task.sleep(for: .seconds(3)); if pending?.kind == .whiteBalance, pending?.value == v { pending = nil } }
    }

    private func setTemperature(_ k: Int64) {
        tempPreview = nil
        tempPending = k
        session.setProperty(0xD20F, k)
        Task { try? await Task.sleep(for: .seconds(3)); if tempPending == k { tempPending = nil } }
    }

    /// 色温模式下滚轮调色温（一格 = 相机的一档，通常 100K）。不能调时返回 false。
    private func stepTemperature(_ delta: Int) -> Bool {
        guard let d = session.properties[0xD20F], d.isWritable, case let .range(lo, hi, step) = d.form,
              let cur = tempPending ?? d.intValue else { return false }
        let v = min(hi, max(lo, cur + Int64(delta) * step))
        if v != cur { setTemperature(v) }
        return true
    }

    /// 底部格子按这些文字里最宽的预留宽度。白平衡后面带微调（A5 M2.75），每种模式和「8888K」都带上同样的微调来算，
    /// 在日光、色温之间切换时格子不变宽窄。
    private func reserveTexts(_ s: CameraSetting) -> [String] {
        let labels = s.options.map(\.label).filter { $0.count <= 7 }
        guard s.kind == .whiteBalance else { return labels }
        let tint = wbTint().map { " " + $0 } ?? ""
        return (labels + ["8888K"]).map { $0 + tint }
    }

    /// 白平衡微调的显示（A5 M2.75），都为 0 时为 nil。
    private func wbTint() -> String? {
        let p = session.properties
        let tint = [UInt16(0xD21C), 0xD210].compactMap { c in p[c]?.intValue.flatMap { SonyPropertyCatalog.label(c, $0) } }.filter { $0 != "0" }
        return tint.isEmpty ? nil : tint.joined(separator: " ")
    }

    /// 白平衡在色温或自定义时显示 K 值和微调，其余显示模式名。
    private func cellValue(_ s: CameraSetting) -> String {
        let hoverValue = picking == s.kind ? preview : nil
        let pendingValue = pending.flatMap { $0.kind == s.kind && $0.value != s.currentValue ? $0.value : nil }
        guard s.kind == .whiteBalance else {
            if let v = hoverValue ?? pendingValue, let o = s.options.first(where: { $0.value == v }) { return o.label }
            return s.valueText
        }
        guard let wb = hoverValue ?? pendingValue ?? s.currentValue else { return s.valueText }
        let p = session.properties
        var text = s.options.first { $0.value == wb }?.label ?? s.valueText
        // 悬停在别的模式上只显示模式名（那个模式的色温、微调要切过去才知道）。
        if hoverValue != nil, hoverValue != s.currentValue { return text }
        let k = (picking == s.kind ? tempPreview : nil) ?? tempPending ?? p[0xD20F]?.intValue
        if wb == 0x8012 || (0x8020...0x8023).contains(wb), let k, k > 0 { text = "\(k)K" }
        return wbTint().map { text + " " + $0 } ?? text
    }

    private func barToggle(_ on: Bool, _ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14))
                .frame(width: 32, height: 32)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(Circle().fill(.white.opacity(on ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }

    private var recordButton: some View {
        let on = session.status.isRecording
        return Button { session.toggleRecording() } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 2).frame(width: 40, height: 40)
                RoundedRectangle(cornerRadius: on ? 3 : 13, style: .continuous).fill(.red)
                    .frame(width: on ? 14 : 26, height: on ? 14 : 26)
            }
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.15), value: on)
        }
        .buttonStyle(.plain)
        .help(on ? "停止录像（录像保存在相机存储卡上）" : "开始录像（录像保存在相机存储卡上）")
        .accessibilityLabel(on ? "停止录像" : "开始录像")
    }

    private var shutterButton: some View {
        Button { session.shoot() } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 3).frame(width: 56, height: 56)
                Circle().fill(.white.opacity(session.shooting ? 0.5 : 1)).frame(width: 44, height: 44)
                if session.shooting { ProgressView().controlSize(.small).tint(.black) }
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .disabled(session.shooting)
        .help("拍摄（空格）")
        .accessibilityLabel("拍摄")
    }

    // MARK: 滚轮调参数

    /// 指针停在某个参数上时，滚轮一格调一档（向上 = 增大）。
    private func installScrollMonitor() {
        guard scrollMonitor == nil else { return }
        var accumulated: CGFloat = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            // 刻度条打开时（快门、光圈、ISO、曝光补偿）：滚轮在弹出框或联机窗口里都调这一项；
            // 没打开时：指针停在底部参数格上才调。
            let inTether = event.window?.title.contains(session.cameraName) == true
            let inPopover = event.window.map { String(describing: type(of: $0)).contains("Popover") } ?? false
            let kind: CameraSettingKind?
            if let k = picking, inTether || inPopover { kind = k }
            else if picking == nil, inTether { kind = hovered }
            else { kind = nil }
            guard let kind, session.status.settings.first(where: { $0.kind == kind })?.isEditable == true else { return event }
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            accumulated += dy
            if abs(accumulated) >= 1 {
                scrollStep(kind, accumulated > 0 ? 1 : -1)
                accumulated = 0
            }
            return nil
        }
    }

    /// 滚轮一格：向上 = 刻度条上往右一档（快门、光圈、ISO、曝光补偿），白平衡按模式图标从左到右。
    /// 底部数值立刻显示新值（等相机回读期间也不跳回），连续滚动时从刚选的值继续。
    private func scrollStep(_ kind: CameraSettingKind, _ delta: Int) {
        guard let s = session.status.settings.first(where: { $0.kind == kind }) else { return }
        let current = (pending?.kind == kind ? pending?.value : nil) ?? s.currentValue
        // 白平衡弹出框开着且是色温：滚轮调色温；否则按模式图标的顺序换模式。
        if kind == .whiteBalance, picking == .whiteBalance, current == 0x8012, stepTemperature(delta) { return }
        let order = kind == .whiteBalance ? s.options.map(\.value) : ScalePicker.layout(s).ticks.map(\.option.value)
        guard let c = order.firstIndex(where: { $0 == current }) else { return }  // AUTO、BULB 等不在刻度上：不动
        let n = min(order.count - 1, max(0, c + delta))
        guard n != c else { return }
        let v = order[n]
        // 指针停在刻度上时 preview 是悬停的值，会盖住底部显示；滚轮不移动指针，所以这里清掉，让底部跟着滚轮走。
        preview = nil
        pending = (kind, v)
        session.set(kind, value: v)
        Task { try? await Task.sleep(for: .seconds(3)); if pending?.kind == kind, pending?.value == v { pending = nil } }
    }
}

/// 横向刻度条（快门、光圈、ISO、曝光补偿）：每个可选值一条刻度，整档的长一些并标数字。指针移动或拖动时底部参数条显示指着的值，
/// 点按或拖动松手才发给相机。
/// ISO 的 AUTO 这类不在数轴上的选项放在刻度条上方，作为单独的按钮。
private struct ScalePicker: View {
    let setting: CameraSetting
    @Binding var preview: Int64?
    /// 刚选、相机还没回读的值（滚轮连续调整时标记先跟着走）。
    var selected: Int64? = nil
    let choose: (Int64) -> Void
    @State private var hover: Int?

    struct Tick { let option: SettingOption; let major: Bool; let label: String? }

    /// 数轴上的选项（按大小排好）和数轴外的选项（AUTO 等）。
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
            // ISO：低 24 位是感光度；AUTO（0xFFFFFF）和高位不为 0 的（多帧降噪等）不在数轴上。
            let numeric = setting.options.filter { $0.value >> 24 == 0 && $0.value != 0x00FF_FFFF && $0.value > 0 }
            let extras = setting.options.filter { o in !numeric.contains { $0.value == o.value } }
            return (numeric.sorted { $0.value < $1.value }.map { o in
                let r = log2(Double(o.value) / 100)
                let major = abs(r - r.rounded()) < 0.01
                return Tick(option: o, major: major, label: major ? Self.isoText(o.value) : nil)
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
                        .fill(i == currentIndex ? Color.accentColor : Color.primary.opacity(t.major ? 0.7 : 0.35))
                        .frame(width: i == currentIndex ? 2 : 1, height: t.major ? 16 : 9)
                        .position(x: x, y: t.major ? 8 : 12)
                    if let label = t.label {
                        Text(label)
                            .font(.system(size: 10, weight: label == "0" || label == "100" ? .semibold : .regular).monospacedDigit())
                            .foregroundStyle(.secondary)
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

/// 白平衡弹出框：一排模式图标（和相机里一样按相机报告的顺序），选中色温时下面是色温刻度（低色温偏蓝在左，高色温偏暖在右）。
/// 悬停图标或刻度时底部参数条显示指着的值；点按才发给相机。A–B、G–M 微调在右侧栏。
private struct WhiteBalancePicker: View {
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

    var body: some View {
        let current = selected ?? setting.currentValue
        let rowWidth = CGFloat(setting.options.count) * Self.tileWidth + CGFloat(max(0, setting.options.count - 1)) * Self.tileGap
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: Self.tileGap) {
                ForEach(setting.options) { o in tile(o, on: o.value == current) }
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
        case 0x0002: return (badge("AWB"), "自动")
        case 0x0004: return (symbol("sun.max"), "日光")
        case 0x8010: return (symbol("cloud"), "阴天")
        case 0x8011: return (symbol("house"), "阴影")
        case 0x0006: return (symbol("lightbulb"), "白炽灯")
        case 0x0005, 0x8001...0x8004: return (symbol("light.panel"), o.label.replacingOccurrences(of: "荧光灯 ", with: "荧光"))
        case 0x0007: return (symbol("bolt"), "闪光灯")
        case 0x8012: return (badge("K"), "色温")
        case 0x8020...0x8022: return (symbol("\(o.value - 0x8020 + 1).square"), "自定义 \(o.value - 0x8020 + 1)")
        case 0x8023: return (symbol("square.dashed"), "自定义")
        case 0x8030: return (symbol("drop"), "水下")
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

private struct ThirdsGrid: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        return p
    }
}

// MARK: 侧栏：本次拍摄、图像设置、导入

private struct TetherSidebar: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: TetherSession
    /// 收起的分组（标题，用换行分隔），下次打开联机窗口时沿用。
    @AppStorage("tetherCollapsedSections") private var collapsedSections = ""
    @AppStorage("tetherPullSeconds") private var pullSeconds = 2.0

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    review.padding(14)
                    Hairline()
                    whiteBalanceCard.padding(.horizontal, 14).padding(.vertical, 12)
                    movieCard
                    focusCard
                    shootingCard
                    lookCard
                    photoCard
                    lensCard
                }
            }
            Hairline()
            importBar
        }
        .background(TetherStyle.sidebar)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
    }

    private func isCollapsed(_ t: String) -> Bool { collapsedSections.split(separator: "\n").contains { $0 == t } }

    /// 可点的分组标题：点整行收起或展开，箭头朝右是收起、朝下是展开。trailing 放在标题右边（例如张数）。
    private func collapsibleTitle(_ t: String) -> some View { collapsibleTitle(t) { EmptyView() } }

    private func collapsibleTitle<T: View>(_ t: String, @ViewBuilder trailing: () -> T) -> some View {
        let collapsed = isCollapsed(t)
        return Button {
            var set = collapsedSections.split(separator: "\n").map(String.init).filter { $0 != t }
            if !collapsed { set.append(t) }
            withAnimation(.easeInOut(duration: 0.15)) { collapsedSections = set.joined(separator: "\n") }
        } label: {
            HStack(spacing: 4) {
                sectionTitle(t)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                Spacer()
                trailing()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "展开" : "收起")
    }

    // MARK: 本次拍摄

    private var current: TetherShot? {
        session.reviewedShotID.flatMap { id in session.shots.first { $0.id == id } } ?? session.shots.first
    }

    private var review: some View {
        let shot = current
        let image = session.reviewedShotID == nil ? session.lastShotImage : session.reviewImage
        let exif = session.reviewedShotID == nil ? session.lastShotExif : session.reviewExif
        return VStack(alignment: .leading, spacing: 8) {
            collapsibleTitle("本次拍摄") {
                if !session.shots.isEmpty {
                    Text("\(session.shots.count) 张").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            if !isCollapsed("本次拍摄") { reviewBody(shot: shot, image: image, exif: exif) }
        }
    }

    @ViewBuilder private func reviewBody(shot: TetherShot?, image: NSImage?, exif: ShotExif?) -> some View {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(TetherStyle.well)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if shot != nil {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "camera").font(.system(size: 20, weight: .light))
                        Text("按空格拍摄").font(.system(size: 11))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onTapGesture(count: 2) { if let u = shot?.display { NSWorkspace.shared.open(u) } }
            .contextMenu {
                if let shot {
                    Button("用默认程序打开") { NSWorkspace.shared.open(shot.display) }
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(shot.files) }
                }
            }
            .help("双击用默认程序打开")
            if let shot {
                HStack(spacing: 6) {
                    Text(shot.id).font(.system(size: 12, weight: .medium))
                    Text(shot.formats).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(TetherStyle.well))
                    Spacer()
                    if session.reviewedShotID != nil {
                        Button("回到最新") { session.reviewedShotID = nil }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
                if let e = exif {
                    if !e.exposureText.isEmpty { Text(e.exposureText).font(.system(size: 11).monospacedDigit()) }
                    if !e.gearText.isEmpty { Text(e.gearText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if session.shots.count > 1 { filmstrip }
    }

    private var filmstrip: some View {
        let selected = current?.id
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 6) {
                ForEach(session.shots) { shot in
                    Button {
                        if shot.id == session.shots.first?.id { session.reviewedShotID = nil } else { session.review(shot) }
                    } label: {
                        ZStack {
                            TetherStyle.well
                            if let t = session.thumbnail(for: shot) { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                        }
                        .frame(width: 54, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(shot.id == selected ? Color.white.opacity(0.9) : .clear, lineWidth: 1.5))
                        .opacity(shot.id == selected ? 1 : 0.7)
                    }
                    .buttonStyle(.plain)
                    .help(shot.id)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 38)
    }

    // MARK: 图像设置（分组卡片：标签在左，值在右）

    private var whiteBalanceCard: some View {
        let p = session.properties
        // 模式和色温在底部白平衡弹出框里选；侧栏只放微调和取白。
        return VStack(alignment: .leading, spacing: 4) {
            collapsibleTitle("白平衡")
            if !isCollapsed("白平衡") { PanelCard {
                if let ab = p[0xD21C], let gm = p[0xD210] {
                    WBShiftPad(session: session, ab: ab, gm: gm)
                }
                if p[0xD270] != nil {
                    if p[0xD21C] != nil, p[0xD210] != nil { PanelDivider() }
                    PanelRow("取白", enabled: session.busy == nil && !session.lost) {
                        Menu {
                            ForEach(1...3, id: \.self) { slot in
                                Button("存入自定义 \(slot)") { captureWB(slot) }
                            }
                        } label: {
                            Label("取白", systemImage: "eyedropper")
                        }
                        .menuStyle(.button).controlSize(.small).fixedSize()
                        .help("先让相机对准灰卡或白纸，再选择存入哪个自定义白平衡。会覆盖该槽位原来的结果。")
                    }
                    if p[0xD135] != nil { PanelDivider() }
                    PropertyRow(session: session, title: "取白框", code: 0xD135)
                }
            } }
        }
    }

    private func captureWB(_ slot: Int) {
        Task {
            do { _ = try await session.customWhiteBalance(slot: slot) }
            catch { session.message = (error as? AgentControlError).map { $0.message.components(separatedBy: " 过程：")[0] } ?? error.localizedDescription }
        }
    }

    /// 拍照时的存储设置。统一记录和分卡槽各有一组属性，哪组可写取决于记录媒体设置：用可写的那组（都不可写时用相机报告了的）。
    private var photoCard: some View {
        let p = session.properties
        func pick(_ codes: [UInt16]) -> [UInt16] {
            (codes.first { p[$0]?.isWritable == true } ?? codes.first { p[$0] != nil }).map { [$0] } ?? []
        }
        let rows: [(String, UInt16)] = pick([0xD28B, 0xD253]).map { ("文件格式", $0) } + [("压缩格式", 0xD287)]
            + pick([0xD28D, 0xD252]).map { ("画质", $0) } + pick([0xD28F, 0xD203]).map { ("图像尺寸", $0) }
            + pick([0xD289, 0xD288]).map { ("RAW 压缩", $0) }
            + [("传到电脑", 0xD269), ("色彩空间", 0xD15E), ("DRO", 0xD201)]
        return propertySection("照片", rows)
    }

    /// 调焦：近 ↔ 远滑块、两个记忆点和拉焦（相机能远程调焦时才显示）。
    @ViewBuilder private var focusCard: some View {
        if let c = session.focusControl, let shown = session.focusShown {
            Hairline()
            VStack(alignment: .leading, spacing: 4) {
                collapsibleTitle("对焦")
                if !isCollapsed("对焦") {
                    PanelCard {
                        FocusSlider(range: c.range, value: shown, marks: session.focusMarks, enabled: !session.lost) {
                            session.moveFocus(to: $0)
                        }
                        if !session.isManualFocus {
                            PanelDivider()
                            PanelRow("自动对焦时相机会重新对焦") {
                                Button("切到 MF") { session.switchToManualFocus() }
                                    .controlSize(.small)
                                    .disabled(session.properties[SonyProperty.focusMode]?.isWritable != true)
                            }
                        }
                        ForEach(["A", "B"], id: \.self) { name in
                            PanelDivider()
                            PanelRow("记忆点 \(name)") {
                                Button("记下") { session.markFocus(name) }
                                    .help("把现在的对焦位置记为 \(name)")
                                Button("拉过去") { session.pullFocus(to: session.focusMarks[name] ?? shown, seconds: pullSeconds) }
                                    .disabled(session.focusMarks[name] == nil)
                                    .help(pullSeconds == 0 ? "直接跳到 \(name)" : "用 \(Self.secondsText(pullSeconds))平滑拉到 \(name)")
                            }
                            .controlSize(.small)
                        }
                        PanelDivider()
                        PanelRow("拉焦时长") {
                            ValueMenu(text: Self.secondsText(pullSeconds), options: [0, 1, 2, 4, 8].map { (Int64($0), Self.secondsText(Double($0))) },
                                      current: Int64(pullSeconds)) { pullSeconds = Double($0) }
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private static func secondsText(_ s: Double) -> String { s == 0 ? "即时" : "\(Int(s)) 秒" }

    /// 对焦和驱动模式（驱动模式只在拍照时可用）。
    private var shootingCard: some View {
        propertySection("拍摄", [("对焦模式", 0x500A), ("驱动模式", 0x5013), ("点按画面", 0xD283)])
    }

    /// 创意外观和各项参数。换外观时各参数会跳到该外观的默认值，相机会回报新值。
    private var lookCard: some View {
        propertySection("创意外观", [("外观", 0xD0FA), ("对比度", 0xD0FB), ("高光", 0xD0FC), ("阴影", 0xD0FD), ("褪色", 0xD0FE),
                                    ("饱和度", 0xD0FF), ("锐度", 0xD100), ("锐度范围", 0xD101), ("清晰度", 0xD102)])
    }

    private var lensCard: some View {
        propertySection("镜头补偿", [("暗角补偿", 0xD1A2), ("色差补偿", 0xD1A3)])
    }

    /// 录像 / S&Q 时的格式、码率、帧率（拍照时不显示）。
    @ViewBuilder private var movieCard: some View {
        switch session.shootingMode {
        // Log 拍摄打开时图片配置文件和伽马 / 色彩模式不可用（相机报告未启用，自动不显示），这时可改 Log 色域、Base Look 和监看 LUT。
        case .movie?: propertySection("录像", [("文件格式", 0xD241), ("码率", 0xD242), ("帧率", 0xD286)] + Self.lookRows)
        case .sq?: propertySection("慢快动作", [("文件格式", 0xD241), ("码率", 0xD0D1), ("记录帧率", 0xD0D0), ("慢快帧率", 0xD052)] + Self.lookRows)
        default: EmptyView()
        }
    }

    private static let lookRows: [(String, UInt16)] = [("Log 拍摄", 0xE000), ("Log 色域", 0xE001), ("图片配置文件", 0xD23F), ("伽马", 0xD0E1), ("色彩模式", 0xD0E9),
                                                       ("Base Look", 0xD03C), ("监看 LUT", 0xD04D)]

    /// 一段属性：相机没报告或不可用的行不显示；一行都没有时整段（连同上面的分隔线）不显示，免得留一条空的。
    @ViewBuilder private func propertySection(_ title: String, _ rows: [(String, UInt16)]) -> some View {
        let p = session.properties
        let shown = rows.filter { r in p[r.1].map { $0.isEnabled != 0 && !$0.allowedValues.isEmpty } ?? false }
        if !shown.isEmpty {
            Hairline()
            VStack(alignment: .leading, spacing: 4) {
                collapsibleTitle(title)
                if !isCollapsed(title) {
                    PanelCard {
                        ForEach(Array(shown.enumerated()), id: \.element.1) { i, r in
                            if i > 0 { PanelDivider() }
                            PropertyRow(session: session, title: r.0, code: r.1)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    // MARK: 导入

    private var importBar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("导入到").foregroundStyle(.secondary)
                Menu(model.currentSession?.name ?? "未选项目") {
                    ForEach(model.sortedSessions.prefix(15)) { s in
                        Button { model.selectSession(s.id) } label: {
                            if s.id == model.currentSessionID { Label(s.name, systemImage: "checkmark") } else { Text(s.name) }
                        }
                    }
                    Divider()
                    Button("在主窗口中新建或选择…") { model.showMainWindow() }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(model.progress != nil)
                Spacer()
                Toggle("自动", isOn: $model.tetherAutoImport).toggleStyle(.switch).controlSize(.mini)
                    .help("拍摄后自动导入当前项目")
            }
            .font(.system(size: 12))
            if let p = model.progress {
                ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1))) {
                    Text("正在导入 \(p.total) 个文件").font(.system(size: 11))
                }
            } else if model.currentSession == nil {
                Text("照片暂存在联机缓存，选好项目后自动导入。").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack {
                Button { NSWorkspace.shared.activateFileViewerSelecting([session.spool.folder]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless).help("在 Finder 中显示联机缓存")
                Spacer()
                if session.lost {
                    Button("重新连接") { if let c = model.lastTetherCamera { model.startTether(c) } }
                        .disabled(model.lastTetherCamera == nil || model.progress != nil)
                }
                Button("结束联机") { model.stopTether() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

// MARK: 面板组件

/// 圆角分组卡片（和系统设置的分组表单同一种层次）。
private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { VStack(spacing: 0) { content } }
}

/// 组内各行之间只留一点空，不画线（分组之间用 Hairline）。
private struct PanelDivider: View {
    var body: some View { Color.clear.frame(height: 2) }
}

/// 联机窗口的深色配色。
enum TetherStyle {
    static let sidebar = Color(white: 0.115)
    static let well = Color(white: 0.165)
    static let hairline = Color.white.opacity(0.07)
}

private struct Hairline: View {
    var body: some View { TetherStyle.hairline.frame(height: 1) }
}

/// 一行：标签在左，值在右。
private struct PanelRow<Trailing: View>: View {
    let title: String
    let enabled: Bool
    @ViewBuilder var trailing: Trailing
    init(_ title: String, enabled: Bool = true, @ViewBuilder trailing: () -> Trailing) {
        self.title = title; self.enabled = enabled; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            trailing.disabled(!enabled)
        }
        .font(.system(size: 12))
        .frame(minHeight: 26)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// 调焦滑块：左近右远（相机的值越大越近，所以反过来画），记忆点 A / B 标在滑块上方。
private struct FocusSlider: View {
    let range: ClosedRange<Int64>
    let value: Int64
    let marks: [String: Int64]
    let enabled: Bool
    let move: (Int64) -> Void

    private func fraction(_ v: Int64) -> Double {
        Double(range.upperBound - v) / Double(range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                ForEach(marks.sorted { $0.key < $1.key }, id: \.key) { name, v in
                    Text(name).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                        .position(x: 8 + fraction(v) * (geo.size.width - 16), y: 5)
                }
            }
            .frame(height: 10)
            Slider(value: Binding(get: { fraction(value) }, set: { f in
                move(range.upperBound - Int64((f * Double(range.upperBound - range.lowerBound)).rounded()))
            }), in: 0...1)
            .controlSize(.small)
            .disabled(!enabled)
            .accessibilityLabel("对焦位置")
            HStack {
                Text("近"); Spacer(); Text("远")
            }
            .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// 右对齐的值 + 上下箭头，点按弹出选项（不带按钮外框）。
private struct ValueMenu: View {
    let text: String
    let options: [(Int64, String)]
    let current: Int64
    let choose: (Int64) -> Void
    var body: some View {
        Menu {
            ForEach(options, id: \.0) { v, label in
                Button { choose(v) } label: {
                    if v == current { Label(label, systemImage: "checkmark") } else { Text(label) }
                }
            }
        } label: {
            // 菜单按钮会把图标放在文字前面：拼成一段文字，箭头才在值的后面。
            Text("\(text) ") + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}

/// 白平衡微调矩阵，照 α7 V 机身的微调画面画：15 × 15 个色块（左上绿、右上黄、左青、中白、右橙、
/// 左下蓝、右下品红），G / M / B / A 写在四边，红色圆点是当前位置。
/// 点按或拖动选位置，松手时按两个轴各自的档位取整后发给相机；读数旁的箭头回到中心。
private struct WBShiftPad: View {
    let session: TetherSession
    let ab: SonyPropertyDesc
    let gm: SonyPropertyDesc
    @State private var dragging: (ab: Int64, gm: Int64)?

    private static let center: Int64 = 192
    private static let cells = 15          // −7 … +7，每格 = 原始值 4
    private static let margin: CGFloat = 13 // 四边留给 G / M / B / A

    var body: some View {
        if case let .range(aLo, aHi, aStep) = ab.form, case let .range(gLo, gHi, gStep) = gm.form,
           aHi > aLo, gHi > gLo, let curA = ab.intValue, let curG = gm.intValue {
            let a = dragging?.ab ?? curA, g = dragging?.gm ?? curG
            let enabled = ab.isWritable && gm.isWritable && !session.lost
            VStack(spacing: 8) {
                HStack {
                    Text("微调").foregroundStyle(.secondary)
                    Spacer()
                    if curA != Self.center || curG != Self.center {
                        Button { reset(curA, curG) } label: { Image(systemName: "arrow.counterclockwise") }
                            .buttonStyle(.borderless).help("回到 0").disabled(!enabled)
                            .accessibilityLabel("微调回到 0")
                    }
                }
                GeometryReader { geo in
                    let side = geo.size.width - Self.margin * 2
                    let cell = side / CGFloat(Self.cells)
                    // 当前值落在色块中心：第 0 格中心 = 最小值，第 14 格中心 = 最大值。
                    let fx = CGFloat(a - aLo) / CGFloat(aHi - aLo)
                    let fy = 1 - CGFloat(g - gLo) / CGFloat(gHi - gLo)
                    ZStack(alignment: .topLeading) {
                        // 格缝是深色（和机身一样），色块之间不露出浅色底。
                        Rectangle().fill(Color(white: 0.05)).frame(width: side, height: side)
                            .offset(x: Self.margin, y: Self.margin)
                        Canvas { ctx, _ in
                            let gap: CGFloat = 1
                            for row in 0..<Self.cells {
                                for col in 0..<Self.cells {
                                    let u = CGFloat(col) / CGFloat(Self.cells - 1) * 2 - 1   // −1 = B，+1 = A
                                    let v = 1 - CGFloat(row) / CGFloat(Self.cells - 1) * 2   // +1 = G，−1 = M
                                    let r = CGRect(x: CGFloat(col) * cell + gap / 2, y: CGFloat(row) * cell + gap / 2,
                                                   width: cell - gap, height: cell - gap)
                                    ctx.fill(Path(r), with: .color(Self.color(u, v)))
                                }
                            }
                        }
                        .frame(width: side, height: side)
                        .offset(x: Self.margin, y: Self.margin)
                        Circle().fill(Color(red: 0.93, green: 0.26, blue: 0.2))
                            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.5), radius: 1.5)
                            .frame(width: cell * 1.2, height: cell * 1.2)
                            .position(x: Self.margin + (fx * CGFloat(Self.cells - 1) + 0.5) * cell,
                                      y: Self.margin + (fy * CGFloat(Self.cells - 1) + 0.5) * cell)
                        axis("G").position(x: geo.size.width / 2, y: Self.margin / 2)
                        axis("M").position(x: geo.size.width / 2, y: geo.size.width - Self.margin / 2)
                        axis("B").position(x: Self.margin / 2, y: geo.size.width / 2)
                        axis("A").position(x: geo.size.width - Self.margin / 2, y: geo.size.width / 2)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragging = values(v.location, cell, aLo, aHi, aStep, gLo, gHi, gStep) }
                        .onEnded { v in
                            let t = values(v.location, cell, aLo, aHi, aStep, gLo, gHi, gStep)
                            dragging = nil
                            if t.ab != curA { session.setProperty(ab.code, t.ab) }
                            if t.gm != curG { session.setProperty(gm.code, t.gm) }
                        })
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 150)
                .frame(maxWidth: .infinity)
                .disabled(!enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("白平衡微调")
                .accessibilityValue(readout(curA, curG))
                Text(readout(a, g)).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .font(.system(size: 12))
            .padding(.vertical, 6)
            .opacity(enabled ? 1 : 0.5)
            .help(enabled ? "点按或拖动选择微调位置；右上角的箭头回到中心" : "当前设置下由相机决定")
        }
    }

    private func axis(_ t: String) -> some View {
        Text(t).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
    }

    /// 和机身一样写成「A-B: B5  G-M: G4.5」。
    private func readout(_ a: Int64, _ g: Int64) -> String {
        "A-B: \(SonyPropertyCatalog.label(0xD21C, a) ?? "0")  G-M: \(SonyPropertyCatalog.label(0xD210, g) ?? "0")"
    }

    private func reset(_ curA: Int64, _ curG: Int64) {
        if curA != Self.center { session.setProperty(ab.code, Self.center) }
        if curG != Self.center { session.setProperty(gm.code, Self.center) }
    }

    private func values(_ pt: CGPoint, _ cell: CGFloat, _ aLo: Int64, _ aHi: Int64, _ aStep: Int64,
                        _ gLo: Int64, _ gHi: Int64, _ gStep: Int64) -> (ab: Int64, gm: Int64) {
        func snap(_ f: CGFloat, _ lo: Int64, _ hi: Int64, _ step: Int64) -> Int64 {
            let raw = Double(lo) + Double(min(max(f, 0), 1)) * Double(hi - lo)
            let s = Double(max(step, 1))
            return min(hi, max(lo, lo + Int64(((raw - Double(lo)) / s).rounded()) * Int64(s)))
        }
        // 色块中心之间映射到取值范围（第一格中心 = 最小值，最后一格中心 = 最大值）。
        let span = cell * CGFloat(Self.cells - 1)
        let fx = (pt.x - Self.margin - cell / 2) / max(span, 1)
        let fy = (pt.y - Self.margin - cell / 2) / max(span, 1)
        return (snap(fx, aLo, aHi, aStep), snap(1 - fy, gLo, gHi, gStep))
    }

    /// 色块颜色：3 × 3 个控制色按象限双线性插值（上排 绿 / 黄绿 / 黄，中排 青 / 白 / 橙，下排 蓝 / 紫 / 品红）。
    static func color(_ u: CGFloat, _ v: CGFloat) -> Color {
        typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
        let grid: [[RGB]] = [
            [(0.15, 0.85, 0.25), (0.7, 0.92, 0.2), (1.0, 0.85, 0.1)],
            [(0.1, 0.8, 0.95), (1, 1, 1), (1.0, 0.5, 0.3)],
            [(0.15, 0.2, 1.0), (0.6, 0.25, 0.95), (1.0, 0.15, 0.75)],
        ]
        // u: −1 … 1 → 列 0 … 2；v: 1 … −1 → 行 0 … 2
        let x = (u + 1), y = (1 - v)
        let c0 = min(Int(x), 1), r0 = min(Int(y), 1)
        let tx = x - CGFloat(c0), ty = y - CGFloat(r0)
        func lerp(_ p: RGB, _ q: RGB, _ t: CGFloat) -> RGB { (p.r + (q.r - p.r) * t, p.g + (q.g - p.g) * t, p.b + (q.b - p.b) * t) }
        let top = lerp(grid[r0][c0], grid[r0][c0 + 1], tx), bottom = lerp(grid[r0 + 1][c0], grid[r0 + 1][c0 + 1], tx)
        let c = lerp(top, bottom, ty)
        // 比纯色收一点饱和度和亮度，放在深色底上不刺眼。
        let m = lerp(c, (0.5, 0.5, 0.5), 0.18)
        return Color(red: m.r * 0.92, green: m.g * 0.92, blue: m.b * 0.92)
    }
}

/// 一个属性的选项（右对齐，相机没报告或未启用时不显示；仅显示时变淡）。
private struct PropertyRow: View {
    let session: TetherSession
    let title: String
    let code: UInt16

    static func text(_ code: UInt16, _ v: Int64) -> String {
        SonyFormat.settingLabel(code, v) ?? SonyPropertyCatalog.label(code, v) ?? "\(v)"
    }

    var body: some View {
        if let d = session.properties[code], d.isEnabled != 0, let v = d.intValue, case let list = d.allowedValues, !list.isEmpty {
            PanelRow(title, enabled: d.isWritable && !session.lost) {
                if code == 0x5013 {
                    DriveModeMenu(text: Self.text(code, v), options: list, current: v) { session.setProperty(code, $0) }
                } else {
                    ValueMenu(text: Self.text(code, v), options: list.map { ($0, Self.text(code, $0)) }, current: v) {
                        session.setProperty(code, $0)
                    }
                }
            }
            .help(d.isWritable ? "" : "当前设置下由相机决定")
        }
    }
}

/// 驱动模式有一百多项：按单张、连拍、自拍、包围分组，包围再按档位分子菜单。认不出的值放在「其他」里显示原始值。
private struct DriveModeMenu: View {
    let text: String
    let options: [Int64]
    let current: Int64
    let choose: (Int64) -> Void

    private struct Item: Identifiable { let id: Int64; let group: String; let sub: String?; let label: String }
    private static let order = ["单张拍摄", "连拍", "自拍", "连续包围", "单拍包围", "其他包围", "其他"]

    var body: some View {
        let items = options.map { v in
            SonyFormat.driveMode(v).map { Item(id: v, group: $0.group, sub: $0.sub, label: $0.label) }
                ?? Item(id: v, group: "其他", sub: nil, label: String(format: "0x%08llX", v))
        }
        let groups = Self.order.filter { g in items.contains { $0.group == g } }
        Menu {
            ForEach(groups, id: \.self) { g in
                let inGroup = items.filter { $0.group == g }
                if inGroup.count == 1, g == "单张拍摄" {
                    entry(inGroup[0])
                } else {
                    Menu(g) {
                        let subs = inGroup.compactMap(\.sub).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        ForEach(inGroup.filter { $0.sub == nil }) { entry($0) }
                        ForEach(subs, id: \.self) { sub in
                            Menu(sub) { ForEach(inGroup.filter { $0.sub == sub }) { entry($0, short: true) } }
                        }
                    }
                }
            }
        } label: {
            Text("\(text) ") + Text(Image(systemName: "chevron.up.chevron.down")).font(.system(size: 9, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }

    /// 包围子菜单里只写张数（组名和档位已在上级菜单）。
    @ViewBuilder private func entry(_ i: Item, short: Bool = false) -> some View {
        let label = short ? i.label.components(separatedBy: " EV ").last ?? i.label : i.label
        Button { choose(i.id) } label: {
            if i.id == current { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }
}
