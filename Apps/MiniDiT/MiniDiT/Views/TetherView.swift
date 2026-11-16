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
        return Button { picking = s.kind } label: {
            VStack(spacing: 3) {
                Text(s.kind.title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(cellValue(s)).font(.system(size: 17, weight: .medium).monospacedDigit())
                    .foregroundStyle(s.isEditable ? .primary : .tertiary)
                    .lineLimit(1)
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
        .popover(isPresented: Binding(get: { picking == s.kind }, set: { if !$0 { picking = nil } }), arrowEdge: .top) {
            OptionList(setting: s) { v in session.set(s.kind, value: v); picking = nil }
        }
    }

    /// 白平衡在色温或自定义时显示 K 值和微调，其余显示模式名。
    private func cellValue(_ s: CameraSetting) -> String {
        guard s.kind == .whiteBalance, let wb = s.currentValue else { return s.valueText }
        let p = session.properties
        var text = s.valueText
        if wb == 0x8012 || (0x8020...0x8023).contains(wb), let k = p[0xD20F]?.intValue, k > 0 { text = "\(k)K" }
        let tint = [UInt16(0xD21C), 0xD210].compactMap { c in p[c]?.intValue.flatMap { SonyPropertyCatalog.label(c, $0) } }.filter { $0 != "0" }
        return ([text] + tint).joined(separator: " ")
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
            guard let kind = hovered, picking == nil,
                  session.status.settings.first(where: { $0.kind == kind })?.isEditable == true,
                  event.window?.title.contains(session.cameraName) == true || event.window?.identifier?.rawValue.contains("tether") == true
            else { return event }
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 12 : event.scrollingDeltaY
            accumulated += dy
            if abs(accumulated) >= 1 {
                session.step(kind, by: accumulated > 0 ? 1 : -1)
                accumulated = 0
            }
            return nil
        }
    }
}

/// 参数的全部选项（弹出列表，打开时滚到当前值）。
private struct OptionList: View {
    let setting: CameraSetting
    let choose: (Int64) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(setting.options) { o in
                        Button { choose(o.value) } label: {
                            HStack {
                                Text(o.label).monospacedDigit()
                                Spacer()
                                if o.value == setting.currentValue { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(o.value == setting.currentValue ? Color.accentColor.opacity(0.12) : .clear)
                        .id(o.value)
                    }
                }
                .padding(.vertical, 6)
            }
            .frame(width: 170, height: min(CGFloat(setting.options.count) * 27 + 12, 360))
            .onAppear { if let v = setting.currentValue { proxy.scrollTo(v, anchor: .center) } }
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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    review
                    whiteBalanceCard
                    photoCard
                }
                .padding(16)
            }
            Divider()
            importBar
        }
        .background(Theme.surface)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
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
            HStack {
                sectionTitle("本次拍摄")
                Spacer()
                if !session.shots.isEmpty {
                    Text("\(session.shots.count) 张").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.sidebarGroup)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                } else if shot != nil {
                    ProgressView().controlSize(.small)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "photo").font(.system(size: 22, weight: .light))
                        Text("按空格拍摄").font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
                        .background(Capsule().fill(Theme.sidebarGroup))
                    Spacer()
                    if session.reviewedShotID != nil {
                        Button("回到最新") { session.reviewedShotID = nil }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
                if let e = exif {
                    if !e.exposureText.isEmpty { Text(e.exposureText).font(.system(size: 12).monospacedDigit()) }
                    if !e.gearText.isEmpty { Text(e.gearText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            if session.shots.count > 1 { filmstrip }
        }
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
                            Theme.sidebarGroup
                            if let t = session.thumbnail(for: shot) { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                        }
                        .frame(width: 60, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(shot.id == selected ? Color.accentColor : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(shot.id)
                }
            }
            .padding(.vertical, 1)
        }
        .frame(height: 42)
    }

    // MARK: 图像设置（分组卡片：标签在左，值在右）

    private var whiteBalanceCard: some View {
        let p = session.properties
        let wb = session.status.settings.first { $0.kind == .whiteBalance }
        let isTemp = wb?.currentValue == 0x8012
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("白平衡")
            PanelCard {
                PanelRow("模式", enabled: wb?.isEditable == true && !session.lost) {
                    if let wb, let v = wb.currentValue, !wb.options.isEmpty {
                        ValueMenu(text: wb.valueText, options: wb.options.map { ($0.value, $0.label) }, current: v) {
                            session.set(.whiteBalance, value: $0)
                        }
                    } else {
                        Text("—").foregroundStyle(.secondary)
                    }
                }
                if isTemp, let d = p[0xD20F] {
                    PanelDivider()
                    GradientSliderRow(session: session, desc: d, title: "色温",
                                      colors: [Color(red: 0.35, green: 0.55, blue: 1), Color(white: 0.92), Color(red: 1, green: 0.72, blue: 0.25)])
                } else if let k = p[0xD20F]?.intValue, k > 0 {
                    PanelDivider()
                    PanelRow("色温", enabled: false) { Text("\(k)K").monospacedDigit() }
                }
                if let ab = p[0xD21C], let gm = p[0xD210] {
                    PanelDivider()
                    WBShiftPad(session: session, ab: ab, gm: gm)
                }
                if p[0xD270] != nil {
                    PanelDivider()
                    PanelRow("取白", enabled: session.busy == nil && !session.lost) {
                        Menu {
                            ForEach(1...3, id: \.self) { slot in
                                Button("存入自定义 \(slot)") { captureWB(slot) }
                            }
                        } label: {
                            Label("对准灰卡后取白", systemImage: "eyedropper")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("先让相机对准灰卡或白纸，再选择存入哪个自定义白平衡。会覆盖该槽位原来的结果。")
                    }
                }
            }
        }
    }

    private func captureWB(_ slot: Int) {
        Task {
            do { _ = try await session.customWhiteBalance(slot: slot) }
            catch { session.message = (error as? AgentControlError).map { $0.message.components(separatedBy: " 过程：")[0] } ?? error.localizedDescription }
        }
    }

    @ViewBuilder private var photoCard: some View {
        let p = session.properties
        let fileTypeCode = [UInt16(0xD28B), 0xD253].first { p[$0]?.isWritable == true } ?? [UInt16(0xD28B), 0xD253].first { p[$0] != nil }
        let rows: [(String, UInt16)] = [("创意外观", 0xD0FA)] + (fileTypeCode.map { [("文件格式", $0)] } ?? []) + [("传到电脑", 0xD269)]
        let shown = rows.filter { r in p[r.1].map { $0.isEnabled != 0 && !$0.allowedValues.isEmpty } ?? false }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("照片")
                PanelCard {
                    ForEach(Array(shown.enumerated()), id: \.element.1) { i, r in
                        if i > 0 { PanelDivider() }
                        PropertyRow(session: session, title: r.0, code: r.1)
                    }
                }
            }
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
            .font(.system(size: 13))
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
        }
        .padding(12)
    }
}

