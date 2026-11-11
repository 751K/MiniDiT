import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 320)
                .background(SidebarWidthFix(min: 220, ideal: 240, max: 280, column: 0))
                .toolbar(removing: .sidebarToggle)
        } content: {
            SourceDateSidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
                .background(SidebarWidthFix(min: 250, ideal: 300, max: 360, column: 1))
        } detail: {
            if let id = model.browsingSession, let session = model.sessions.first(where: { $0.id == id }) {
                SessionBrowser(session: session, media: model.browsingSessionMedia) { model.browseSession(nil) }
            } else {
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        BrowseHeader()
                        if model.offline { OfflineBanner() }
                        if model.phase == .loading {
                            LoadingGrid()
                        } else {
                            GridView()
                        }
                    }
                    // 窗口没有标题栏：顶栏直接放进标题栏那一行，不另留一条空白。
                    .ignoresSafeArea(.container, edges: .top)
                    FloatingBar()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .overlay {
            if model.previewShot != nil { PreviewOverlay() }
        }
    }
}

/// 主窗口改成单个 Window 场景后，系统不再遵守上面的列宽，侧栏每次打开都被挤到 144 pt。
/// 直接找到底下的 NSSplitViewController，把侧栏的最小 / 最大宽度设上，太窄时拉到合适宽度。
private struct SidebarWidthFix: NSViewRepresentable {
    let min: CGFloat, ideal: CGFloat, max: CGFloat
    let column: Int

    func makeNSView(context: Context) -> NSView { Probe(fix: self) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let fix: SidebarWidthFix
        init(fix: SidebarWidthFix) { self.fix = fix; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            var v: NSView? = superview
            while let cur = v, !(cur is NSSplitView) { v = cur.superview }
            guard let split = v as? NSSplitView,
                  split.arrangedSubviews.indices.contains(fix.column) else { return }
            if let ctrl = split.delegate as? NSSplitViewController,
               ctrl.splitViewItems.indices.contains(fix.column) {
                let item = ctrl.splitViewItems[fix.column]
                item.minimumThickness = fix.min
                item.maximumThickness = fix.max
            }
            if split.arrangedSubviews[fix.column].frame.width < fix.min {
                let leading = split.arrangedSubviews.prefix(fix.column).reduce(0) { $0 + $1.frame.width }
                split.setPosition(leading + fix.ideal, ofDividerAt: fix.column)
            }
        }
    }
}

// MARK: - 侧栏

/// 第一栏：导入目标和拍摄项目。这里不混入来源或日期。
struct ProjectSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                SessionSection()
            }
            .scrollIndicators(.hidden)
            Button { openSettings() } label: {
                Label("设置", systemImage: "slider.horizontal.3").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// 第二栏：当前要导入的来源，以及该来源下可选的具体日期。
struct SourceDateSidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            SourceCard()
            BrowseFilters()
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.sidebarGroup)
                )
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
    }
}

/// 侧栏顶上的来源卡片：当前相机 / 存储卡、卡槽切换。换来源在右边的菜单里。
private struct SourceCard: View {
    @Environment(AppModel.self) private var model
    @State private var focusedSourceID: Int?
    @State private var newName = ""
    @State private var newHost = ""

    var body: some View {
        VStack(spacing: 0) {
            sourceHeader

            ForEach(model.sources) { src in
                SourceManagerRow(
                    source: src,
                    focused: managedSourceID == src.id,
                    rename: startRename
                ) {
                    model.sourceFilter = nil
                    model.browseSession(nil)
                    focusedSourceID = src.id
                }
                .padding(.horizontal, 6)
            }
            if let id = managedSourceID, model.sourceSlots(id).count > 1 {
                Divider().padding(.horizontal, 10)
                SourceSlotPicker(id: id)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }
        }
        // 侧栏是系统的灰色底：分组用浅色半透明底跟着侧栏走，不用白底（白块在侧栏里很突兀）。
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.sidebarGroup))
        .accessibilityElement(children: .contain)
        .onAppear {
            model.sourceFilter = nil
            if focusedSourceID == nil { focusedSourceID = model.sources.first?.id }
        }
        .onChange(of: model.renamingSource) { _, id in if let id { newName = model.cardRoot(for: id).map { model.sourceIdentities.name(for: $0) } ?? model.profile(id)?.nickname ?? "" } }
        .alert("同时连接相机", isPresented: Bindable(model).askingHost) {
            TextField("IP 地址", text: $newHost)
            Button("连接") { model.addCamera(host: newHost); newHost = "" }
            Button("取消", role: .cancel) { newHost = "" }
        } message: {
            Text("输入相机的 IP 地址，例如 192.168.1.23。")
        }
        .alert("重命名“\(model.renamingSource.map(model.sourceName) ?? "")”",
               isPresented: Binding(get: { model.renamingSource != nil }, set: { if !$0 { model.renamingSource = nil } })) {
            TextField("名称", text: $newName)
            Button("好") { if let id = model.renamingSource { model.rename(id, to: newName) }; model.renamingSource = nil }
            Button("取消", role: .cancel) { model.renamingSource = nil }
        } message: {
            Text(model.renamingSource.flatMap { model.cardRoot(for: $0) } != nil
                 ? "为这张卡命名，例如“主机卡 01”。不会修改拍摄相机的名称。"
                 : "例如“主机”“副机”。无法读取机身序列号时，仅用于本次连接。")
        }
        .sheet(isPresented: Binding(get: { model.confirmingCard != nil }, set: { if !$0 { model.confirmingCard = nil } })) {
            if let id = model.confirmingCard, let root = model.cardRoot(for: id) {
                CardIdentityConfirmation(sourceID: id, root: root).environment(model)
            }
        }
    }

    private func startRename(_ id: Int) { model.renamingSource = id }

    /// 重新读列表：相机里新拍的照片要读一次才出现。
    private var refreshButton: some View {
        Button { model.refreshSources() } label: {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.progress != nil || model.phase != .ready)
        .help("重新读取（⌘R）：显示相机中新拍的照片")
        .accessibilityLabel("重新读取")
    }

    private var addSourceMenu: some View {
        Menu {
            let openCards = Set(([model.cardRoot] + model.extraSources.map(\.root)).compactMap { $0?.standardizedFileURL })
            let cards = model.cards.filter { !openCards.contains($0.standardizedFileURL) }
            let cameras = model.knownCameras.filter {
                !model.openFingerprints.contains($0.fingerprint) && !model.openHosts.contains($0.host)
            }
            ForEach(cards, id: \.self) { url in
                Button("添加存储卡：\(url.lastPathComponent)") { model.addCard(url) }
            }
            ForEach(cameras) { k in
                Button("\(k.displayName) · \(k.host)") { model.addCamera(known: k) }
            }
            if !cards.isEmpty || !cameras.isEmpty { Divider() }
            Button("输入相机地址…") { model.askingHost = true }
            Button("搜索相机或存储卡…") { model.disconnect() }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(model.progress != nil)
        .help("添加或切换来源")
        .accessibilityLabel("添加或切换来源")
    }

    /// 来源区的标题；每个来源本身在下面单独列出，不混在筛选菜单里。
    private var sourceHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("设备").font(.system(size: 15, weight: .semibold))
                Spacer()
                refreshButton
                addSourceMenu
            }
            if model.clocksUnaligned {
                Label("相机时间尚未对齐", systemImage: "clock.badge.exclamationmark")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                    .help("各相机的时钟可能不一致，合并后的顺序会错位。选中两台相机在同一时刻拍的各一张照片，右键选“按这两张对齐时间”。")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var managedSourceID: Int? {
        if model.sources.count == 1 { return AppModel.primarySource }
        if let focusedSourceID, model.sources.contains(where: { $0.id == focusedSourceID }) {
            return focusedSourceID
        }
        return model.sources.first?.id
    }
}

