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