// MARK: 面板组件

/// 圆角分组卡片（和系统设置的分组表单同一种层次）。
private struct PanelCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.035)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
    }
}

private struct PanelDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
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
        .font(.system(size: 13))
        .padding(.horizontal, 12)
        .frame(minHeight: 34)
        .opacity(enabled ? 1 : 0.55)
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

/// 范围型属性（色温）：渐变滑杆，松手时才发给相机（按档位取整）。
private struct GradientSliderRow: View {
    let session: TetherSession
    let desc: SonyPropertyDesc
    let title: String
    var center: Int64? = nil
    let colors: [Color]
    @State private var dragging: Int64?

    var body: some View {
        if case let .range(lo, hi, step) = desc.form, hi > lo, let current = desc.intValue {
            let value = dragging ?? current
            let enabled = desc.isWritable && !session.lost
            VStack(spacing: 6) {
                HStack {
                    Text(title).foregroundStyle(.secondary)
                    Spacer()
                    Text(SonyPropertyCatalog.label(desc.code, value) ?? "\(value)").monospacedDigit()
                }
                GeometryReader { geo in
                    let w = geo.size.width
                    let x = CGFloat(value - lo) / CGFloat(hi - lo) * w
                    ZStack(alignment: .leading) {
                        Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                            .frame(height: 5).opacity(enabled ? 0.9 : 0.4)
                        if let center {
                            Rectangle().fill(Color.primary.opacity(0.35)).frame(width: 1, height: 9)
                                .offset(x: CGFloat(center - lo) / CGFloat(hi - lo) * w)
                        }
                        Circle().fill(.white).frame(width: 15, height: 15)
                            .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.08)))
                            .offset(x: min(max(x - 7.5, -1), w - 14))
                    }
                    .frame(height: 16)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { g in dragging = snap(g.location.x / max(w, 1), lo, hi, step) }
                        .onEnded { g in
                            let v = snap(g.location.x / max(w, 1), lo, hi, step)
                            dragging = nil
                            if v != current { session.setProperty(desc.code, v) }
                        })
                }
                .frame(height: 18)
                .disabled(!enabled)
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .opacity(enabled ? 1 : 0.55)
            .help(enabled ? "拖动调整" : "当前设置下由相机决定")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue(SonyPropertyCatalog.label(desc.code, current) ?? "\(current)")
            .accessibilityAdjustableAction { dir in
                guard enabled else { return }
                let v = dir == .increment ? min(hi, current + step) : max(lo, current - step)
                session.setProperty(desc.code, v)
            }
        }
    }

    private func snap(_ f: CGFloat, _ lo: Int64, _ hi: Int64, _ step: Int64) -> Int64 {
        let raw = Double(lo) + Double(min(max(f, 0), 1)) * Double(hi - lo)
        let s = Double(max(step, 1))
        return min(hi, max(lo, lo + Int64(((raw - Double(lo)) / s).rounded()) * Int64(s)))
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
                    Text(readout(a, g)).monospacedDigit()
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
                        Circle().fill(Color(red: 0.92, green: 0.22, blue: 0.14))
                            .overlay(Circle().strokeBorder(Color.black.opacity(0.6), lineWidth: 1))
                            .frame(width: cell * 1.35, height: cell * 1.35)
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
                .frame(maxWidth: 156)
                .frame(maxWidth: .infinity)
                .disabled(!enabled)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("白平衡微调")
                .accessibilityValue(readout(curA, curG))
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 10)
            .opacity(enabled ? 1 : 0.55)
            .help(enabled ? "点按或拖动选择微调位置；右上角的箭头回到中心" : "当前设置下由相机决定")
        }
    }

    private func axis(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
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
        return Color(red: c.r, green: c.g, blue: c.b)
    }
}

/// 一个属性的选项（右对齐，相机没报告或未启用时不显示；仅显示时变淡）。
private struct PropertyRow: View {
    let session: TetherSession
    let title: String
    let code: UInt16

    var body: some View {
        if let d = session.properties[code], d.isEnabled != 0, case .enumeration(let list) = d.form, !list.isEmpty, let v = d.intValue {
            PanelRow(title, enabled: d.isWritable && !session.lost) {
                ValueMenu(text: SonyPropertyCatalog.label(code, v) ?? "\(v)",
                          options: list.map { ($0, SonyPropertyCatalog.label(code, $0) ?? "\($0)") }, current: v) {
                    session.setProperty(code, $0)
                }
            }
            .help(d.isWritable ? "" : "当前设置下由相机决定")
        }
    }
}