/// 来源管理器的一行：点主体筛选这个来源，右边的按钮只负责推出或断开。
private struct SourceManagerRow: View {
    @Environment(AppModel.self) private var model
    let source: SourceSummary
    let focused: Bool
    let rename: (Int) -> Void
    let focus: () -> Void
    @State private var hover = false

    /// 卡槽限制、时钟校正。
    private var extra: String {
        var s = ""
        if model.sourceSlots(source.id).count > 1, let slot = model.onlySlot(source.id) {
            s += " · 仅卡 \(slot)"
        }
        if let t = model.profile(source.id)?.clockOffset, t != 0 { s += " · 时间 " + CameraProfile.offsetText(t) }
        return s
    }

    var body: some View {
        let total = model.shotCount(source: source.id)
        HStack(spacing: 4) {
            Button(action: focus) {
                HStack(spacing: 8) {
                    Image(systemName: source.isCard ? "sdcard" : "camera")
                        .font(.system(size: 13, weight: source.isCard ? .regular : .semibold))
                        .foregroundStyle(source.isCard ? (focused ? Theme.accent : Color.secondary) : Color.primary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.sourceLabel(source.id))
                            .font(Theme.Font.headline)
                            .fontWeight(focused ? .semibold : .regular)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            if (source.id == AppModel.primarySource && model.offline) || source.offline {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                                Text("已断开，正在重新连接…")
                            } else if source.connecting {
                                ProgressView().controlSize(.mini)
                                Text("正在连接…")
                            } else {
                                Text(source.detail + extra)
                            }
                        }
                        .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                        .help(source.detail + extra)
                    }
                    Spacer(minLength: 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(focused ? .isSelected : [])
            .help(focused ? "正在设置此来源的卡槽；所有已打开来源都会参与导入"
                           : "设置此来源的卡槽；不会关闭其他导入来源")

            if model.cardNeedsConfirmation(source.id) {
                Button("确认身份") { model.confirmingCard = source.id }
                    .buttonStyle(.link).font(.system(size: 12))
                    .disabled(model.progress != nil)
            }
            ZStack(alignment: .trailing) {
                Text("\(total)")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(hover ? 0 : 1)
                    .help("共 \(total) 次拍摄")
                if hover {
                    Button {
                        if source.isCard, source.id != AppModel.primarySource { model.ejectExtra(source.id) }
                        else if source.isCard { model.ejectCard() }
                        else { model.removeSource(source.id) }
                    } label: {
                        Image(systemName: source.isCard ? "eject" : "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.progress != nil)
                    .help(source.isCard ? "推出 \(source.detail.replacingOccurrences(of: "读卡器 · ", with: ""))" : "断开此相机")
                    .accessibilityLabel(source.isCard ? "推出存储卡" : "断开相机")
                }
            }
            .frame(minWidth: 44, alignment: .trailing)
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(focused ? Theme.accent.opacity(0.12) : .clear)
        )
        .onHover { hover = $0 }
        .contextMenu {
            SourceMenu(id: source.id, rename: rename)
            Divider()
            Button(source.isCard ? "推出存储卡" : "断开相机", role: .destructive) {
                if source.isCard, source.id != AppModel.primarySource { model.ejectExtra(source.id) }
                else if source.isCard { model.ejectCard() }
                else { model.removeSource(source.id) }
            }
            .disabled(model.progress != nil)
        }
    }
}

/// 来源的右键菜单：改名、只导某个卡槽（Wi-Fi 相机）、清除时间校正。改的是这台机身的档案。
struct SourceMenu: View {
    @Environment(AppModel.self) private var model
    let id: Int
    let rename: (Int) -> Void

    var body: some View {
        if model.cardRoot(for: id) != nil {
            Button(model.sourceIdentitySnapshot(id).kind == .directory ? "重命名目录…" : "重命名存储卡…") {
                if model.cardNeedsConfirmation(id) { model.confirmingCard = id }
                else { rename(id) }
            }
            Button(model.sourceIdentitySnapshot(id).kind == .directory ? "确认目录身份…" : model.cardNeedsConfirmation(id) ? "确认存储卡身份…" : "更正存储卡身份…") { model.confirmingCard = id }
            if model.cardNeedsConfirmation(id) { Text("身份待确认；当前仍可导入") }
        } else {
            Button("重命名相机…") { rename(id) }
            if model.profileKey(id) == nil { Text("序列号未知，设置仅用于本次连接") }
            if id == AppModel.primarySource, model.sourceKind == .camera, !model.isMultiSource {
                Picker("导入卡槽", selection: Binding(get: { model.onlySlot(id) ?? 0 },
                                                   set: { model.setOnlySlot(id, $0 == 0 ? nil : $0) })) {
                    Text("全部卡槽").tag(UInt32(0))
                    Text("仅卡 1").tag(UInt32(1))
                    Text("仅卡 2").tag(UInt32(2))
                }
            }
        }
        if let t = model.profile(id)?.clockOffset {
            Button("清除时间校正（\(CameraProfile.offsetText(t))）") { model.clearClockOffset(id) }
        }
    }
}

/// 几个来源时，一台 Wi-Fi 相机只看 / 只导哪张卡：全部 / 卡 1 / 卡 2。按机身记住（同「导入卡槽」）。
private struct SourceSlotPicker: View {
    @Environment(AppModel.self) private var model
    let id: Int

    var body: some View {
        let options: [SegmentPicker<UInt32?>.Option] = [.init(title: "合并", value: nil)]
            + model.sourceSlots(id).map { .init(title: "卡 \($0)", value: $0) }
        ChoicePicker(title: "卡槽", options: options,
                     selection: Binding(get: { model.onlySlot(id) }, set: { model.setOnlySlot(id, $0) }))
            .disabled(model.progress != nil)
            .help("合并两卡会去重；也可只看并只导入卡 1 或卡 2")
    }
}

/// 单选：不超过三项用玻璃分段（撑满整行），再多用系统弹出菜单（见 docs/MiniDiT-DESIGN.md）。
struct ChoicePicker<T: Hashable>: View {
    let title: String
    let options: [SegmentPicker<T>.Option]
    @Binding var selection: T

    var body: some View {
        if options.count <= 3 {
            SegmentPicker(options: options, selection: $selection, fill: true)
                .accessibilityLabel(title)
        } else {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.value) { Text($0.title + ($0.count.map { " \($0)" } ?? "")).tag($0.value) }
            }
            .labelsHidden()
        }
    }
}

private struct DayRow: View {
    /// 选中的行是蓝底：勾选框一律用白色；没选中的行用强调色 / 灰色。
    private func checkColor(_ state: CheckState) -> Color {
        if model.shownDays.contains(day.id) { return .white }
        return state == .off ? Color(nsColor: .tertiaryLabelColor) : .accentColor
    }

    @Environment(AppModel.self) private var model
    let day: ShootingDay

    var body: some View {
        let state = model.checkState(day)
        HStack(spacing: 8) {
            Button { model.toggleDay(day) } label: {
                Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                    .font(.system(size: 15))
                    .foregroundStyle(checkColor(state))
                    .frame(width: 18, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入 \(day.title)")
            .accessibilityValue(state == .on ? "已勾选" : state == .mixed ? "部分勾选" : "未勾选")
            .help(day.newCount > 0 ? "勾选当日 \(AppModel.countText(photos: day.newPhotos, videos: day.newVideos, fresh: true))" : "勾选当日全部内容")
            DayTitle(title: day.title)
            Spacer(minLength: 4)
            let copies = day.newCount > 0 ? 0 : (day.shots.map { model.copyCount(shot: $0) }.min() ?? 0)
            ShotCounts(new: day.newCount, total: day.shots.count, copies: copies, size: 12)
        }
        .contextMenu {
            Button("选择当日新照片") { model.selectNew(in: [day.id]) }
            Button("选择当日全部照片") { model.selectAll(in: [day.id]) }
            Button("取消选择当日照片") { model.deselect(in: [day.id]) }
            Divider()
            SceneGapMenu()
        }
    }
}

/// 侧栏的日期：「11月4日 周三」拆成日期和星期，日期占固定宽度（按最长的「00月00日」留位），星期上下对齐。
private struct DayTitle: View {
    let title: String

    var body: some View {
        let parts = title.split(separator: " ", maxSplits: 1).map(String.init)
        if parts.count == 2 {
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    // 占位：数字换成 0，月和日都按两位算。
                    Text(parts[0].contains("年") ? "0000年00月00日" : "00月00日").hidden()
                    Text(parts[0])
                }
                .monospacedDigit()
                Text(parts[1]).foregroundStyle(.secondary)
            }
            .lineLimit(1)
        } else {
            Text(title).lineLimit(1)
        }
    }
}

/// 侧栏右边：有新照片时写「6 新」，都导入过时打勾（只有一份的打橙色勾），最右边是总张数。
private struct ShotCounts: View {
    let new: Int
    let total: Int
    /// 都导入过时最少的份数（决定勾的颜色）。
    let copies: Int
    let size: CGFloat

