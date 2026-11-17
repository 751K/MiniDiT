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
    /// 取景框线：总开关（底栏按钮），右键选三分网格、画幅遮罩、安全框、中心十字。
    @AppStorage("tetherGrid") private var grid = false
    @AppStorage("tetherGuideThirds") private var guideThirds = true
    /// 画幅遮罩的宽高比，0 = 不遮。
    @AppStorage("tetherGuideMask") private var guideMask = 0.0
    @AppStorage("tetherGuideSafe") private var guideSafe = false
    @AppStorage("tetherGuideCenter") private var guideCenter = false
    @AppStorage("tetherVectorscope") private var showVectorscope = false
    @AppStorage("tetherVectorscopeZoom") private var vectorscopeZoom = false
    /// 和达芬奇一样，默认用画面颜色画轨迹。
    @AppStorage("tetherVectorscopeColor") private var vectorscopeColor = true
    @AppStorage("tetherVectorscopeSkin") private var vectorscopeSkin = true
    @AppStorage("tetherVectorscopePosition") private var vectorscopePosition = ""
    @AppStorage("tetherVectorscopeSize") private var vectorscopeSize = ""
    @AppStorage("tetherSpotMeter") private var showSpotMeter = false
    /// 点测光钉住的位置（画面 0–1 坐标）和指针所在的位置。
    @State private var spotPin: CGPoint?
    @State private var spotHover: CGPoint?
    /// 变形镜头去挤压：开关和倍率分开记，关掉再开回到上次的倍率。
    @AppStorage("tetherDesqueeze") private var desqueezeOn = false
    @AppStorage("tetherDesqueezeFactor") private var desqueezeFactor = 2.0
    // 拍摄辅助（见 ViewfinderAids）。
    @AppStorage("tetherHistogram") private var showHistogram = false
    @AppStorage("tetherHistogramMode") private var histogramMode = ViewfinderAidOptions.HistogramMode.luma.rawValue
    @AppStorage("tetherWaveformMode") private var waveformMode = ViewfinderAidOptions.WaveformMode.luma.rawValue
    @AppStorage("tetherWaveform") private var showWaveform = false
    @AppStorage("tetherZebra") private var showZebra = false
    @AppStorage("tetherZebraMode") private var zebraMode = ViewfinderAidOptions.ZebraMode.lowerLimit.rawValue
    @AppStorage("tetherZebraLevel") private var zebraLevel = 95
    @AppStorage("tetherZebraCenter") private var zebraCenter = 70
    @AppStorage("tetherZebraRange") private var zebraRange = 10
    @AppStorage("tetherPeaking") private var showPeaking = false
    @AppStorage("tetherPeakingColor") private var peakingColor = ViewfinderAidOptions.PeakingColor.red.rawValue
    @AppStorage("tetherPeakingLevel") private var peakingLevel = ViewfinderAidOptions.PeakingLevel.mid.rawValue
    @AppStorage("tetherFalseColor") private var showFalseColor = false
    /// 浮动面板中心在取景区域里的比例位置（"x,y"，空 = 默认位置）。
    @AppStorage("tetherHistogramPosition") private var histogramPosition = ""
    @AppStorage("tetherWaveformPosition") private var waveformPosition = ""
    @AppStorage("tetherHistogramSize") private var histogramSize = ""
    @AppStorage("tetherWaveformSize") private var waveformSize = ""
    @AppStorage("tetherFalseColorMode") private var falseColorMode = ViewfinderAidOptions.FalseColorMode.stops.rawValue
    @State private var aids = ViewfinderAids()
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
    /// 指针在取景画面上（MF 时滚轮调焦）。
    @State private var overViewfinder = false
    @State private var modeHovered = false
    @State private var modePicking = false
    @State private var zebraEditing = false

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
            allowed.isEmpty ? $0 == .photo || $0 == .movie : SonyPropertyCatalog.exposureProgram($0, exposure: "m", allowed: allowed) != nil
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
            // 开着叠在画面上的辅助时，显示分析过的那一帧，叠加层和画面严格对齐（分析约 1–2 毫秒，几乎不增加延迟）。
            if let img = ((showZebra || showPeaking || showFalseColor) ? aids.frame : nil) ?? session.liveFrame {
                // 去挤压只改显示比例：叠加层、点按对焦都用相对坐标，跟着一起拉宽。
                Image(nsImage: img).resizable()
                    .aspectRatio(img.size.height > 0 ? img.size.width * desqueeze / img.size.height : nil, contentMode: .fit)
                    .overlay { if showFalseColor, let fc = aids.result.falseColor { aidImage(fc) } }
                    .overlay { if showZebra || showPeaking, let o = aids.result.overlay { aidImage(o) } }
                    .overlay { if grid { FrameGuides(mask: guideMask, thirds: guideThirds, safe: guideSafe, center: guideCenter) } }
                    .overlay { touchLayer }
                    .overlay { if showSpotMeter { spotLayer } }
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
        // 面板放在 onHover 之前：指针在面板上时仍算在取景画面上。
        .overlay(alignment: .bottomLeading) { aidPanels }
        .onHover { overViewfinder = $0 }
        .onChange(of: session.liveFrame) { _, frame in aids.submit(frame, aidOptions) }
        .onChange(of: aidOptions) { _, o in aids.submit(session.liveFrame, o) }
        .overlay(alignment: .top) {
            HStack(alignment: .top, spacing: 8) {
                if let m = session.magnifier, m.isOn {
                    chip(String(localized: "放大 \(TetherSession.ratioText(m.ratio))"), systemImage: "plus.magnifyingglass", color: .white)
                        .help("点按画面移动放大区域，Esc 退出放大")
                }
                if desqueeze != 1 {
                    chip(String(localized: "去挤压 \(Self.desqueezeText(desqueeze))"), systemImage: "arrow.left.and.right", color: .white)
                        .help("取景画面按变形镜头倍率横向拉宽显示，不影响相机记录")
                }
                if session.focusLocked || session.status.isFocused {
                    chip(session.status.isFocused ? String(localized: "已合焦") : String(localized: "对焦中"), systemImage: "scope",
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
        // 测延迟用（defaults write com.kong.MiniDiT tetherDebugClock -bool true）：取景区左上角显示毫秒时钟。
        // 相机对着屏幕拍，取景画面里的时钟和这里的时钟之差就是延迟。
        .overlay(alignment: .topLeading) {
            if UserDefaults.standard.bool(forKey: "tetherDebugClock") {
                TimelineView(.animation) { ctx in
                    Text(ctx.date, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits).secondFraction(.fractional(3)))
                        .font(.system(size: 44, weight: .bold, design: .monospaced))
                        .foregroundStyle(.black).padding(.horizontal, 10).background(.white)
                }
                .padding(.top, 60).padding(.leading, 12)
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if session.downloading || session.status.pendingTransfers > 0 {
                chip(String(localized: "正在接收照片"), systemImage: nil, color: .white, progress: true).padding(10)
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
                    let p = CGPoint(x: loc.x / geo.size.width, y: loc.y / geo.size.height)
                    if session.magnifier?.isOn == true { session.panMagnifier(p) } else { session.touch(p) }
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
        .help(session.magnifier?.isOn == true ? "点按画面移动放大区域，Esc 退出放大"
              : session.isManualFocus ? "MF：滚轮调焦，点按画面在该处放大（拍照模式），Esc 退出放大"
              : "点按画面对焦（按机身的触摸功能对焦或跟踪），Esc 或右键取消")
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
            aidToggles
            barToggle(grid, "square.grid.3x3", String(localized: "取景框线（G）；右键选择网格、画幅遮罩、安全框"), key: "g") { grid.toggle() }
                .contextMenu {
                    Toggle("三分网格", isOn: $guideThirds)
                    Picker("画幅遮罩", selection: $guideMask) {
                        Text("不遮").tag(0.0)
                        ForEach(FrameGuides.masks, id: \.ratio) { Text($0.title).tag($0.ratio) }
                    }
                    Toggle("安全框（90% / 80%）", isOn: $guideSafe)
                    Toggle("中心十字", isOn: $guideCenter)
                }
            barToggle(desqueezeOn, "arrow.left.and.right.square", String(localized: "变形镜头去挤压（\(Self.desqueezeText(desqueezeFactor))）；右键选择倍率")) {
                desqueezeOn.toggle()
            }
            .contextMenu {
                Picker("去挤压倍率", selection: $desqueezeFactor) {
                    ForEach(Self.desqueezeFactors, id: \.self) { Text(Self.desqueezeText($0)).tag($0) }
                }
                .pickerStyle(.inline)
            }
            barToggle(session.focusLocked, "scope", String(localized: "锁定对焦：相当于半按快门（F）")) { session.setFocusLock(!session.focusLocked) }
                .keyboardShortcut("f", modifiers: [])
            // Esc 取消触摸对焦（看不见的按钮，只为快捷键）。
            Button("退出放大或取消触摸对焦") {
                if session.magnifier?.isOn == true { session.setMagnifier(0) } else { session.cancelTouch() }
            }
            .keyboardShortcut(.escape, modifiers: [])
            .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            .disabled(!(session.canCancelTouch || session.magnifier?.isOn == true))
            shortcutButtons
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
        let current = raw.flatMap(SonyPropertyCatalog.shootingMode)
        let text = current.map { Self.exposureText($0.exposure) }
            ?? session.status.modeText.split(separator: " ").first.map(String.init) ?? "—"
        // 同一组（拍照 / 录像 / S&Q）里相机支持的曝光模式。
        let allowed = session.properties[SonyProperty.exposureProgramMode]?.allowedValues ?? []
        let letters = current.map { c in
            ["auto", "p", "a", "s", "m"].filter { SonyPropertyCatalog.exposureProgram(c.mode, exposure: $0, allowed: allowed) != nil }
        } ?? []
        let enabled = current != nil && letters.count > 1 && !session.lost && session.busy == nil && !session.status.isRecording
        return Button { modePicking.toggle() } label: {
            VStack(spacing: 3) {
                Text("模式").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(text).font(.system(size: 17, weight: .semibold))
            }
            .frame(minWidth: 44)
            .padding(.horizontal, 6).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity((modeHovered && enabled) || modePicking ? 0.1 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { modeHovered = $0 }
        .help(enabled ? String(localized: "\(session.status.modeText)：点按切换曝光模式") : session.status.modeText)
        .accessibilityLabel("曝光模式")
        .accessibilityValue(text)
        .popover(isPresented: $modePicking, arrowEdge: .top) {
            ExposurePicker(letters: letters, current: current?.exposure) { l in
                modePicking = false
                chooseExposure(l)
            }
        }
    }

    private static func exposureText(_ l: String) -> String { l == "auto" ? "AUTO" : l.uppercased() }

    private func chooseExposure(_ l: String) {
        guard let mode = session.shootingMode else { return }
        Task {
            do { _ = try await session.switchMode(to: mode, exposure: l) }
            catch { session.message = (error as? AgentControlError)?.message ?? error.localizedDescription }
        }
    }

    /// 某一格不能改时的原因。A / M 下光圈被锁，几乎都是镜头光圈环不在 A 档（α7 V + FE 20-70mm F4 G 实测）。
    private func lockedReason(_ s: CameraSetting) -> String {
        let letter = session.properties[SonyProperty.exposureProgramMode]?.intValue
            .flatMap(SonyPropertyCatalog.shootingMode)?.exposure
        switch s.kind {
        case .aperture where letter == "a" || letter == "m":
            return String(localized: "光圈由镜头上的光圈环控制：光圈环不在 A 档时相机不让远程调整。把光圈环拨到 A 后即可在电脑上调。")
        case .shutterSpeed where letter == "s" || letter == "m":
            return String(localized: "相机现在不让远程调整快门（检查机身的拨盘和设置）。")
        default:
            let mode = letter.map { $0 == "auto" ? String(localized: "智能自动") : $0.uppercased() } ?? String(localized: "当前")
            return String(localized: "\(mode) 模式下\(s.kind.title)由相机自动决定。")
        }
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
        // 提示放在外层：按钮禁用时也能看到为什么不能改。
        .background(Color.clear.contentShape(Rectangle()).help(s.isEditable ? "" : lockedReason(s)))
        .onHover { hovered = $0 ? s.kind : (hovered == s.kind ? nil : hovered) }
        .help(s.isEditable ? String(localized: "\(s.kind.title)：点按选择，或把指针放在上面滚动调整\(Self.stepKeyText(s.kind))") : lockedReason(s))
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

    /// 底部格子按这些文字里最宽的预留宽度（白平衡另算「8888K」），在日光、色温之间切换时格子不变宽窄。
    private func reserveTexts(_ s: CameraSetting) -> [String] {
        let labels = s.options.map(\.label).filter { $0.count <= 7 }
        return s.kind == .whiteBalance ? labels + ["8888K"] : labels
    }

    /// 白平衡在色温或自定义时显示 K 值，其余显示模式名（微调只在侧栏显示）。
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
        return text
    }

    // MARK: 拍摄辅助

    private var aidOptions: ViewfinderAidOptions {
        ViewfinderAidOptions(histogram: showHistogram, waveform: showWaveform, zebra: showZebra, peaking: showPeaking,
                             falseColor: showFalseColor,
                             vectorscope: showVectorscope, vectorscopeZoom: vectorscopeZoom, vectorscopeColor: vectorscopeColor, spotMeter: showSpotMeter,
                             zebraMode: .init(rawValue: zebraMode) ?? .lowerLimit,
                             zebraLevel: zebraLevel, zebraCenter: zebraCenter, zebraRange: zebraRange,
                             peakingColor: .init(rawValue: peakingColor) ?? .red,
                             peakingLevel: .init(rawValue: peakingLevel) ?? .mid,
                             falseColorMode: .init(rawValue: falseColorMode) ?? .stops,
                             histogramMode: .init(rawValue: histogramMode) ?? .luma,
                             waveformMode: .init(rawValue: waveformMode) ?? .luma,
                             logInput: liveViewIsLog)
    }

    private var liveViewIsLog: Bool { session.liveViewIsLog }

    /// 常见变形镜头倍率。
    static let desqueezeFactors: [Double] = [1.25, 1.33, 1.5, 1.6, 1.8, 2.0]

    static func desqueezeText(_ f: Double) -> String {
        f == f.rounded() ? String(format: "%.0f×", f) : String(format: "%g×", f)
    }

    private var desqueeze: Double { desqueezeOn ? desqueezeFactor : 1 }

    /// 点测光层：盖在取景画面上（开着时接管点按，不再触摸对焦）。指针处显示读数，点按钉住一个点，再点同一处附近取消。
    private var spotLayer: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Color.clear.contentShape(Rectangle())
                    .onContinuousHover(coordinateSpace: .local) { phase in
                        if case let .active(loc) = phase, size.width > 0 { spotHover = CGPoint(x: loc.x / size.width, y: loc.y / size.height) }
                        else { spotHover = nil }
                    }
                    .onTapGesture(coordinateSpace: .local) { loc in
                        guard size.width > 0, size.height > 0 else { return }
                        let p = CGPoint(x: loc.x / size.width, y: loc.y / size.height)
                        if let pin = spotPin, hypot((pin.x - p.x) * size.width, (pin.y - p.y) * size.height) < 12 { spotPin = nil } else { spotPin = p }
                    }
                if let pin = spotPin { spotMarker(pin, size: size, pinned: true) }
                if let h = spotHover { spotMarker(h, size: size, pinned: false) }
            }
        }
    }

    @ViewBuilder private func spotMarker(_ p: CGPoint, size: CGSize, pinned: Bool) -> some View {
        if let s = aids.result.sampler, let r = s.sample(p) {
            let pct = Int((Double(r.luma) / 255 * 100).rounded())
            let stops = ViewfinderAnalysis.stops(r.luma, log: aids.result.logInput)
            let x = p.x * size.width, y = p.y * size.height
            ZStack {
                Circle().strokeBorder(.white, lineWidth: pinned ? 1.5 : 1).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.7), radius: 1)
                    .position(x: x, y: y)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(pct)%  \(String(format: "%+.1f", stops)) 档").font(.system(size: 11, weight: .semibold).monospacedDigit())
                    Text("R \(r.r)  G \(r.g)  B \(r.b)").font(.system(size: 9).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(pinned ? 0.75 : 0.55), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .fixedSize()
                .position(x: min(max(x + 62, 60), size.width - 60), y: y + (y > size.height - 40 ? -26 : 26))
            }
            .allowsHitTesting(false)
        }
    }

    private func aidImage(_ image: CGImage) -> some View {
        Image(decorative: image, scale: 1).resizable().interpolation(.none).allowsHitTesting(false)
    }

    /// 直方图和波形图是可拖动的浮动面板（位置按取景区域的比例记住，双击回到默认位置）；伪色图例固定在左下角。
    @ViewBuilder private var aidPanels: some View {
        if session.liveFrame != nil, showHistogram || showWaveform || showFalseColor || showVectorscope {
            GeometryReader { geo in
                // 默认位置：左下角并排，开着伪色时让出图例那一行。
                let bottom = geo.size.height - 10 - (showFalseColor ? 30 : 0)
                ZStack(alignment: .bottomLeading) {
                    Color.clear.allowsHitTesting(false)
                    if showFalseColor {
                        FalseColorLegend(mode: aidOptions.falseColorMode, log: aidOptions.logInput)
                            .padding(10).allowsHitTesting(false)
                    }
                    if showHistogram, let bins = aids.result.histogram {
                        FloatingAidPanel(position: $histogramPosition, sizeText: $histogramSize, container: geo.size,
                                         defaultSize: CGSize(width: 192, height: 84),
                                         defaultCenter: CGPoint(x: 10 + 96, y: bottom - 42)) {
                            HistogramView(channels: bins)
                        }
                    }
                    if showWaveform, let wf = aids.result.waveform {
                        // 分量模式三个通道并排，面板加宽。
                        let width: CGFloat = aids.result.waveformMode == .parade ? 372 : 232
                        FloatingAidPanel(position: $waveformPosition, sizeText: $waveformSize, container: geo.size,
                                         defaultSize: CGSize(width: width, height: 108),
                                         defaultCenter: CGPoint(x: 10 + 192 + 6 + width / 2, y: bottom - 54)) {
                            WaveformView(image: wf, mode: aids.result.waveformMode)
                        }
                    }
                    if showVectorscope, let vs = aids.result.vectorscope {
                        FloatingAidPanel(position: $vectorscopePosition, sizeText: $vectorscopeSize, container: geo.size,
                                         defaultSize: CGSize(width: 160, height: 160),
                                         defaultCenter: CGPoint(x: geo.size.width - 10 - 80, y: bottom - 80)) {
                            VectorscopeView(image: vs, zoom: aids.result.vectorscopeZoom, skinLine: vectorscopeSkin)
                        }
                    }
                }
            }
        }
    }

    /// 底栏的辅助开关；斑马纹和峰值对焦右键可调。
    @ViewBuilder private var aidToggles: some View {
        barToggle(showHistogram, "chart.bar.xaxis", String(localized: "直方图（H）；右键切换亮度或 RGB"), key: "h") { showHistogram.toggle() }
            .contextMenu {
                Picker("直方图", selection: $histogramMode) {
                    ForEach(ViewfinderAidOptions.HistogramMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
        barToggle(showWaveform, "waveform.path", String(localized: "波形图（W）；右键切换亮度、RGB 叠加或 RGB 分量"), key: "w") { showWaveform.toggle() }
            .contextMenu {
                Picker("波形图", selection: $waveformMode) {
                    ForEach(ViewfinderAidOptions.WaveformMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
        barToggle(showVectorscope, "target", String(localized: "矢量示波器（V）；右键放大 2 倍（Log 画面饱和度低时用）"), key: "v") { showVectorscope.toggle() }
            .contextMenu {
                Toggle("放大 2 倍", isOn: $vectorscopeZoom)
                Toggle("彩色轨迹", isOn: $vectorscopeColor)
                Toggle("肤色线", isOn: $vectorscopeSkin)
            }
        barToggle(showSpotMeter, "eyedropper.halffull", String(localized: "点测光：指针所在处显示亮度和档位，点按钉住一个测光点（开着时点按画面不对焦）")) {
            showSpotMeter.toggle()
            if !showSpotMeter { spotPin = nil; spotHover = nil }
        }
        barToggle(showFalseColor, "swatchpalette", String(localized: "伪色（C）；右键切换按档位或按百分比"), key: "c") { showFalseColor.toggle() }
            .contextMenu {
                Picker("伪色", selection: $falseColorMode) {
                    ForEach(ViewfinderAidOptions.FalseColorMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
            }
        barToggle(showZebra, "circle.lefthalf.striped.horizontal", String(localized: "斑马纹（\(aidOptions.zebraText)，Z）；右键调整"), key: "z") { showZebra.toggle() }
            .contextMenu {
                Picker("模式", selection: $zebraMode) {
                    Text("下限：亮度不低于阈值").tag(ViewfinderAidOptions.ZebraMode.lowerLimit.rawValue)
                    Text("范围：亮度在某个区间内").tag(ViewfinderAidOptions.ZebraMode.range.rawValue)
                }
                .pickerStyle(.inline)
                Divider()
                Button("调整数值（当前 \(aidOptions.zebraText)）…") { zebraEditing = true }
            }
            .popover(isPresented: $zebraEditing, arrowEdge: .top) {
                ZebraSettings(mode: $zebraMode, level: $zebraLevel, center: $zebraCenter, range: $zebraRange)
            }
        barToggle(showPeaking, "circle.dotted.and.circle", String(localized: "峰值对焦（P）；右键调整颜色和灵敏度"), key: "p") { showPeaking.toggle() }
            .contextMenu {
                Picker("颜色", selection: $peakingColor) {
                    ForEach(ViewfinderAidOptions.PeakingColor.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
                Picker("灵敏度", selection: $peakingLevel) {
                    ForEach(ViewfinderAidOptions.PeakingLevel.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
                }
            }
    }

    private func barToggle(_ on: Bool, _ icon: String, _ help: String, key: KeyEquivalent? = nil,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14))
                .frame(width: 32, height: 32)
                .foregroundStyle(on ? Color.accentColor : .secondary)
                .background(Circle().fill(.white.opacity(on ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(key.map { KeyboardShortcut($0, modifiers: []) })
        .help(help)
        .accessibilityLabel(help)
    }

    /// 只为快捷键的看不见的按钮：M 放大检查焦点，方向键加修饰键调参数（和滚轮一样一次一档）。
    /// ⌃←→ 是系统切换桌面用的，所以 ISO 用 ⌥⇧←→。
    @ViewBuilder private var shortcutButtons: some View {
        Group {
            Button("放大检查焦点") {
                guard let m = session.magnifier else { return }
                if m.isOn { session.setMagnifier(0) }
                else if let r = m.ratios.filter({ $0 > 10 }).min() { session.setMagnifier(r) }
            }
            .keyboardShortcut("m", modifiers: [])
            .disabled(session.magnifier == nil)
            ForEach(Self.stepKeys, id: \.title) { k in
                Button("\(k.title)减一档") { keyStep(k.kind, -1) }.keyboardShortcut(.leftArrow, modifiers: k.modifiers)
                Button("\(k.title)加一档") { keyStep(k.kind, 1) }.keyboardShortcut(.rightArrow, modifiers: k.modifiers)
            }
        }
        .frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
    }

    private static let stepKeys: [(title: String, kind: CameraSettingKind, modifiers: EventModifiers)] = [
        (String(localized: "快门"), .shutterSpeed, .shift), (String(localized: "光圈"), .aperture, .option),
        ("ISO", .iso, [.option, .shift]), (String(localized: "曝光补偿"), .exposureCompensation, .command),
    ]

    /// 参数格提示里的快捷键说明，如「；⇧← → 加减一档」。
    private static func stepKeyText(_ kind: CameraSettingKind) -> String {
        guard let k = stepKeys.first(where: { $0.kind == kind }) else { return "" }
        let m = (k.modifiers.contains(.option) ? "⌥" : "") + (k.modifiers.contains(.shift) ? "⇧" : "") + (k.modifiers.contains(.command) ? "⌘" : "")
        return String(localized: "；\(m)← → 加减一档")
    }

    private func keyStep(_ kind: CameraSettingKind, _ delta: Int) {
        guard session.status.settings.first(where: { $0.kind == kind })?.isEditable == true else { return }
        scrollStep(kind, delta)
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
        .keyboardShortcut("r", modifiers: [])
        .help(on ? "停止录像（R，录像保存在相机存储卡上）" : "开始录像（R，录像保存在相机存储卡上）")
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
            // MF 时指针在取景画面上：滚轮调焦（向上 = 往近处，触控板按滑动量细调）。
            if inTether, picking == nil, overViewfinder, session.isManualFocus,
               let c = session.focusControl, let cur = session.focusShown {
                let span = Double(c.range.upperBound - c.range.lowerBound)
                let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * span / 4000 : event.scrollingDeltaY * span / 300
                if step != 0 { session.moveFocus(to: cur + Int64(step.rounded())) }
                return nil
            }
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
        let order = kind == .whiteBalance ? WhiteBalancePicker.ordered(s.options).map(\.value) : ScalePicker.layout(s).ticks.map(\.option.value)
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

    struct Tick {
        let option: SettingOption; let major: Bool; let label: String?
        /// 扩展感光度（ISO 50–80、64000 以上）：刻度画淡一些。
        var extended = false
    }

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

/// 白平衡弹出框：一排模式图标（和相机里一样按相机报告的顺序），选中色温时下面是色温刻度（低色温偏蓝在左，高色温偏暖在右）。
/// 悬停图标或刻度时底部参数条显示指着的值；点按才发给相机。A–B、G–M 微调在右侧栏。
/// 曝光模式：一排方块（和白平衡弹出框同一种样式），字母在上、中文名在下。
private struct ExposurePicker: View {
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
private struct ZebraSettings: View {
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

/// 取景上可拖动的辅助面板：拖到哪里就停在哪里（不会拖出取景区域）；拖右下角改大小（左上角不动）；
/// 双击回到默认位置和大小。
private struct FloatingAidPanel<Content: View>: View {
    @Binding var position: String
    /// 用户改过的大小（"宽,高"，点；空 = 默认大小）。
    @Binding var sizeText: String
    let container: CGSize
    /// 含内边距的默认尺寸。
    let defaultSize: CGSize
    let defaultCenter: CGPoint
    @ViewBuilder var content: Content
    @GestureState private var drag: CGSize = .zero
    @GestureState private var resize: CGSize = .zero
    @State private var hovering = false

    static var minSize: CGSize { CGSize(width: 140, height: 64) }

    var body: some View {
        let baseSize = fitted(storedSize ?? defaultSize)
        let size = fitted(CGSize(width: baseSize.width + resize.width, height: baseSize.height + resize.height))
        let baseCenter = clamped(storedCenter ?? defaultCenter, baseSize)
        // 改大小时左上角不动：中心跟着移半个增量。
        let grown = CGPoint(x: baseCenter.x + (size.width - baseSize.width) / 2, y: baseCenter.y + (size.height - baseSize.height) / 2)
        let center = clamped(CGPoint(x: grown.x + drag.width, y: grown.y + drag.height), size)
        let active = hovering || drag != .zero || resize != .zero
        content
            .frame(width: size.width - 12, height: size.height - 12)
            .padding(6)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(active ? 0.3 : 0), lineWidth: 1)
            }
            .overlay(alignment: .bottomTrailing) {
                // 平时淡淡显示（完全透明的视图收不到点按，指针没先停在面板上时会拖成移动）。
                resizeHandle(baseSize: baseSize, baseCenter: baseCenter).opacity(active ? 1 : 0.75)
            }
            .contentShape(Rectangle())
            .position(center)
            .gesture(
                // 用窗口坐标：面板跟着移动时，本地坐标会跟着变，算出的位移不准。
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        save(center: CGPoint(x: baseCenter.x + v.translation.width, y: baseCenter.y + v.translation.height), size: baseSize)
                    }
            )
            .onTapGesture(count: 2) { position = ""; sizeText = "" }
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
            }
            .help("拖动可移动，拖右下角改大小，双击恢复默认")
    }

    /// 右下角的改大小手柄（悬停时显示）。手柄上的拖动优先于整块面板的移动。
    private func resizeHandle(baseSize: CGSize, baseCenter: CGPoint) -> some View {
        // 深色小方块上三条白色斜线：压在浅色的直方图上也看得清。
        Path { p in
            for d in [4.0, 8.0, 12.0] {
                p.move(to: CGPoint(x: 15 - d, y: 15)); p.addLine(to: CGPoint(x: 15, y: 15 - d))
            }
        }
        .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 18, height: 18)
        .background(.black.opacity(0.75), in: UnevenRoundedRectangle(topLeadingRadius: 5, bottomTrailingRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($resize) { v, s, _ in s = v.translation }
                .onEnded { v in
                    let size = fitted(CGSize(width: baseSize.width + v.translation.width, height: baseSize.height + v.translation.height))
                    save(center: CGPoint(x: baseCenter.x + (size.width - baseSize.width) / 2,
                                         y: baseCenter.y + (size.height - baseSize.height) / 2), size: size)
                }
        )
        .onHover { inside in
            if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
        }
        .accessibilityLabel("改变面板大小")
    }

    private func save(center: CGPoint, size: CGSize) {
        guard container.width > 0, container.height > 0 else { return }
        let c = clamped(center, size)
        position = String(format: "%.4f,%.4f", c.x / container.width, c.y / container.height)
        if size != fitted(defaultSize) { sizeText = String(format: "%.0f,%.0f", size.width, size.height) }
    }

    private var storedCenter: CGPoint? {
        let parts = position.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0] * container.width, y: parts[1] * container.height)
    }

    private var storedSize: CGSize? {
        let parts = sizeText.split(separator: ",").compactMap { Double($0) }
        guard parts.count == 2 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }

    /// 不小于最小尺寸，也不超过取景区域。
    private func fitted(_ s: CGSize) -> CGSize {
        CGSize(width: min(max(s.width, Self.minSize.width), max(Self.minSize.width, container.width)),
               height: min(max(s.height, Self.minSize.height), max(Self.minSize.height, container.height)))
    }

    /// 面板整个留在取景区域里（区域比面板还小时贴左上）。
    private func clamped(_ p: CGPoint, _ size: CGSize) -> CGPoint {
        let hw = size.width / 2, hh = size.height / 2
        return CGPoint(x: min(max(p.x, hw), max(hw, container.width - hw)),
                       y: min(max(p.y, hh), max(hh, container.height - hh)))
    }
}

/// 取景框线：画幅遮罩（遮掉画幅外的部分，边上画一条细线）、在可见区域里的三分网格、90% / 80% 安全框和中心十字。
private struct FrameGuides: View {
    let mask: Double
    let thirds: Bool
    let safe: Bool
    let center: Bool

    static let masks: [(ratio: Double, title: String)] = [
        (2.39, String(localized: "2.39:1 宽银幕")), (2.0, "2:1"), (1.85, "1.85:1"), (16.0 / 9, "16:9"), (4.0 / 3, "4:3"),
        (1, "1:1"), (0.8, String(localized: "4:5 竖")), (9.0 / 16, String(localized: "9:16 竖屏")),
    ]

    var body: some View {
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            let area = active(in: full)
            ZStack {
                if area != full {
                    Path { p in p.addRect(full); p.addRect(area) }
                        .fill(.black.opacity(0.6), style: FillStyle(eoFill: true))
                    Path(area).stroke(.white.opacity(0.5), lineWidth: 0.5)
                }
                if thirds { ThirdsGrid().stroke(.white.opacity(0.35), lineWidth: 0.5).frame(width: area.width, height: area.height).position(x: area.midX, y: area.midY) }
                if safe {
                    ForEach([0.9, 0.8], id: \.self) { k in
                        Path(area.insetBy(dx: area.width * (1 - k) / 2, dy: area.height * (1 - k) / 2))
                            .stroke(.white.opacity(0.4), style: StrokeStyle(lineWidth: 0.5, dash: [4, 3]))
                    }
                }
                if center {
                    Path { p in
                        p.move(to: CGPoint(x: area.midX - 10, y: area.midY)); p.addLine(to: CGPoint(x: area.midX + 10, y: area.midY))
                        p.move(to: CGPoint(x: area.midX, y: area.midY - 10)); p.addLine(to: CGPoint(x: area.midX, y: area.midY + 10))
                    }
                    .stroke(.white.opacity(0.75), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// 遮罩后的可见区域：画面比遮罩宽就遮左右，否则遮上下。
    private func active(in r: CGRect) -> CGRect {
        guard mask > 0, r.width > 0, r.height > 0 else { return r }
        let aspect = r.width / r.height
        if abs(aspect - mask) < 0.01 { return r }
        if aspect > mask {
            let w = r.height * mask
            return CGRect(x: (r.width - w) / 2, y: 0, width: w, height: r.height)
        }
        let h = r.width / mask
        return CGRect(x: 0, y: (r.height - h) / 2, width: r.width, height: h)
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
                    // 分组之间不画分割线，靠留白和分组标题区分。
                    review.padding(14)
                    // 拍摄时常调的展开放在上面；一次性设好的收成「设置」里的摘要行，点开弹出完整列表（像机身的二级菜单）。
                    focusCard
                    whiteBalanceCard.padding(.horizontal, 14).padding(.vertical, 12)
                    settingsCard
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
    private func collapsibleTitle(_ title: LocalizedStringResource) -> some View { collapsibleTitle(title) { EmptyView() } }

    /// 收起状态按中文键保存（title.key），显示用本地化后的文字。
    private func collapsibleTitle<T: View>(_ title: LocalizedStringResource, @ViewBuilder trailing: () -> T) -> some View {
        let t = title.key
        let collapsed = isCollapsed(t)
        return Button {
            var set = collapsedSections.split(separator: "\n").map(String.init).filter { $0 != t }
            if !collapsed { set.append(t) }
            withAnimation(.easeInOut(duration: 0.15)) { collapsedSections = set.joined(separator: "\n") }
        } label: {
            HStack(spacing: 4) {
                sectionTitle(String(localized: title))
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
        let shifted = [UInt16(0xD21C), 0xD210].contains { p[$0]?.intValue.map { $0 != 192 } ?? false }
        let shiftWritable = p[0xD21C]?.isWritable == true && p[0xD210]?.isWritable == true && !session.lost
        return VStack(alignment: .leading, spacing: 4) {
            collapsibleTitle("白平衡") {
                if shifted {
                    Button {
                        for c in [UInt16(0xD21C), 0xD210] where p[c]?.intValue != 192 { session.setProperty(c, 192) }
                    } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.borderless).help("微调回到 0").disabled(!shiftWritable)
                    .accessibilityLabel("微调回到 0")
                }
            }
            if !isCollapsed("白平衡") { PanelCard {
                if let ab = p[0xD21C], let gm = p[0xD210] {
                    WBShiftSliders(session: session, ab: ab, gm: gm)
                }
                if p[0xD270] != nil {
                    if p[0xD21C] != nil, p[0xD210] != nil { PanelDivider() }
                    // 取白和取白框放一行：框大小是取白时才用的设置。
                    PanelRow(String(localized: "自定义白平衡"), enabled: session.busy == nil && !session.lost) {
                        if let size = p[0xD135], let v = size.intValue, !size.allowedValues.isEmpty {
                            ValueMenu(text: String(localized: "框 \(PropertyRow.text(0xD135, v))"), options: size.allowedValues.map { ($0, PropertyRow.text(0xD135, $0)) },
                                      current: v) { session.setProperty(0xD135, $0) }
                                .disabled(!size.isWritable)
                                .help("取白框大小")
                        }
                        Menu {
                            ForEach(1...3, id: \.self) { slot in
                                Button("存入自定义 \(slot)") { captureWB(slot) }
                            }
                        } label: {
                            MenuValueLabel(text: String(localized: "取白…"))
                        }
                        .sidebarMenuStyle()
                        .help("先让相机对准灰卡或白纸，再选择存入哪个自定义白平衡。会覆盖该槽位原来的结果。")
                    }
                }
            } }
        }
    }

    private func captureWB(_ slot: Int) {
        Task {
            do { _ = try await session.customWhiteBalance(slot: slot) }
            catch { session.message = (error as? AgentControlError).map { $0.message.components(separatedBy: TetherSession.traceSeparator)[0] } ?? error.localizedDescription }
        }
    }

    /// 调焦：近 ↔ 远滑块、两个记忆点和拉焦（相机能远程调焦时才显示）。
    @ViewBuilder private var focusCard: some View {
        if let c = session.focusControl, let shown = session.focusShown {
            VStack(alignment: .leading, spacing: 4) {
                collapsibleTitle("对焦")
                if !isCollapsed("对焦") {
                    PanelCard {
                        FocusHeader(session: session)
                        FocusSlider(range: c.range, value: shown, marks: session.focusMarks, enabled: !session.lost) {
                            session.moveFocus(to: $0)
                        }
                        HStack(spacing: 6) {
                            ForEach(["A", "B"], id: \.self) { FocusMarkChip(session: session, name: $0, seconds: pullSeconds) }
                            Spacer(minLength: 6)
                            ValueMenu(text: String(localized: "拉焦 \(Self.secondsText(pullSeconds))"),
                                      options: [0, 1, 2, 4, 8].map { (Int64($0), Self.secondsText(Double($0))) },
                                      current: Int64(pullSeconds)) { pullSeconds = Double($0) }
                                .help("点记忆点时拉焦用的时长")
                        }
                        .frame(minHeight: 30)
                        // 放大只在相机允许时出现（α7 V：拍照模式、MF）。
                        if let m = session.magnifier {
                            let ratios = m.ratios.filter { $0 > 10 }
                            PanelRow(String(localized: "放大"), enabled: !session.lost) {
                                ValueMenu(text: m.isOn ? TetherSession.ratioText(m.ratio) : String(localized: "关"),
                                          options: [(Int64(0), String(localized: "关"))] + ratios.map { ($0, TetherSession.ratioText($0)) },
                                          current: m.isOn ? m.ratio : 0) { session.setMagnifier($0) }
                            }
                            .help("放大取景画面检查焦点（M）；放大时点按画面移动放大区域，Esc 退出")
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private static func secondsText(_ s: Double) -> String { s == 0 ? String(localized: "即时") : String(localized: "\(Int(s)) 秒") }

    /// 「设置」：每组一行摘要，点开弹出该组的完整列表。相机没报告或未启用的项不显示，整组都没有时不显示这一行。
    @ViewBuilder private var settingsCard: some View {
        let groups = settingGroups.filter { !shownRows($0.rows).isEmpty }
        if !groups.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                collapsibleTitle("设置")
                if !isCollapsed("设置") {
                    PanelCard {
                        ForEach(groups, id: \.title) { g in
                            SettingsSummaryRow(session: session, title: g.title, rows: shownRows(g.rows), summary: g.summary)
                        }
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
        }
    }

    private struct SettingGroup { let title: String; let rows: [(String, UInt16)]; let summary: [UInt16] }

    private var settingGroups: [SettingGroup] {
        var list: [SettingGroup] = []
        switch session.shootingMode {
        // Log 拍摄打开时图片配置文件和伽马 / 色彩模式不可用（相机报告未启用，自动不显示），这时可改 Log 色域、Base Look 和监看 LUT。
        case .movie?: list.append(SettingGroup(title: String(localized: "录像"), rows: [(String(localized: "文件格式"), 0xD241), (String(localized: "码率"), 0xD242), (String(localized: "帧率"), 0xD286)], summary: [0xD241, 0xD286, 0xD242]))
        case .sq?: list.append(SettingGroup(title: String(localized: "慢快动作"), rows: [(String(localized: "文件格式"), 0xD241), (String(localized: "码率"), 0xD0D1), (String(localized: "记录帧率"), 0xD0D0), (String(localized: "慢快帧率"), 0xD052)], summary: [0xD052, 0xD0D0, 0xD241]))
        case .interval?: list.append(SettingGroup(title: String(localized: "间隔录像"), rows: [(String(localized: "文件格式"), 0xD241), (String(localized: "录像设置"), 0xD152), (String(localized: "记录帧率"), 0xD151), (String(localized: "拍摄间隔"), 0xD055)], summary: [0xD055, 0xD151, 0xD241]))
        default: break
        }
        if session.shootingMode != nil, session.shootingMode != .photo {
            list.append(SettingGroup(title: String(localized: "Log 与画面"), rows: Self.lookRows, summary: [0xE000, 0xD03C, 0xD04D, 0xD23F]))
        }
        list.append(SettingGroup(title: String(localized: "照片"), rows: photoRows, summary: [photoRows.first?.1 ?? 0xD253, 0xD287] + photoRows.filter { $0.0 == String(localized: "画质") || $0.0 == String(localized: "图像尺寸") }.map(\.1)))
        // 创意外观只在拍照时显示：录像时画面由 Log / 图片配置文件决定（相机在录像模式下也可能仍报告它可写）。
        if session.shootingMode == .photo || session.shootingMode == nil {
            list.append(SettingGroup(title: String(localized: "创意外观"), rows: [(String(localized: "外观"), 0xD0FA)] + Self.lookParams, summary: [0xD0FA]))
        }
        // 对焦卡片顶部已有对焦模式；相机不能远程调焦（没有对焦卡片）时才放在这里。
        let focusMode: (String, UInt16) = (String(localized: "对焦模式"), 0x500A)
        let focusRow: [(String, UInt16)] = session.focusControl == nil ? [focusMode] : []
        let shootRows: [(String, UInt16)] = [(String(localized: "驱动模式"), 0x5013), (String(localized: "点按画面"), 0xD283)]
        list.append(SettingGroup(title: String(localized: "拍摄"), rows: focusRow + shootRows, summary: focusRow.map(\.1) + [0x5013, 0xD283]))
        list.append(SettingGroup(title: String(localized: "镜头补偿"), rows: [(String(localized: "暗角补偿"), 0xD1A2), (String(localized: "色差补偿"), 0xD1A3)], summary: [0xD1A2, 0xD1A3]))
        // 低画质分辨率减半，但 Wi-Fi 下更顺、延迟略低；检查对焦时用高。
        list.append(SettingGroup(title: String(localized: "取景"), rows: [(String(localized: "取景画质"), 0xD26A)], summary: [0xD26A]))
        return list
    }

    private func shownRows(_ rows: [(String, UInt16)]) -> [(String, UInt16)] {
        let p = session.properties
        return rows.filter { r in p[r.1].map { $0.isEnabled != 0 && !$0.allowedValues.isEmpty } ?? false }
    }

    private static let lookParams: [(String, UInt16)] = [(String(localized: "对比度"), 0xD0FB), (String(localized: "高光"), 0xD0FC), (String(localized: "阴影"), 0xD0FD), (String(localized: "褪色"), 0xD0FE),
                                                          (String(localized: "饱和度"), 0xD0FF), (String(localized: "锐度"), 0xD100), (String(localized: "锐度范围"), 0xD101), (String(localized: "清晰度"), 0xD102)]

    private static let lookRows: [(String, UInt16)] = [(String(localized: "Log 拍摄"), 0xE000), (String(localized: "Log 色域"), 0xE001), (String(localized: "图片配置文件"), 0xD23F), (String(localized: "伽马"), 0xD0E1), (String(localized: "色彩模式"), 0xD0E9),
                                                       ("Base Look", 0xD03C), (String(localized: "监看 LUT"), 0xD04D)]

    /// 拍照时的存储设置（「设置」里的「照片」一组）。统一记录和分卡槽各有一组属性，哪组可写取决于记录媒体设置：用可写的那组（都不可写时用相机报告了的）。
    private var photoRows: [(String, UInt16)] {
        let p = session.properties
        func pick(_ codes: [UInt16]) -> [UInt16] {
            (codes.first { p[$0]?.isWritable == true } ?? codes.first { p[$0] != nil }).map { [$0] } ?? []
        }
        // 分步写，类型检查才快。
        var rows: [(String, UInt16)] = pick([0xD28B, 0xD253]).map { (String(localized: "文件格式"), $0) }
        rows.append((String(localized: "压缩格式"), 0xD287))
        rows += pick([0xD28D, 0xD252]).map { (String(localized: "画质"), $0) }
        rows += pick([0xD28F, 0xD203]).map { (String(localized: "图像尺寸"), $0) }
        rows += pick([0xD289, 0xD288]).map { (String(localized: "RAW 压缩"), $0) }
        rows += [(String(localized: "传到电脑"), 0xD269), (String(localized: "色彩空间"), 0xD15E), ("DRO", 0xD201)]
        return rows
    }

    // MARK: 导入

    private var importBar: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("导入到").foregroundStyle(.secondary)
                Menu(model.currentSession?.name ?? String(localized: "未选项目")) {
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

/// 对焦卡片顶部：大号距离读数（没有换算表时显示位置百分比），右边是对焦模式菜单。
private struct FocusHeader: View {
    let session: TetherSession

    var body: some View {
        let mode = session.properties[SonyProperty.focusMode]
        HStack(alignment: .firstTextBaseline) {
            Text(session.focusDistanceText ?? positionText)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Spacer()
            if let mode, let v = mode.intValue, !mode.allowedValues.isEmpty {
                ValueMenu(text: PropertyRow.text(mode.code, v),
                          options: mode.allowedValues.map { ($0, PropertyRow.text(mode.code, $0)) }, current: v) {
                    session.setProperty(mode.code, $0)
                }
                .disabled(!mode.isWritable || session.lost)
                .help(session.isManualFocus ? "对焦模式" : "自动对焦时相机会自己重新对焦，调焦不一定保持；切到 MF 再调")
            }
        }
        .padding(.top, 2).padding(.bottom, 4)
    }

    private var positionText: String {
        guard let c = session.focusControl, let v = session.focusShown, c.range.upperBound > c.range.lowerBound else { return "—" }
        let f = Double(c.range.upperBound - v) / Double(c.range.upperBound - c.range.lowerBound)
        return "\(Int((f * 100).rounded()))%"
    }
}

/// 调焦刻度条：左近右远（相机的值越大越近，所以反过来画）。点按跳到该处，拖动连续调；记忆点 A / B 用小三角标在下方。
private struct FocusSlider: View {
    let range: ClosedRange<Int64>
    let value: Int64
    let marks: [String: Int64]
    let enabled: Bool
    let move: (Int64) -> Void
    @State private var hovering = false

    static func markColor(_ name: String) -> Color { name == "A" ? Color(red: 1, green: 0.62, blue: 0.2) : Color(red: 0.35, green: 0.78, blue: 1) }

    private func fraction(_ v: Int64) -> Double {
        Double(range.upperBound - v) / Double(range.upperBound - range.lowerBound)
    }

    var body: some View {
        // 和白平衡滑杆同一种样子：细轨道 + 白色圆钮；记忆点是轨道下方的小三角。左近右远。
        GeometryReader { geo in
            let w = geo.size.width
            let x = 7 + fraction(value) * (w - 14)
            ZStack(alignment: .topLeading) {
                Capsule().fill(.white.opacity(0.14)).frame(height: 4).offset(y: 7)
                Capsule().fill(Color.accentColor.opacity(0.7)).frame(width: max(x, 0), height: 4).offset(y: 7)
                ForEach(marks.sorted { $0.key < $1.key }, id: \.key) { name, v in
                    Triangle().fill(Self.markColor(name)).frame(width: 7, height: 5)
                        .position(x: 7 + fraction(v) * (w - 14), y: 19)
                }
                Circle().fill(.white).frame(width: 14, height: 14)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
                    .scaleEffect(hovering ? 1.1 : 1)
                    .position(x: x, y: 9)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                guard enabled, w > 14 else { return }
                let f = min(max((g.location.x - 7) / (w - 14), 0), 1)
                move(range.upperBound - Int64((f * Double(range.upperBound - range.lowerBound)).rounded()))
            })
            .onHover { hovering = $0 }
        }
        .frame(height: 22)
        .opacity(enabled ? 1 : 0.5)
        .accessibilityElement()
        .accessibilityLabel("对焦位置，左近右远")
        .accessibilityValue("\(Int((fraction(value) * 100).rounded()))%")
        .help("左近右远")
        .padding(.bottom, 2)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.closeSubpath() }
    }
}

/// 记忆点标签：没记时点按记下现在的位置；记过后点按拉焦过去，右键可重新记下或清除。
private struct FocusMarkChip: View {
    let session: TetherSession
    let name: String
    let seconds: Double
    @State private var hovering = false

    var body: some View {
        let v = session.focusMarks[name]
        let color = FocusSlider.markColor(name)
        Button {
            if let v { session.pullFocus(to: v, seconds: seconds) } else { session.markFocus(name) }
        } label: {
            HStack(spacing: 5) {
                Text(name).font(.system(size: 11, weight: .bold))
                    .foregroundStyle(v == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(color))
                Text(label(v)).font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(v == nil ? .tertiary : .primary)
            }
            .padding(.horizontal, 8).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(v != nil ? color.opacity(hovering ? 0.26 : 0.16) : .white.opacity(hovering ? 0.1 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.lost)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("记下当前位置") { session.markFocus(name) }
            Button("清除") { session.clearFocusMark(name) }.disabled(v == nil)
        }
        .help(v == nil ? "点按记下现在的对焦位置为 \(name)" : "点按拉焦到 \(name)；右键重新记下或清除")
    }

    private func label(_ v: Int64?) -> String {
        guard let v else { return String(localized: "记下") }
        return session.focusDistanceText(at: v) ?? String(localized: "拉过去")
    }
}

/// 「设置」里的一行：标题 + 几项当前值的摘要 + 箭头，点按弹出这一组的完整列表。
private struct SettingsSummaryRow: View {
    let session: TetherSession
    let title: String
    let rows: [(String, UInt16)]
    let summary: [UInt16]
    @State private var open = false
    @State private var hovering = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(summaryText).foregroundStyle(.primary).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 6).frame(minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.white.opacity(hovering || open ? 0.07 : 0)))
            .contentShape(Rectangle())
            .padding(.horizontal, -6)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $open, arrowEdge: .leading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.bottom, 4)
                ForEach(rows, id: \.1) { PropertyRow(session: session, title: $0.0, code: $0.1) }
            }
            .padding(14).frame(width: 250)
        }
        .help("点按查看和修改\(title)的全部设置")
    }

    private static let shortNames: [UInt16: String] = [0xD0FB: String(localized: "对比"), 0xD0FF: String(localized: "饱和")]
    /// 这些项单写值看不出是哪个，要带上名字（值都一样时合成一个，比如两项都是「自动」只写「自动」）。
    private static let namedValues: [UInt16: String] = [0xD1A2: String(localized: "暗角"), 0xD1A3: String(localized: "色差")]

    private var summaryText: String {
        let p = session.properties
        let parts = summary.compactMap { c -> String? in
            guard let d = p[c], d.isEnabled != 0, let v = d.intValue else { return nil }
            // 光秃秃的数字看不出是什么：创意外观的参数带上简称和正负号。
            if let short = Self.shortNames[c] { return "\(short) \(v > 0 ? "+" : "")\(v)" }
            if c == 0xE000 { return v == 1 ? String(localized: "Log 关") : String(localized: "Log 开") }
            return PropertyRow.text(c, v)
        }
        let named = summary.filter { Self.namedValues[$0] != nil }
        if !named.isEmpty {
            let vals = named.compactMap { c in p[c]?.intValue.map { PropertyRow.text(c, $0) } }
            if Set(vals).count == 1, let v = vals.first { return v }
            return zip(named, vals).map { "\(Self.namedValues[$0.0]!) \($0.1)" }.joined(separator: " · ")
        }
        return parts.joined(separator: " · ")
    }
}

/// 侧栏菜单的值：常规字重的值 + 小号淡色上下箭头，指针移上去时出现浅色底，提示可以点。
private struct MenuValueLabel: View {
    let text: String
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).foregroundStyle(enabled ? .primary : .tertiary)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white.opacity(hovering && enabled ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .padding(.trailing, -6)
    }
}

extension View {
    /// 不带系统按钮外框、用自定义标签的下拉菜单。
    func sidebarMenuStyle() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
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
            MenuValueLabel(text: text)
        }
        .sidebarMenuStyle()
    }
}

/// 白平衡微调：A–B、G–M 两个滑杆，轨道用对应方向的颜色渐变。拖动时显示新值，松手按档位取整后发给相机。
private struct WBShiftSliders: View {
    let session: TetherSession
    let ab: SonyPropertyDesc
    let gm: SonyPropertyDesc
    private static let center: Int64 = 192

    var body: some View {
        let enabled = ab.isWritable && gm.isWritable && !session.lost
        VStack(spacing: 4) {
            ShiftSlider(session: session, desc: ab, low: "B", high: "A",
                        colors: [Color(red: 0.3, green: 0.5, blue: 0.95), Color(white: 0.75), Color(red: 0.95, green: 0.6, blue: 0.25)])
            ShiftSlider(session: session, desc: gm, low: "M", high: "G",
                        colors: [Color(red: 0.85, green: 0.35, blue: 0.75), Color(white: 0.75), Color(red: 0.35, green: 0.8, blue: 0.4)])
        }
        .font(.system(size: 12))
        .padding(.vertical, 4)
        .opacity(enabled ? 1 : 0.5)
        .disabled(!enabled)
        .help(enabled ? "" : "当前设置下由相机决定")
    }
}

private struct ShiftSlider: View {
    let session: TetherSession
    let desc: SonyPropertyDesc
    let low: String
    let high: String
    let colors: [Color]
    @State private var dragging: Int64?

    var body: some View {
        if case let .range(lo, hi, step) = desc.form, hi > lo, let cur = desc.intValue {
            let v = dragging ?? cur
            let f = CGFloat(v - lo) / CGFloat(hi - lo)
            HStack(spacing: 8) {
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                            .opacity(0.55).frame(height: 4)
                        Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 10).offset(x: w / 2 - 0.5)
                        Circle().fill(.white).frame(width: 14, height: 14)
                            .shadow(color: .black.opacity(0.5), radius: 1.5)
                            .offset(x: f * (w - 14))
                    }
                    .frame(height: geo.size.height)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in dragging = snap(g.location.x, w, lo, hi, step) }
                        .onEnded { g in
                            let t = snap(g.location.x, w, lo, hi, step)
                            dragging = nil
                            if t != cur { session.setProperty(desc.code, t) }
                        })
                    .onTapGesture(count: 2) { session.setProperty(desc.code, 192) }
                }
                .frame(height: 22)
                .help("\(low) ← → \(high)，双击回到 0")
                Text(SonyPropertyCatalog.label(desc.code, v) ?? "0")
                    .monospacedDigit().frame(width: 44, alignment: .trailing)
                    .foregroundStyle(v == 192 ? .tertiary : .primary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(low)–\(high) 微调")
            .accessibilityValue(SonyPropertyCatalog.label(desc.code, cur) ?? "0")
        }
    }

    private func snap(_ x: CGFloat, _ w: CGFloat, _ lo: Int64, _ hi: Int64, _ step: Int64) -> Int64 {
        let f = Double(min(max((x - 7) / max(w - 14, 1), 0), 1))
        let s = Double(max(step, 1))
        let raw = Double(lo) + f * Double(hi - lo)
        return min(hi, max(lo, lo + Int64(((raw - Double(lo)) / s).rounded()) * Int64(s)))
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
    // 分组名来自 SonyFormat.driveMode（中文原文），显示时按 Localizable.xcstrings 翻译。
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
                    Menu(LocalizedStringKey(g)) {
                        let subs = inGroup.compactMap(\.sub).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        ForEach(inGroup.filter { $0.sub == nil }) { entry($0) }
                        ForEach(subs, id: \.self) { sub in
                            Menu(sub) { ForEach(inGroup.filter { $0.sub == sub }) { entry($0, short: true) } }
                        }
                    }
                }
            }
        } label: {
            MenuValueLabel(text: text)
        }
        .sidebarMenuStyle()
    }

    /// 包围子菜单里只写张数（组名和档位已在上级菜单）。
    @ViewBuilder private func entry(_ i: Item, short: Bool = false) -> some View {
        let label = short ? i.label.components(separatedBy: " EV ").last ?? i.label : i.label
        Button { choose(i.id) } label: {
            if i.id == current { Label(label, systemImage: "checkmark") } else { Text(label) }
        }
    }
}
