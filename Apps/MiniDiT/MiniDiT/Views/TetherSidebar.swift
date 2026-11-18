import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

// 联机拍摄窗口右边的侧栏（本次拍摄、图像设置、导入去向）和它用到的面板组件。

// MARK: 侧栏：本次拍摄、图像设置、导入

struct TetherSidebar: View {
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

/// 一组面板行的容器：只把各行上下叠在一起，不画底色和圆角。
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