    var body: some View {
        HStack(spacing: 8) {
            // 还有没导入的不另外标数字；全部导入过才打勾。
            if new == 0 {
                Image(systemName: "checkmark").font(.system(size: size - 2, weight: .semibold))
                    .foregroundStyle(copies == 1 ? Theme.warning : Color.secondary)
                    .help(copies == 1 ? "均已导入，部分照片仅存有一份" : "均已导入")
            }
            Text(total.formatted()).font(.system(size: size).monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 22, alignment: .trailing)
        }
    }
}

/// 侧栏里日期下面的场次：勾选框选这一场，点中这一行右边只显示这一场。
private struct SceneRow: View {
    @Environment(AppModel.self) private var model
    let scene: ShootingScene
    let day: ShootingDay

    var body: some View {
        let state = model.checkState(scene)
        let shown = model.shownDays.contains(scene.id)
        HStack(spacing: 8) {
            Button { model.toggleScene(scene, in: day) } label: {
                Image(systemName: state == .on ? "checkmark.square.fill" : state == .mixed ? "minus.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(shown ? .white : state == .off ? Color(nsColor: .tertiaryLabelColor) : .accentColor)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("导入 \(day.title) \(AppModel.sceneTitle(scene))")
            .accessibilityValue(state == .on ? "已勾选" : state == .mixed ? "部分勾选" : "未勾选")
            .help(scene.newCount > 0 ? "勾选该场次 \(AppModel.countText(photos: scene.newPhotos, videos: scene.newVideos, fresh: true))" : "勾选该场次全部内容")
            Text(scene.timeRange.isEmpty ? "第 \(scene.number) 场" : scene.timeRange).font(Theme.Font.caption).lineLimit(1)
            Spacer(minLength: 4)
            ShotCounts(new: scene.newCount, total: scene.shots.count, copies: 2, size: 11)
        }
        .padding(.leading, 18)
        .contextMenu { SceneGapMenu() }
    }
}

/// 「按时间分场次」：不分 / 隔多久分一场。和「设置 › 照片 › 场次」是同一个选项。
struct SceneGapMenu: View {
    @Environment(AppModel.self) private var model

    static let options: [(String, Int)] = [("不分场次", 0), ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("3 小时", 180), ("4 小时", 240)]

    var body: some View {
        @Bindable var model = model
        Picker("按时间分场次", selection: $model.sceneGap) {
            ForEach(Self.options, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
}

// MARK: - 标题区

struct BrowseHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                let counts = model.countTitle
                Text(counts.new)
                    .font(Theme.Font.headline)
                Text(counts.total)
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Slider(value: $model.thumbSize, in: 110...320)
                .frame(width: 76)
                .accessibilityLabel("缩略图大小")
                .help("缩略图大小（⌘+ / ⌘−）")
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(minHeight: 52)
    }
}

private struct BrowseFilters: View {
    @Environment(AppModel.self) private var model
    @State private var dateAnchor: String?

    private var dateRowCount: Int {
        model.days.reduce(0) { count, day in
            count + 1 + (day.scenes.count > 1 ? day.scenes.count : 0)
        }
    }

    private var dateListHeight: CGFloat {
        max(90, min(CGFloat(dateRowCount) * 31, 300))
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("筛选").font(.system(size: 15, weight: .semibold))
                Spacer()
                if model.hasImportFilters {
                    Button("清除") { model.resetImportFilters() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("显示").font(Theme.Font.caption).foregroundStyle(.secondary)
                SegmentPicker(options: [.init(title: "全部", value: false), .init(title: "未导入", value: true)],
                              selection: $model.onlyNew, fill: true)
                    .accessibilityLabel("显示范围")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("导入内容").font(Theme.Font.caption).foregroundStyle(.secondary)
                SegmentPicker(options: ImportContent.allCases.map { .init(title: $0.title, value: $0) },
                              selection: $model.importContent, fill: true)
                    .disabled(model.progress != nil)
                    .accessibilityLabel("导入内容")
            }
            if model.importContent != .videos {
                VStack(alignment: .leading, spacing: 4) {
                    Text("照片格式").font(Theme.Font.caption).foregroundStyle(.secondary)
                    MultiSegmentPicker(options: [
                        .init(title: "RAW", isOn: $model.showRaw),
                        .init(title: "JPG/HIF", isOn: $model.showPhotos),
                    ], fill: true)
                    .disabled(model.progress != nil)
                    .accessibilityLabel("照片格式")
                }
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索文件名或设备", text: $model.mediaFilter.query)
                        .textFieldStyle(.plain)
                        .font(Theme.Font.body)
                        .accessibilityLabel("搜索素材")
                    if !model.mediaFilter.query.isEmpty {
                        Button { model.mediaFilter.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清除搜索")
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )

                let markIsActive = model.mediaFilter.mark != .all
                Menu {
                    ForEach(MediaFilter.Mark.allCases, id: \.self) { mark in
                        Button((mark == model.mediaFilter.mark ? "✓ " : "") + mark.menuTitle) {
                            model.mediaFilter.mark = mark
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "tag")
                        Text(model.mediaFilter.mark.shortTitle).lineLimit(1)
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(markIsActive ? Theme.accent : Color.secondary)
                    .padding(.horizontal, 9)
                    .frame(height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(markIsActive ? Theme.accent.opacity(0.13) : Color.primary.opacity(0.06))
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("按机内标记筛选")
            }
            Divider()
            Text("日期").font(.system(size: 15, weight: .semibold))
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.days) { day in
                        FilterDayRow(
                            day: day,
                            selected: model.shownDays.contains(day.id)
                        ) {
                            selectDate(day.id)
                        }
                        if day.scenes.count > 1 {
                            ForEach(day.scenes) { scene in
                                FilterSceneRow(
                                    scene: scene,
                                    day: day,
                                    selected: model.shownDays.contains(scene.id)
                                ) {
                                    selectDate(scene.id)
                                }
                            }
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
            .frame(height: dateListHeight)
            .transaction { $0.animation = nil }
            if model.metadataLoading {
                ProgressView().controlSize(.mini)
                Text("正在读取标记…").foregroundStyle(.secondary).lineLimit(1)
            } else if model.isRefreshingSources {
                ProgressView().controlSize(.mini)
                Text("正在刷新…").foregroundStyle(.secondary).lineLimit(1)
            } else if let message = model.refreshMessage {
                Text(message).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .font(Theme.Font.caption)
        .padding(12)
    }

    private func selectDate(_ id: String) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let current = model.shownDays
        let selected: Set<String>
        if flags.contains(.command) {
            selected = current.contains(id) ? current.subtracting([id]) : current.union([id])
        } else if flags.contains(.shift), let anchor = dateAnchor,
                  let a = model.days.firstIndex(where: { $0.id == anchor }),
                  let b = model.days.firstIndex(where: { $0.id == id }) {
            selected = Set(model.days[min(a, b)...max(a, b)].map(\.id))
        } else {
            selected = [id]
        }
        guard !selected.isEmpty else { return }
        let removed = current.subtracting(selected)
        let added = selected.subtracting(current)
        for date in removed { deselectNew(in: date) }
        dateAnchor = id
        model.browseSession(nil)
        model.shownDays = selected
        for date in added { selectNew(in: date) }
        if added.isEmpty, current == Set([id]) { selectNew(in: id) }
    }

    private func selectNew(in id: String) {
        if let day = model.days.first(where: { $0.id == id }) {
            model.grid.set(day.shots.filter { !model.isImported(shot: $0) }, selected: true)
        } else if let scene = model.days.flatMap(\.scenes).first(where: { $0.id == id }) {
            model.grid.set(scene.shots.filter { !model.isImported(shot: $0) }, selected: true)
        }
    }

    private func deselectNew(in id: String) {
        if let day = model.days.first(where: { $0.id == id }) {
            model.grid.set(day.shots, selected: false)
        } else if let scene = model.days.flatMap(\.scenes).first(where: { $0.id == id }) {
            model.grid.set(scene.shots, selected: false)
        }
    }
}

/// 筛选卡里的日期行：去掉系统 List 的深层缩进和分隔线，只保留紧凑的悬停 / 选中底。
private struct FilterDayRow: View {
    @Environment(AppModel.self) private var model
    let day: ShootingDay
    let selected: Bool
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                DayTitle(title: day.title)
                Spacer(minLength: 4)
                let copies = day.newCount > 0 ? 0 : (day.shots.map { model.copyCount(shot: $0) }.min() ?? 0)
                ShotCounts(new: day.newCount, total: day.shots.count, copies: copies, size: 13)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 15))
        .padding(.trailing, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.13) : hover ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hover = $0 }
        .contextMenu {
            Button("选择当日新照片") { model.selectNew(in: [day.id]) }
            Button("选择当日全部照片") { model.selectAll(in: [day.id]) }
            Button("取消选择当日照片") { model.deselect(in: [day.id]) }
            Divider()
            SceneGapMenu()
        }
    }
}

private struct FilterSceneRow: View {
    @Environment(AppModel.self) private var model
    let scene: ShootingScene
    let day: ShootingDay
    let selected: Bool
    let select: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Text(scene.timeRange.isEmpty ? "第 \(scene.number) 场" : scene.timeRange)
                    .font(.system(size: 13))
                Spacer(minLength: 4)
                ShotCounts(new: scene.newCount, total: scene.shots.count, copies: 2, size: 12)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 14))
        .padding(.leading, 24).padding(.trailing, 8).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.13) : hover ? Color.primary.opacity(0.05) : .clear)
        )
        .onHover { hover = $0 }
        .contextMenu { SceneGapMenu() }
    }
}

private struct ImportOptions: View {
    @Environment(AppModel.self) private var model
    @State private var showingDestinations = false

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 6) {
            // 底栏浮在照片上：开关和按钮都用系统玻璃样式，尺寸和导入按钮一致。
            // 选中了 Wi-Fi 相机上的视频时才出现：只导代理，原片留在卡上。
            if model.selectionHasWiFiVideo {
                GlassToggle(title: "仅代理", isOn: $model.proxyOnlyWiFi)
                .help(model.proxyOnlyWiFi ? "视频只导入代理和 XML，原片留在存储卡上；点按改为导入原片"
                                          : "导入视频原片；点按改为只导入代理，原片留在存储卡上，之后可用读卡器导入")
            }
            GlassToggle(title: "备份", isOn: $model.backupEnabled)
            .help(model.backupEnabled ? "同时备份至另一磁盘；点按改为仅存储一份" : "仅存储一份；点按以同时备份")

            Button { showingDestinations.toggle() } label: {
                Image(systemName: "folder").frame(height: 20)
            }
            .glassButton().accessibilityLabel("查看本次存放位置")
            .help("查看照片、视频和备份将存到哪里")
            .popover(isPresented: $showingDestinations) {
                ImportDestinationPreview(files: model.selectedFiles())
            }
            Menu {
                if model.importContent != .videos {
                    Button("更改照片存放位置…") { chooseFolder(video: false) }
                }
                if model.importContent != .photos {
                    Button("更改视频存放位置…") { chooseFolder(video: true) }
                }
                Divider()
                Toggle("完成后删除存储卡上的原片", isOn: $model.deleteAfterImport)
                    .disabled(!model.canDeleteFromSource)
                if !model.canDeleteFromSource {
                    Text("仅适用于读卡器")
                }
                if model.canSplitBySlot {
                    Divider()
                    Toggle("按卡槽分子文件夹", isOn: $model.splitBySlot)
                    Text("仅适用于 Wi-Fi 连接的相机")
                }
            } label: {
                // 菜单按钮不跟着 controlSize 变高，给图标一个和文字按钮一样的高度。
                Image(systemName: "ellipsis").frame(height: 20)
            }
            .menuStyle(.button).glassButton().menuIndicator(.hidden).controlSize(.extraLarge)
            .fixedSize()
            .accessibilityLabel("更多操作")
            .help("更多操作")
        }
        .controlSize(.extraLarge)
        .fixedSize()
    }

    /// 新建会话改的是会话放在哪；其余方式改的是照片存放位置。
    private func chooseFolder(video: Bool) {
        if video {
            if let url = FolderPicker.choose(start: model.videoDestination) { model.videoDestination = url }
        } else if model.captureOneMode == .newSession {
            if let url = FolderPicker.choose(start: model.sessionsFolder) { model.sessionsFolder = url }
        } else {
            if let url = FolderPicker.choose(start: model.destination) { model.destination = url }
        }
    }
}

struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("相机已断开，正在重新连接").fontWeight(.semibold)
            Text("已保留当前选择").foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("重新连接") { model.reconnectNow() }.glassButton()
        }
        .padding(.init(top: 8, leading: 12, bottom: 8, trailing: 8))
        .glassRounded(10)
        .padding(.horizontal, 20).padding(.bottom, 8)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 网格

private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [UInt32: CGRect] = [:]
    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct LoadingGrid: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(model.status.isEmpty ? "正在读取照片列表…" : model.status).font(Theme.Font.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbSize), spacing: 16)], spacing: 16) {
                    ForEach(0..<12, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)).aspectRatio(3 / 2, contentMode: .fit)
                            RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)).frame(width: model.thumbSize * 0.6, height: 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .disabled(true)
        .accessibilityLabel("正在读取照片列表")
    }
}

struct GridView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var frames: [UInt32: CGRect] = [:]
    @State private var box: CGRect?
    @State private var width: CGFloat = 800
    @State private var height: CGFloat = 600

    /// 格子四周各有 7 pt 留给选中框和焦点框，所以列间距 2、行间距 4 看起来是 16 / 18。
    private var spacing: CGFloat { 2 }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: model.thumbSize + 14, maximum: (model.thumbSize + 14) * 1.6), spacing: spacing)] }
    /// 和 LazyVGrid 的自适应列数算法一致，方向键上下移动用。
    private var columnCount: Int { max(1, Int((width - 26 + spacing) / (model.thumbSize + 14 + spacing))) }

    var body: some View {
        if model.visibleDays.isEmpty {
            EmptyState()
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(model.visibleDays) { day in
                            Section {
                                if day.scenes.count > 1 {
                                    // 分了场次：每场一个小标题，最后一场下面留出和日期之间的间距。
                                    ForEach(day.scenes) { scene in
                                        SceneHeader(scene: scene, day: day).id(scene.id)
                                        cells(scene.shots, bottom: scene.id == day.scenes.last?.id ? 20 : 10)
                                    }
                                } else {
                                    cells(day.shots, bottom: 20)
                                }
                            } header: {
                                DayHeader(day: day)
                            }
                        }
                    }
                    .padding(.bottom, 96)
                    // 内容不满一屏时也撑满可视区；空白处（行间、底部）也能开始框选。
                    .frame(maxWidth: .infinity, minHeight: height, alignment: .top)
                    .contentShape(Rectangle())
                    .coordinateSpace(name: "grid")
                    .overlay(alignment: .topLeading) {
                        if let box {
                            Rectangle().fill(Color.accentColor.opacity(0.12))
                                .overlay(Rectangle().stroke(Color.accentColor.opacity(0.7), lineWidth: 1))
                                .frame(width: box.width, height: box.height)
                                .offset(x: box.minX, y: box.minY)
                                .allowsHitTesting(false)
                        }
                    }
                    .simultaneousGesture(boxGesture)
                }
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { width = g.size.width; height = g.size.height }
                        .onChange(of: g.size) { width = $1.width; height = $1.height }
                })
                .onPreferenceChange(CellFrameKey.self) { frames = $0 }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onAppear { focused = true }
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let dir: GridSelection<UInt32>.Direction = switch press.key {
                    case .leftArrow: .left
                    case .rightArrow: .right
                    case .upArrow: .up
                    default: .down
                    }
                    model.grid.move(dir, columns: columnCount, extend: press.modifiers.contains(.shift))
                    if let f = model.grid.focus { proxy.scrollTo(f) }
                    return .handled
                }
                .onKeyPress(.space) { model.openPreview(); return .handled }
                .onKeyPress(.escape) { model.grid.clear(); return .handled }
                .onCommand(#selector(NSResponder.selectAll(_:))) { model.grid.selectAll() }
            }
        }
    }

    private func cells(_ shots: [UInt32], bottom: CGFloat) -> some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(shots, id: \.self) { id in
                ThumbCell(shotID: id)
                    .id(id)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: CellFrameKey.self, value: [id: g.frame(in: .named("grid"))])
                    })
            }
        }
        .padding(.init(top: 2, leading: 13, bottom: bottom, trailing: 13))
    }

    /// 已选中的缩略图用于拖出文件；空白处或未选中处开始框选（⌘ / ⇧ 增减）。
    private var boxGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("grid"))
            .onChanged { v in
                if box == nil {
                    let flags = NSEvent.modifierFlags
                    if flags.intersection([.command, .shift]).isEmpty,
                       frames.contains(where: { model.grid.contains($0.key) && $0.value.contains(v.startLocation) }) { return }
                    model.grid.beginBox(additive: flags.contains(.command) || flags.contains(.shift))
                    focused = true
                }
                let r = CGRect(x: min(v.startLocation.x, v.location.x), y: min(v.startLocation.y, v.location.y),
                               width: abs(v.location.x - v.startLocation.x), height: abs(v.location.y - v.startLocation.y))
                box = r
                model.grid.updateBox(Set(frames.filter { $0.value.intersects(r) }.keys))
            }
            .onEnded { _ in
                box = nil
                model.grid.endBox()
            }
    }
}

private struct EmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(Theme.Font.headline)
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.days.isEmpty && model.onlyNew {
                Button("显示全部") { model.onlyNew = false }
                    .buttonStyle(.bordered).padding(.top, 10)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        if !model.days.isEmpty { return "请在左侧选择日期" }
        return model.onlyNew ? "这些照片均已导入" : "无符合筛选条件的文件"
    }

    private var detail: String {
        if !model.days.isEmpty { return "点按日期以查看照片；按住 ⌘ 或 ⇧ 可选择多天。" }
        return model.onlyNew ? "切换至“全部”即可查看。" : "请在上方显示更多文件类型，或更换存储卡。"
    }
}

struct DayHeader: View {
    @Environment(AppModel.self) private var model
    let day: ShootingDay

    var body: some View {
        let picked = day.shots.contains(where: model.grid.contains)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.title).font(Theme.Font.headline).foregroundStyle(.primary)
            if day.partial, day.scenes.count == 1 {
                Text(AppModel.sceneTitle(day.scenes[0])).font(Theme.Font.headline).foregroundStyle(.primary)
            }
            Text(GroupMeta.text(photos: day.photos, videos: day.videos,
                                newPhotos: day.newPhotos, newVideos: day.newVideos))
            Spacer(minLength: 8)
            Button(picked ? "取消选择" : day.newCount > 0 ? "选择当前范围未导入素材" : "全选当前范围") {
                if picked { model.deselect(in: [day.id]) }
                else if day.newCount > 0 { model.selectNew(in: [day.id]) }
                else { model.selectAll(in: [day.id]) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 7)
        .background(.bar)   // 滚动时浮在缩略图上，毛玻璃底
    }
}

/// 一天里分了场次时，每场上面的小标题。
struct SceneHeader: View {
    @Environment(AppModel.self) private var model
    let scene: ShootingScene
    let day: ShootingDay

    var body: some View {
        let picked = scene.shots.contains(where: model.grid.contains)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(AppModel.sceneTitle(scene)).font(Theme.Font.headline).foregroundStyle(.primary)
            Text(GroupMeta.text(photos: scene.photos, videos: scene.videos,
                                newPhotos: scene.newPhotos, newVideos: scene.newVideos))
            Spacer(minLength: 8)
            Button(picked ? "取消选择" : scene.newCount > 0 ? "选择当前范围未导入素材" : "全选当前范围") {
                if picked { model.grid.set(scene.shots, selected: false) }
                else if scene.newCount > 0 { model.grid.set(scene.shots.filter { !model.isImported(shot: $0) }, selected: true) }
                else { model.grid.set(scene.shots, selected: true) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 2)
    }
}

/// 「870 张 · 6 张新照片」/「112 张 · 均已导入」/「12 张照片、3 个片段 · 2 个新片段」。
enum GroupMeta {
    /// 用 rebuild 里算好的计数，避免每次渲染都扫一遍 shots。
    @MainActor static func text(photos: Int, videos: Int, newPhotos: Int, newVideos: Int) -> String {
        let total = photos + videos
        let fresh = newPhotos + newVideos
        let all = fresh == total
            ? (videos == 0 ? "均为新照片" : videos == total ? "均为新片段" : "均未导入")
            : AppModel.countText(photos: newPhotos, videos: newVideos, fresh: true)
        return AppModel.countText(photos: photos, videos: videos) + " · " + (fresh == 0 ? "均已导入" : all)
    }
}

struct ThumbCell: View {
    @Environment(AppModel.self) private var model
    let shotID: UInt32

    var body: some View {
        let shot = model.shots[shotID]
        let primary = shot?.primary ?? shotID
        let item = model.item(primary)
        let selected = model.grid.contains(shotID)
        let focused = model.grid.focus == shotID
        let imported = model.isImported(shot: shotID)
        VStack(alignment: .leading, spacing: 5) {
            // 先定一个 3:2 的框，图片在框里裁切填满：不同来源的缩略图比例不同（RAW 的是 4:3 带黑边）。
            Color.primary.opacity(0.06)
                .aspectRatio(3 / 2, contentMode: .fit)
                .overlay {
                    if let img = model.thumbnails[primary] {
                        Image(nsImage: img).resizable().scaledToFill()
                    } else {
                        Image(systemName: shot?.isVideo == true ? "video" : "photo").foregroundStyle(.tertiary)
                    }
                }
                .clipped()
            .overlay(alignment: .bottomLeading) {
                if let shot { Badge(text: model.badge(of: shot)).padding(5) }
            }
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    // 视频：伽马和帧率（「S-Log3 59.94p」），升格时帧率写成「120p→23.98p」。
                    if shot?.isVideo == true, model.thumbSize >= 150, let c = model.clipInfos[primary] {
                        Badge(text: [c.gammaText, c.fpsText].filter { !$0.isEmpty }.joined(separator: " "))
                    }
                    // Shot Mark：「◆ 2」= 打了两个。
                    if shot?.isVideo == true, let n = model.clipInfos[primary]?.shotMarks.count, n > 0 {
                        Badge(text: "◆ \(n)").help("Shot Mark × \(n)")
                    }
                    // 机内星级。
                    if let shot, let r = model.rating(of: shot), r != 0 {
                        Badge(text: r < 0 ? "✕" : String(repeating: "★", count: min(r, 5)))
                            .help(r < 0 ? "相机中标为删除" : "相机中打了 \(r) 星")
                    }
                }
                .padding(5)
            }
            .overlay(alignment: .bottomTrailing) {
                if !imported, model.proxyOnlyCopy(shot: shotID) != nil {
                    Badge(text: model.thumbSize >= 150 ? "仅代理" : "", checks: 1, checkColor: .blue).padding(5)
                        .help("已导入代理，原片尚未导入")
                }
                if imported {
                    let copies = model.copyCount(shot: shotID)
                    let text = copies > 2 ? "\(copies) 份副本" : copies == 2 ? "已备份" : copies == 1 ? "已导入" : "不可访问"
                    Badge(text: model.thumbSize >= 150 ? text : "",
                          checks: copies >= 2 ? 2 : copies == 1 ? 1 : 0,
                          checkColor: copies == 1 ? Theme.warning : Theme.accent).padding(5)
                        .help(copies >= 2 ? "当前可访问 \(copies) 份文件；仅检查存在和大小，不代表磁盘独立或刚完成内容复核" : copies == 1 ? "当前可访问一份；另一份可能未备份、离线或已移动" : "有导入记录，当前副本不可访问；请检查磁盘连接或文件位置")
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 18, height: 18).background(Circle().fill(Color.accentColor))
                        .padding(5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            // 选中：照片外面隔 2 pt 一圈蓝框（不压住照片边缘）；同时是焦点时加粗，不再另画一圈焦点框。
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: focused ? 3 : 2).padding(-4)
                }
            }
            HStack(spacing: 6) {
                Text(item?.baseName ?? "").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                // 几个来源时标出是哪台相机 / 哪张卡。
                Text((model.isMultiSource ? model.sourceLabel(model.source(of: shotID)) + " · " : "") + Self.time(item))
                    .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 1)
        }
        // 焦点框（方向键移动到的位置，且未选中）：连同文件名一起框住，离照片 5 pt，细而浅。
        .overlay {
            if focused, !selected { RoundedRectangle(cornerRadius: 11).strokeBorder(Color.focusRing, lineWidth: 1.5).padding(-6.5) }
        }
        .padding(7)
        .contentShape(Rectangle())
        .overlay { FileDragSource(model: model, shotID: shotID) }
        .onTapGesture {
            let event = NSApp.currentEvent
            if event?.clickCount == 2 { model.openPreview(shotID); return }
            let flags = event?.modifierFlags ?? []
            model.grid.click(shotID, flags.contains(.shift) ? .shift : flags.contains(.command) ? .command : .none)
        }
        .contextMenu {
            Button("大图预览") { model.openPreview(shotID) }
            if shot?.isVideo == true {
                Button("导出实况照片…") { model.openLivePhotoExport(shotID) }
            }
            Divider()
            if let day = model.day(of: shotID) {
                Button("选择当日新照片") { model.selectNew(in: [day.id]) }
                Button("选择当日全部照片") { model.selectAll(in: [day.id]) }
            }
            Button("反选") { model.grid.invert() }
            if model.isMultiSource {
                Divider()
                if let c = model.alignCandidate {
                    Button("按这两张对齐时间（\(model.sourceLabel(c.adjust)) \(CameraProfile.offsetText(c.offset))）") { model.alignClocks() }
                } else {
                    Button("按这两张对齐时间") {}.disabled(true)
                    Text("先选中两台相机在同一时刻拍的各一张照片")
                }
            }
            if let url = model.localFile(of: shotID) {
                Divider()
                Button("在“访达”中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((item?.baseName ?? "") + (imported ? "，已导入" : "") + (selected ? "，已选中" : ""))
        .accessibilityAddTraits(.isButton)
        .help("选中后可拖到桌面或访达文件夹，复制所选原文件")
        .onAppear { model.requestThumbnail(primary) }
        .onDisappear { model.cancelThumbnail(primary) }
    }

    static func time(_ item: CameraContentItem?) -> String {
        guard let raw = item?.captureDateRaw, raw.count >= 13 else { return "" }
        let t = raw.dropFirst(9)
        return "\(t.prefix(2)):\(t.dropFirst(2).prefix(2))"
    }
}

private struct Badge: View {
    let text: String
    var checks = 0
    var checkColor: Color = Theme.accent

    var body: some View {
        HStack(spacing: 2) {
            if checks > 0 {
                HStack(spacing: 0) {
                    ForEach(0..<min(checks, 2), id: \.self) { _ in
                        Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(checkColor)
                    }
                }
            }
            if !text.isEmpty { Text(text) }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.55)))
    }
}

// MARK: - 浮动底栏

struct FloatingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.importJournal.repairTask != nil {
                capsule(maxWidth: 560) {
                    ProgressView().controlSize(.small)
                    twoLines("正在补备份", model.importJournal.repairProgress)
                    secondaryButton("取消") { model.importJournal.repairTask?.cancel() }
                }
            } else if let p = model.progress {
                capsule(maxWidth: 560) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.resumingFrom == nil ? "正在导入" : "正在续传").fontWeight(.semibold)
                            if let from = p.resumingFrom {
                                // 续传：明确告诉用户这个文件不是从头来的。
                                Label("从 \(Self.bytes(from)) 处继续", systemImage: "arrow.clockwise")
                                    .font(Theme.Font.caption).foregroundStyle(.tint).fixedSize()
                            }
                            Spacer(minLength: 8)
                            Text("\(p.done + p.skipped + p.reused + p.failed.count) / \(p.total) 个文件")
                                .font(Theme.Font.caption.monospacedDigit())
                        }
                        ProgressView(value: p.fraction).progressViewStyle(.linear).controlSize(.small)
                        HStack(spacing: 0) {
                            Text(p.current).lineLimit(1).truncationMode(.middle)
                            Text(" · \(Self.bytes(p.bytesDone)) / \(Self.bytes(p.bytesTotal)) · \(Self.timeLeft(p.secondsLeft))")
                                .monospacedDigit().lineLimit(1).layoutPriority(1)
                        }
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .help(p.bytesPerSecond.map { "\(Self.bytes(UInt64($0)))/s" } ?? "")
                        ForEach(model.importBackupProgress) { target in
                            HStack(spacing: 8) {
                                Text(target.target.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(target.verified)/\(target.total)" + (target.failed > 0 ? " · \(target.failed) 项待补" : target.copying ? " · 正在备份" : ""))
                                    .monospacedDigit()
                            }
                            .font(Theme.Font.caption)
                            .foregroundStyle(target.failed > 0 ? Theme.warning : Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
                    secondaryButton("取消") { model.cancelImport() }
                }
            } else if let i = model.interrupted {
                capsule(maxWidth: 560) {
                    statusIcon(warning: true)
                    twoLines("导入已中断，已完成 \(i.done) / \(i.total) 个文件",
                             (model.sourcesOffline ? "相机已断开，" : "") + "未完成的 \(i.total - i.done) 个文件仍处于选中状态"
                             + (i.savedBytes > 0 ? "；已保存 \(Self.bytes(i.savedBytes))，继续时将从断点续传" : ""))
                    secondaryButton("放弃") { model.dismissInterrupted() }
                    mainButton("继续导入", disabled: model.sourcesOffline) { model.continueImport() }
                }
            } else if let r = model.lastResult, r.c1Failed, model.grid.selected.isEmpty {
                capsule(maxWidth: 560) {
                    statusIcon(warning: true)
                    twoLines("未能交由 Capture One 导入", "\(r.files) 个文件已存储至电脑，无需重新下载")
                    secondaryButton("稍后") { model.dismissResult() }
                    mainButton(model.pendingCaptureOneSessions.isEmpty ? "重新导入 C1" : "重试打开 C1",
                               disabled: model.retryingCaptureOne) { model.retryCaptureOne() }
                }
            } else if !model.grid.selected.isEmpty {
                let files = model.selectedFiles()
                capsule {
                    if let r = model.lastResult, r.cancelled, r.savedBytes > 0, !model.sourcesOffline {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("已选 \(model.countText(model.grid.selected)) · \(Self.bytes(model.selectionBytes(of: files)))")
                                .font(Theme.Font.headline).lineLimit(1)
                            Label("已保存未传输完成的 \(Self.bytes(r.savedBytes))，再次导入时将从断点续传", systemImage: "arrow.clockwise")
                                .font(Theme.Font.caption).foregroundStyle(.tint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        twoLines("已选 \(model.countText(model.grid.selected)) · \(Self.bytes(model.selectionBytes(of: files)))", pickedDetail(files))
                    }
                    ImportOptions()
                    mainButton(importLabel, disabled: model.sourcesOffline || model.phase != .ready) { model.beginImport() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else if let r = model.lastResult {
                let (title, detail) = resultLines(r)
                capsule(maxWidth: 560) {
                    statusIcon(warning: r.needsAttention || !model.deliveryFailures.isEmpty)
                    twoLines(title, detail).help(detail)
                    let retryable = model.videoDeliveries(in: model.deliveryID).filter(\.canRetry)
                    if !retryable.isEmpty {
                        Menu("重试发送") {
                            ForEach(retryable) { record in
                                Button(record.software.name) { model.retryVideoDelivery(batchID: model.deliveryID, id: record.id) }
                            }
                        }.disabled(model.videoDeliveryTask != nil)
                    }
                    if model.videoDeliveryTask != nil { ProgressView().controlSize(.small) }
                    if let folder = AppModel.commonFolder(model.lastBatch) {
                        secondaryButton("在访达中显示") { NSWorkspace.shared.open(folder) }
                    }
                    Button { model.dismissResult() } label: { Image(systemName: "xmark").frame(height: 20) }
                    .glassButton().controlSize(.extraLarge)
                    .accessibilityLabel("关闭")
                }
            } else if model.phase == .ready {
                pill { Text("勾选日期或点选照片（⇧ 连选，⌘ 加选）").foregroundStyle(.secondary) }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.grid.selected.isEmpty)
    }

    private var importLabel: String { model.currentSession == nil ? "新建项目" : "导入" }

    private func pickedDetail(_ files: [CameraContentItem]) -> String {
        if model.sourcesOffline { return "相机重新连接后方可导入" }
        let days = Set(files.map(AppModel.dayKey)).count
        var s = "仅导入所选 \(files.count) 个文件 · \(days) 天 · "
        if let cur = model.currentSession {
            s += "归入项目“\(cur.name)”"
        } else {
            s += "请先选择或新建项目"
        }
        if model.backupEnabled {
            s += model.backupAvailable ? " · 备份至 \(model.enabledBackupTargets.count) 个位置" : " · 部分必需备份位置未连接"
        }
        if model.isMultiSource { s += model.splitBySlot && model.canSplitBySlot ? " · 按来源和卡槽分子文件夹" : " · 按来源分子文件夹" }
        if model.proxyOnlyWiFi && model.selectionHasWiFiVideo { s += " · 视频只导代理" }
        if model.willDeleteFromSource { s += " · 完成后删除存储卡上的照片" }
        if let previous = model.lastResult {
            if previous.failed > 0 { s += " · 上次 \(previous.failed) 个文件未完成" }
            if previous.backupFailed > 0 { s += " · 上次 \(previous.backupFailed) 个备份失败" }
        }
        return s
    }

    /// 完成提示的两行：「已导入 12 个文件」和其余说明。
    private func resultLines(_ r: AppModel.ImportResult) -> (String, String) {
        let title = Self.resultTitle(r)
        var rest = resultText(r).dropFirst(title.count)
        while let c = rest.first, "，；、".contains(c) { rest = rest.dropFirst() }
        return (title, String(rest))
    }

    /// 「已导入 12 个文件」；只导了代理时「已导入 3 个片段的代理」。
    static func resultTitle(_ r: AppModel.ImportResult) -> String {
        r.files == 0 && r.proxyOnly > 0 ? "已导入 \(r.proxyOnly) 个片段的代理" : "已导入 \(r.files) 个文件"
    }

    private func resultText(_ r: AppModel.ImportResult) -> String {
        var s = Self.resultTitle(r)
        if r.files > 0 && r.proxyOnly > 0 { s += "、\(r.proxyOnly) 个片段的代理" }
        if r.proxyOnly > 0 { s += "，原片留在存储卡上" }
        if let session = r.session { s += "，已存入 Capture One 会话“\(session)”" }
        if let c = r.lightroom { s += "，收藏夹“\(c)”" + (model.lightroomStatus.map { "：" + $0 } ?? "") }
        if r.resumed > 0 { s += "，其中 \(r.resumed) 个从断点续传" }
        if r.failed > 0 { s += "，\(r.failed) 个失败" }
        if !r.backupTargets.isEmpty {
            s += "，" + r.backupTargets.map { "\($0.target.name)：\($0.verified)/\($0.total) 个文件已校验" }.joined(separator: "；")
        } else if let b = r.backedUp {
            s += "，本次备份并校验 \(b) 个文件"
            if r.backupFailed > 0 { s += "，\(r.backupFailed) 个备份失败" }
        } else {
            s += "，仅存储一份"
        }
        if r.cardReadOnly {
            s += "；存储卡为只读，未删除文件"
        } else if r.deleteFailed > 0 {
            s += "；\(r.deleteFailed) 个文件未能从存储卡上删除"
        } else if r.deleted == 0, r.keptOnCard > 0 {
            s += r.backedUp == nil ? "；因未备份，存储卡上的文件均已保留" : "；存储卡上的文件均已保留"
        } else if let d = r.deleted {
            s += "，已从存储卡删除 \(d) 个" + (r.keptOnCard > 0 ? "（保留 \(r.keptOnCard) 个）" : "")
        }
        if !r.reports.isEmpty { s += "，已写入校验清单" }
        if let o = r.opened { s += o }
        for software in model.deliveryMessages.keys.sorted() where software != "Lightroom Classic" {
            s += "；\(software)：\(model.deliveryMessages[software]!)"
        }
        if r.hasWiFiSource { s += "；Wi-Fi 校验依据为接收内容与本地副本，未取得相机源文件校验值" }
        if r.cancelled { s += r.savedBytes > 0 ? "（已取消；已保存 \(Self.bytes(r.savedBytes))，下次将从断点续传）" : "（已取消）" }
        return s
    }

    private func capsule<C: View>(maxWidth: CGFloat = 760, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.init(top: 6, leading: 20, bottom: 6, trailing: 6))
            .frame(maxWidth: maxWidth)
            .glassCapsule()
    }

    private func statusIcon(warning: Bool) -> some View {
        Image(systemName: warning ? "exclamationmark.triangle" : "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(warning ? Theme.warning : Theme.accent)
            .padding(.trailing, 6)
    }

    private func secondaryButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).glassButton().controlSize(.extraLarge).fixedSize()
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassCapsule()
    }

    private func twoLines(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.Font.headline).lineLimit(1)
            Text(detail).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }

    private func mainButton(_ title: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { action() } label: { Text(title).fontWeight(.semibold) }
        .glassButton(prominent: true)
        .controlSize(.extraLarge)
        .disabled(disabled)
    }

    static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// 「剩余约 2 分 10 秒」；刚开始还算不出速度时显示「正在估算…」。
    static func timeLeft(_ s: Double?) -> String {
        guard let s else { return "正在估算…" }
        let n = Int(s.rounded())
        if n < 5 { return "即将完成" }
        if n < 60 { return "剩余约 \(n) 秒" }
        if n < 3600 {
            let sec = n % 60 / 10 * 10      // 秒数取整到 10，免得一直跳
            return "剩余约 \(n / 60) 分" + (sec > 0 ? " \(sec) 秒" : "")
        }
        return "剩余约 \(n / 3600) 小时 \(n % 3600 / 60) 分"
    }
}

// MARK: - 大图预览

struct PreviewOverlay: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let id = model.previewShot ?? 0
        let shot = model.shots[id]
        let item = shot.flatMap { model.item($0.primary) }
        let selected = model.grid.contains(id)
        let order = model.grid.order
        let index = order.firstIndex(of: id) ?? 0
        let atEnd = index >= order.count - 1
        ZStack(alignment: .bottom) {
            Color.black
            Group {
                if shot?.isVideo == true {
                    if let url = model.previewVideoURL {
                        VideoPreviewSurface(url: url, info: shot.flatMap { model.clipInfos[$0.primary] })
                    } else {
                        VStack(spacing: 14) {
                            if let progress = model.previewVideoProgress {
                                ProgressView(value: progress).frame(width: 240).tint(.white)
                                Text("正在缓存\(model.previewIsProxy ? "代理" : "原片")预览… \(Int(progress * 100))%")
                                Text("关闭预览即可取消，不计入导入记录").font(Theme.Font.caption).foregroundStyle(.white.opacity(0.6))
                            } else if let message = model.previewVideoMessage {
                                Image(systemName: "video").font(.system(size: 36))
                                Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
                                Button("缓存原片预览（\(FloatingBar.bytes(item?.sizeEstimate ?? 0))）") {
                                    model.retryVideoPreview(allowOriginal: true)
                                }
                                .glassButton().disabled(model.progress != nil)
                            } else { ProgressView("正在读取视频信息…").tint(.white) }
                        }
                    }
                } else if let img = model.previewImage {
                    Image(nsImage: img).resizable().scaledToFit()
                        // 大图还没到：先放大缩略图，模糊处理，免得看着像糊了。
                        .blur(radius: model.previewLoaded ? 0 : 10, opaque: true)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(alignment: .topTrailing) {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                    .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor)).padding(8)
                            }
                        }
                        .overlay {
                            if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4) }
                        }
                        .animation(.easeOut(duration: 0.2), value: model.previewLoaded)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .padding(.init(top: 40, leading: 28, bottom: 84, trailing: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bar(shot: shot, item: item, id: id, selected: selected, index: index, count: order.count, atEnd: atEnd)
                .padding(.horizontal, 24).padding(.bottom, 14)
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let direction = press.key == .leftArrow ? -1 : 1
            if shot?.isVideo == true, model.previewVideoURL != nil {
                model.videoPlayback.step(direction, rate: shot.flatMap { model.clipInfos[$0.primary] }.flatMap { ClipInfo.fpsValue($0.formatFps) } ?? 25)
            } else { model.previewStep(direction) }
            return .handled
        }
        .onKeyPress(.upArrow) { model.previewStep(-1); return .handled }
        .onKeyPress(.downArrow) { model.previewStep(1); return .handled }
        .onKeyPress(.space) {
            if shot?.isVideo == true { model.videoPlayback.toggle() } else { model.closePreview() }
            return .handled
        }
        .onKeyPress(.escape) { model.closePreview(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { _ in model.togglePreviewSelection(); return .handled }
        .accessibilityAddTraits(.isModal)
    }

    /// 底部一条：文件名和参数、翻页、选中、关闭。
    private func bar(shot: Shot?, item: CameraContentItem?, id: UInt32, selected: Bool, index: Int, count: Int, atEnd: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item?.baseName ?? "").font(Theme.Font.headline)
                    if let x = model.previewExif {
                        Text(x.exposureText).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    }
                }
                HStack(spacing: 4) {
                    Text(metaText(shot: shot, item: item))
                    if model.isImported(shot: id) {
                        let copies = model.copyCount(shot: id)
                        Text("·")
                        if copies > 0 {
                            HStack(spacing: 0) {
                                ForEach(0..<min(copies, 2), id: \.self) { _ in
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(copies == 1 ? Theme.warning : Theme.accent)
                                }
                            }
                        }
                        Text(copies >= 2 ? "已备份" : copies == 1 ? "已导入" : "不可访问")
                    }
                    if let gear = model.previewExif?.gearText, !gear.isEmpty {
                        Text("· " + gear).truncationMode(.tail)
                    }
                    if let shot, let r = model.rating(of: shot), r != 0 {
                        Text("· " + (r < 0 ? "标为删除" : String(repeating: "★", count: min(r, 5))))
                    }
                    if shot?.isVideo == true, let c = shot.flatMap({ model.clipInfos[$0.primary] }) {
                        if !c.shotMarks.isEmpty {
                            Text("· Shot Mark " + c.shotMarks.map { m in Self.markTime(m.frame, c) }.joined(separator: "、"))
                        }
                        Text("· " + Self.clipText(c)).truncationMode(.tail)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                arrow("chevron.left", "上一张（←）", disabled: index == 0) { model.previewStep(-1) }
                Text("\(index + 1) / \(count)")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.72))
                    .frame(minWidth: 68)
                arrow("chevron.right", "下一张（→）", disabled: atEnd) { model.previewStep(1) }
            }
            .padding(.trailing, 8)

            Button { model.togglePreviewSelection() } label: {
                HStack(spacing: 8) {
                    Text(selected ? "已选中" : "选中").font(Theme.Font.headline)
                    Text("P").font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 18, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.2)))
                }
                .padding(.leading, 16).padding(.trailing, 10).frame(height: 36)
                .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.16)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("按 P 切换")
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button { model.closePreview() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.16)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
            .accessibilityLabel("关闭预览")
        }
        .padding(.init(top: 6, leading: 20, bottom: 6, trailing: 6))
        .frame(maxWidth: 760)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
    }

    private func metaText(shot: Shot?, item: CameraContentItem?) -> String {
        [model.isMultiSource ? model.sourceLabel(model.source(of: model.previewShot ?? 0)) : "",
         shot.map(model.badge(of:)) ?? "", ThumbCell.time(item)].filter { !$0.isEmpty }.joined(separator: " · ")
            + (model.previewLoaded ? "" : " · 正在加载大图…")
    }

    /// 标记在片段里的位置「0:03」。
    static func markTime(_ frame: Int, _ c: ClipInfo) -> String {
        guard let f = ClipInfo.fpsValue(c.formatFps), f > 0 else { return "第 \(frame) 帧" }
        let s = Int(Double(frame) / f)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 「4K 59.94p · H.265 4:2:2 10bit · S-Log3 / S-Gamut3.Cine · TC 06:05:09;21 · FE 50mm F1.4 GM」
    static func clipText(_ c: ClipInfo) -> String {
        let color = [c.gammaText, c.primariesText].filter { !$0.isEmpty }.joined(separator: " / ")
        return [[c.resolutionText, c.fpsText].filter { !$0.isEmpty }.joined(separator: " "),
                c.codecText, color, c.timecode.isEmpty ? "" : "TC " + c.timecode, c.lens]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func arrow(_ icon: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled).opacity(disabled ? 0.35 : 1)
        .help(label)
        .accessibilityLabel(label)
    }
}

extension Color {
    /// 键盘焦点框：浅色模式深蓝、深色模式浅蓝，比选中的蓝框浅一档。
    static let focusRing = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x7c / 255, green: 0xc0 / 255, blue: 1, alpha: 1)
            : NSColor(srgbRed: 0, green: 0x60 / 255, blue: 0xdf / 255, alpha: 1)
    })
}

// MARK: - 液态玻璃（macOS 26 起；更早的系统用毛玻璃）

extension View {
    @ViewBuilder func glassCapsule() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: Capsule())
        } else {
            background(Capsule().fill(.regularMaterial))
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    @ViewBuilder func glassRounded(_ radius: CGFloat) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
        } else {
            background(RoundedRectangle(cornerRadius: radius).fill(.regularMaterial))
        }
    }

}
