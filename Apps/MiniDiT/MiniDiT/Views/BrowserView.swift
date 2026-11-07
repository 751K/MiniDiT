import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 320)
                .background(SidebarWidthFix(min: 220, ideal: 264, max: 320))
                .toolbar(removing: .sidebarToggle)
        } detail: {
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
        .overlay {
            if model.previewShot != nil { PreviewOverlay() }
        }
    }
}

/// 主窗口改成单个 Window 场景后，系统不再遵守上面的列宽，侧栏每次打开都被挤到 144 pt。
/// 直接找到底下的 NSSplitViewController，把侧栏的最小 / 最大宽度设上，太窄时拉到合适宽度。
private struct SidebarWidthFix: NSViewRepresentable {
    let min: CGFloat, ideal: CGFloat, max: CGFloat

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
            guard let split = v as? NSSplitView, let first = split.arrangedSubviews.first else { return }
            if let ctrl = split.delegate as? NSSplitViewController, let item = ctrl.splitViewItems.first {
                item.minimumThickness = fix.min
                item.maximumThickness = fix.max
            }
            if first.frame.width < fix.min { split.setPosition(fix.ideal, ofDividerAt: 0) }
        }
    }
}

// MARK: - 侧栏

struct Sidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        List(selection: $model.shownDays) {
            Section("日期") {
                ForEach(model.days) { day in
                    DayRow(day: day).tag(day.id)
                    if day.scenes.count > 1 {
                        ForEach(day.scenes) { scene in
                            SceneRow(scene: scene, day: day).tag(scene.id)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 6) {
            SourceCard().padding(.horizontal, 10).padding(.top, 4)
        }
        .safeAreaInset(edge: .bottom) {
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

/// 侧栏顶上的来源卡片：当前相机 / 存储卡、卡槽切换、这张卡能不能格式化。换来源在右边的菜单里。
private struct SourceCard: View {
    @Environment(AppModel.self) private var model
    /// 展开换来源的列表。
    @State private var expanded = false
    @State private var listHeight: CGFloat = 0
    @State private var newName = ""
    @State private var newHost = ""

    private struct ListHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isMultiSource { multiHeader } else { singleHeader }

            // 像手风琴一样展开：高度从 0 变到列表的高度，多出来的部分裁掉，不会压到下面的卡槽。
            SourceList { withAnimation(.snappy(duration: 0.22)) { expanded = false } }
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { g in Color.clear.preference(key: ListHeight.self, value: g.size.height) })
                .frame(height: expanded ? listHeight : 0, alignment: .top)
                .clipped()
                .opacity(expanded ? 1 : 0)
                .allowsHitTesting(expanded)
                .accessibilityHidden(!expanded)
                .onPreferenceChange(ListHeight.self) { listHeight = $0 }

            if model.isMultiSource {
                ForEach(model.sources) { src in
                    VStack(spacing: 0) {
                        SourceRow(source: src)
                        // 每台 Wi-Fi 相机自己选看哪张卡：A 看卡 1、B 看卡 2，各管各的。
                        if model.sourceSlots(src.id).count > 1 {
                            SourceSlotPicker(id: src.id).padding(.leading, 36).padding(.trailing, 6).padding(.bottom, 6)
                        }
                    }
                    .contextMenu { SourceMenu(id: src.id, rename: startRename) }
                }
                .padding(.horizontal, 6)
                SourcePicker().padding(.horizontal, 10).padding(.vertical, 10)
            } else {
                if model.onlySlot(AppModel.primarySource) != nil {
                    // 这台相机记住了只看某张卡（多来源时选的）：用同一条切换条，点「全部」就改回来。
                    SourceSlotPicker(id: AppModel.primarySource).padding(.horizontal, 10).padding(.bottom, 10)
                } else if model.slots.count > 1 {
                    SlotPicker().padding(.horizontal, 10).padding(.bottom, 10)
                }
                if !model.items.isEmpty {
                    Divider().padding(.horizontal, 10)
                    FormatSafety().padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        // 侧栏是系统的灰色底：分组用浅色半透明底跟着侧栏走，不用白底（白块在侧栏里很突兀）。
        .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.sidebarGroup))
        .accessibilityElement(children: .contain)
        .onChange(of: model.progress != nil) { _, busy in if busy { expanded = false } }
        .onChange(of: model.renamingSource) { _, id in if let id { newName = model.profile(id)?.nickname ?? "" } }
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
            Text("例如“主机”“副机”。同时导入多个来源时，也用作子文件夹名。留空即恢复机型名。")
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

    private var toggle: some View {
        Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
            Image(systemName: expanded ? "chevron.up" : "chevron.up.chevron.down")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 28).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.progress != nil)
        .help(expanded ? "收起" : "添加或切换来源")
        .accessibilityLabel(expanded ? "收起来源列表" : "添加或切换来源")
    }

    /// 同时打开了几个来源：标题只写数量，每个来源一行列在下面。
    private var multiHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.stack").font(.system(size: 17)).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.sources.count) 个来源").font(Theme.Font.headline)
                if model.clocksUnaligned {
                    Label("相机时间尚未对齐", systemImage: "clock.badge.exclamationmark")
                        .font(Theme.Font.caption).foregroundStyle(Theme.warning)
                        .help("各相机的时钟可能不一致，合并后的顺序会错位。选中两台相机在同一时刻拍的各一张照片，右键选“按这两张对齐时间”。")
                } else {
                    Text("按拍摄时间合并显示").font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            refreshButton
            toggle
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var singleHeader: some View {
            HStack(spacing: 10) {
                Image(systemName: model.sourceKind == .card ? "sdcard" : "camera")
                    .font(.system(size: 18)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.sourceName(AppModel.primarySource)).font(Theme.Font.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        // 正常不上色；断开时才有橙色警告。
                        if model.offline { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
                        Text(statusText).lineLimit(1)
                    }
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                    .help(statusHelp)
                }
                Spacer(minLength: 4)
                refreshButton
                toggle
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .contentShape(Rectangle())
            .contextMenu { SourceMenu(id: AppModel.primarySource, rename: startRename) }
    }

    private var statusText: String {
        if model.offline { return "已断开，正在重新连接…" }
        if model.sourceKind == .card { return "读卡器 · " + (model.cardRoot?.lastPathComponent ?? "") }
        let only = model.onlySlot(AppModel.primarySource).map { " · 仅卡 \($0)" } ?? ""
        return "已连接 · " + (model.connectedHost ?? "") + only
    }

    private var statusHelp: String {
        var parts: [String] = []
        if let v = model.deviceInfo?.version, !v.isEmpty { parts.append("固件 \(v)") }
        if model.sourceKind != .card && !model.usesRemoteTransfer { parts.append("内容传输模式") }
        return parts.joined(separator: " · ")
    }
}

/// 卡片里展开的换来源列表：插着的卡、连过的相机；推出存储卡；回到选择来源的界面。
private struct SourceList: View {
    @Environment(AppModel.self) private var model
    let done: () -> Void

    var body: some View {
        let openCards = Set(([model.cardRoot] + model.extraSources.map(\.root)).compactMap { $0?.standardizedFileURL })
        let cards = model.cards.filter { !openCards.contains($0.standardizedFileURL) }
        let cameras = model.knownCameras.filter { !model.openFingerprints.contains($0.fingerprint) && !model.openHosts.contains($0.host) }
        let open = model.library != nil || model.offline
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 10)
            VStack(spacing: 2) {
                // 再插一张卡：和当前的来源同时打开（多机位一起导）。
                ForEach(cards, id: \.self) { url in
                    row(icon: "plus.circle", title: url.lastPathComponent, detail: "同时打开此存储卡") { model.addCard(url) }
                }
                // 连过的相机：和当前来源同时连接（多机位）。
                ForEach(cameras) { k in
                    row(icon: open ? "plus.circle" : "camera", title: k.displayName,
                        detail: model.switchingTo == k.fingerprint ? "正在检查…" : (open ? "同时连接此相机 · \(k.host)" : (k.name == k.host ? "上次连接的相机" : "上次连接：\(k.host)"))) {
                        if open { model.addCamera(known: k) } else { model.switchTo(known: k) }
                    }
                }
                if open {
                    row(icon: "network", title: "输入地址同时连接相机…", detail: nil) { model.askingHost = true }
                }
                if model.sourceKind == .card, !model.isMultiSource {
                    row(icon: "eject", title: "推出存储卡", detail: nil) { model.ejectCard() }
                }
                row(icon: "magnifyingglass", title: "搜索相机或选择存储卡…", detail: nil) { model.disconnect() }
            }
            .padding(6)
            Divider().padding(.horizontal, 10).padding(.bottom, 10)
        }
    }

    private func row(icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        SourceListRow(icon: icon, title: title, detail: detail) { done(); action() }
    }
}

private struct SourceListRow: View {
    let icon: String
    let title: String
    let detail: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).lineLimit(1)
                    if let detail { Text(detail).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hover ? Color.primary.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// 同时打开几个来源时，卡片里的一行：名字、读卡器 / Wi-Fi、能不能格式化；右边推出或关闭。
private struct SourceRow: View {
    @Environment(AppModel.self) private var model
    let source: SourceSummary

    /// 卡槽限制、时钟校正。
    private var extra: String {
        var s = ""
        // 有卡槽切换条时，看的是哪张卡在条上一目了然，这里不再重复。
        if let only = model.onlySlot(source.id), model.sourceSlots(source.id).count < 2 { s += " · 仅卡 \(only)" }
        if let t = model.profile(source.id)?.clockOffset, t != 0 { s += " · 时间 " + CameraProfile.offsetText(t) }
        return s
    }

    var body: some View {
        let c = model.cardSafety(source: source.id)
        HStack(spacing: 8) {
            Image(systemName: source.isCard ? "sdcard" : "camera").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.name).font(Theme.Font.headline).lineLimit(1)
                HStack(spacing: 4) {
                    if (source.id == AppModel.primarySource && model.offline) || source.offline {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        Text("已断开，正在重新连接…")
                    } else if source.connecting {
                        ProgressView().controlSize(.mini)
                        Text("正在连接…")
                    } else {
                        Image(systemName: c.canFormat ? "checkmark.shield.fill" : "shield")
                            .foregroundStyle(c.canFormat ? Theme.accent : Color.secondary)
                        Text(source.detail + extra)
                    }
                }
                .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                .help(source.detail + extra + "\n" + (c.canFormat ? "可格式化：全部文件均已存有两份" : "已存两份：\(c.two.formatted()) / \(c.total.formatted())，全部存有两份后可格式化"))
            }
            Spacer(minLength: 0)
            Button {
                if source.isCard, source.id != AppModel.primarySource { model.ejectExtra(source.id) }
                else if source.isCard { model.ejectCard() }
                else { model.removeSource(source.id) }
            } label: {
                Image(systemName: source.isCard ? "eject" : "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.progress != nil)
            .help(source.isCard ? "推出 \(source.detail.replacingOccurrences(of: "读卡器 · ", with: ""))" : "断开此相机")
            .accessibilityLabel(source.isCard ? "推出存储卡" : "断开相机")
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
    }
}

/// 来源的右键菜单：改名、只导某个卡槽（Wi-Fi 相机）、清除时间校正。改的是这台机身的档案。
struct SourceMenu: View {
    @Environment(AppModel.self) private var model
    let id: Int
    let rename: (Int) -> Void

    var body: some View {
        if model.profileKey(id) == nil {
            Text("未能识别机身，无法保存设置")
        } else {
            Button("重命名…") { rename(id) }
            // 几个来源时卡槽在来源行的切换条上选。
            if id == AppModel.primarySource, model.sourceKind == .camera, !model.isMultiSource {
                Picker("导入卡槽", selection: Binding(get: { model.onlySlot(id) ?? 0 },
                                                   set: { model.setOnlySlot(id, $0 == 0 ? nil : $0) })) {
                    Text("全部卡槽").tag(UInt32(0))
                    Text("仅卡 1").tag(UInt32(1))
                    Text("仅卡 2").tag(UInt32(2))
                }
            }
            if let t = model.profile(id)?.clockOffset {
                Button("清除时间校正（\(CameraProfile.offsetText(t))）") { model.clearClockOffset(id) }
            }
        }
    }
}

/// 几个来源时的筛选：全部 / 每个来源，后面是张数。不超过三项用系统分段控件，再多用弹出菜单。
private struct SourcePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let options: [SegmentPicker<Int?>.Option] = [.init(title: "全部", count: "\(model.sources.reduce(0) { $0 + model.shotCount(source: $1.id) })", value: nil)]
            + model.sources.map { .init(title: model.sourceLabel($0.id), count: "\(model.shotCount(source: $0.id))", value: $0.id) }
        ChoicePicker(title: "来源", options: options,
                     selection: Binding(get: { model.sourceFilter }, set: { model.sourceFilter = $0 }))
    }
}

/// 几个来源时，一台 Wi-Fi 相机只看 / 只导哪张卡：全部 / 卡 1 / 卡 2。按机身记住（同「导入卡槽」）。
private struct SourceSlotPicker: View {
    @Environment(AppModel.self) private var model
    let id: Int

    var body: some View {
        let options: [SegmentPicker<UInt32?>.Option] = [.init(title: "全部", count: "\(model.shotCount(source: id, slot: nil))", value: nil)]
            + model.sourceSlots(id).map { .init(title: "卡 \($0)", count: "\(model.shotCount(source: id, slot: $0))", value: $0) }
        ChoicePicker(title: "卡槽", options: options,
                     selection: Binding(get: { model.onlySlot(id) }, set: { model.setOnlySlot(id, $0) }))
            .disabled(model.progress != nil)
            .help("只显示并导入这台相机的某张存储卡；按机身记住")
    }
}

/// 卡槽：全部 / 卡 1 / 卡 2，后面是张数。
private struct SlotPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let options: [SegmentPicker<UInt32?>.Option] = [.init(title: "全部", count: "\(model.allShots.count)", value: nil)]
            + model.slots.map { .init(title: "卡 \($0)", count: "\(model.shotCount(slot: $0))", value: $0) }
        ChoicePicker(title: "卡槽", options: options,
                     selection: Binding(get: { model.slotFilter }, set: { model.slotFilter = $0 }))
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

/// 这张卡能不能格式化：卡上每个文件都在电脑上有两份才行。
/// 还没齐时是平常状态，不用橙色警告，只显示进度：已存两份的文件数和一条进度条；齐了才说「可以格式化」。
private struct FormatSafety: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.cardSafety
        HStack(alignment: c.canFormat ? .top : .center, spacing: 10) {
            Image(systemName: c.canFormat ? "checkmark.shield.fill" : "shield")
                .font(.system(size: 15)).foregroundStyle(c.canFormat ? Theme.accent : Color.secondary).frame(width: 24)
            if c.canFormat {
                VStack(alignment: .leading, spacing: 2) {
                    Text("可以格式化存储卡").font(Theme.Font.headline)
                    Text("全部文件均已存有两份").font(Theme.Font.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("已存两份").font(Theme.Font.headline)
                        Spacer(minLength: 4)
                        Text("\(c.two.formatted()) / \(c.total.formatted())")
                            .font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(c.two), total: Double(max(c.total, 1)))
                        .progressViewStyle(.linear).controlSize(.small).tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .help(c.canFormat
              ? "存储卡上全部 \(c.total) 个文件均已存有两份（本机与备份盘），可以放心格式化。"
              : "全部文件都存有两份（本机与备份盘）后，才能放心格式化存储卡。\n共 \(c.total) 个文件：两份 \(c.two) · 一份 \(c.one) · 未导入 \(c.none)（含未显示的类型，如视频）")
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
            .help(day.newCount > 0 ? "勾选当日 \(model.countText(day.shots.filter { !model.isImported(shot: $0) }, fresh: true))" : "勾选当日全部内容")
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
            if new > 0 {
                Text("\(new) 新").font(.system(size: size, weight: .semibold).monospacedDigit())
            } else {
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
            .help(scene.newCount > 0 ? "勾选该场次 \(model.countText(scene.shots.filter { !model.isImported(shot: $0) }, fresh: true))" : "勾选该场次全部内容")
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
            // 单选、多选都用玻璃分段（灰色底槽 + 玻璃滑块），不用系统分段控件的整块蓝色。
            SegmentPicker(options: [.init(title: "全部", value: false), .init(title: "未导入", value: true)], selection: $model.onlyNew)
                .accessibilityLabel("显示范围")
            MultiSegmentPicker(options: [.init(title: "RAW", isOn: $model.showRaw),
                                        .init(title: "JPG/HIF", isOn: $model.showPhotos),
                                        .init(title: "视频", isOn: $model.showVideo)])
                .accessibilityLabel("文件类型")
            Slider(value: $model.thumbSize, in: 110...320)
                .frame(width: 76)
                .accessibilityLabel("缩略图大小")
                .help("缩略图大小（⌘+ / ⌘−）")
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(minHeight: 52)
    }
}

private struct ImportOptions: View {
    @Environment(AppModel.self) private var model

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

            Menu {
                Button("更改存放位置…") { chooseFolder() }
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
    private func chooseFolder() {
        if model.captureOneMode == .newSession {
            if let url = FolderPicker.choose(start: model.sessionsFolder) { model.sessionsFolder = url }
        } else {
            if let url = FolderPicker.choose(start: model.destination) { model.destination = url }
        }
    }
}

/// 底栏上的当前会话（新建 C1 会话模式）：显示导入到哪个会话；菜单里新建会话或换成已有的会话。
private struct SessionMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.currentSession
        Menu {
            Button("新建会话…") { model.newSessionPrompt = .init(importAfter: false) }
            let existing = Array(model.existingSessions.prefix(10))
            let names = existing.map { $0.deletingPathExtension().lastPathComponent }
            if let current, !names.contains(current.name) {
                Divider()
                // 刚新建、还没导入过的会话：磁盘上还没有。
                Toggle(current.name, isOn: .constant(true))
            }
            if !existing.isEmpty {
                Divider()
                Section("已有会话") {
                    ForEach(existing, id: \.self) { f in
                        let n = f.deletingPathExtension().lastPathComponent
                        Toggle(n, isOn: Binding(get: { current?.name == n }, set: { _ in model.useSession(f) }))
                    }
                }
            }
        } label: {
            Label(current?.name ?? "未选择会话", systemImage: "folder")
                .lineLimit(1).frame(maxWidth: 200).frame(height: 20)
        }
        .menuStyle(.button).glassButton().controlSize(.extraLarge)
        .fixedSize()
        .help(current.map { "当前会话：\($0.name)。点按以新建或更换会话" } ?? "尚未选择会话。点按以新建或选择已有会话")
        .accessibilityLabel("会话")
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
            Text(GroupMeta.text(model, shots: day.shots))
            Spacer(minLength: 8)
            Button(picked ? "取消选择" : day.newCount > 0 ? "选择新照片" : "全选") {
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
            Text(GroupMeta.text(model, shots: scene.shots))
            Spacer(minLength: 8)
            Button(picked ? "取消选择" : scene.newCount > 0 ? "选择新照片" : "全选") {
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
    @MainActor static func text(_ model: AppModel, shots: [UInt32]) -> String {
        let fresh = shots.filter { !model.isImported(shot: $0) }
        let videos = shots.filter { model.shots[$0]?.isVideo == true }.count
        let all = fresh.count == shots.count
            ? (videos == 0 ? "均为新照片" : videos == shots.count ? "均为新片段" : "均未导入")
            : model.countText(fresh, fresh: true)
        return model.countText(shots) + " · " + (fresh.isEmpty ? "均已导入" : all)
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
                            .saturation(imported ? 0.55 : 1)
                            .brightness(imported ? -0.2 : 0)
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
                    Badge(text: model.thumbSize >= 150 ? "仅代理" : "", check: true, checkColor: .blue).padding(5)
                        .help("已导入代理，原片尚未导入")
                }
                if imported {
                    let copies = model.copyCount(shot: shotID)
                    let text = copies >= 2 ? "两份" : copies == 1 ? "一份" : "已导入"
                    Badge(text: model.thumbSize >= 150 ? text : "", check: true,
                          checkColor: copies == 1 ? Theme.warning : Theme.accent).padding(5)
                        .help(copies >= 2 ? "电脑上存有两份，均已校验" : copies == 1 ? "仅存有一份，尚未备份" : "已导入，但电脑上未找到该文件")
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
        .onTapGesture {
            let event = NSApp.currentEvent
            if event?.clickCount == 2 { model.openPreview(shotID); return }
            let flags = event?.modifierFlags ?? []
            model.grid.click(shotID, flags.contains(.shift) ? .shift : flags.contains(.command) ? .command : .none)
        }
        .contextMenu {
            Button("大图预览") { model.openPreview(shotID) }
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
    var check = false
    var checkColor: Color = Theme.accent

    var body: some View {
        HStack(spacing: 2) {
            if check { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(checkColor) }
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
            if let p = model.progress {
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
                    mainButton("重新导入 C1") { model.retryCaptureOne() }
                }
            } else if !model.grid.selected.isEmpty {
                capsule {
                    if let r = model.lastResult, r.cancelled, r.savedBytes > 0, !model.sourcesOffline {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("已选 \(model.countText(model.grid.selected)) · \(Self.bytes(model.selectionBytes))")
                                .font(Theme.Font.headline).lineLimit(1)
                            Label("已保存未传输完成的 \(Self.bytes(r.savedBytes))，再次导入时将从断点续传", systemImage: "arrow.clockwise")
                                .font(Theme.Font.caption).foregroundStyle(.tint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        twoLines("已选 \(model.countText(model.grid.selected)) · \(Self.bytes(model.selectionBytes))", pickedDetail)
                    }
                    ImportOptions()
                    if model.captureOneMode == .newSession { SessionMenu() }
                    mainButton(importLabel, disabled: model.sourcesOffline) { model.beginImport() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else if let r = model.lastResult {
                let (title, detail) = resultLines(r)
                capsule(maxWidth: 560) {
                    statusIcon(warning: r.needsAttention)
                    twoLines(title, detail).help(detail)
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

    private var importLabel: String {
        switch model.captureOneMode {
        case .newSession: model.currentSession == nil ? "导入…" : "导入"
        case .lightroom: "导入到 Lightroom…"
        case .off: "下载"
        default: "导入到 Capture One"
        }
    }

    private var pickedDetail: String {
        if model.sourcesOffline { return "相机重新连接后方可导入" }
        let files = model.selectedFiles()
        let days = Set(files.map(AppModel.dayKey)).count
        let dest = model.captureOneMode == .newSession ? model.sessionsFolder : model.destination
        let videos = files.contains { $0.kind == .video }, photos = files.contains { $0.kind != .video }
        var s = "\(files.count) 个文件 · \(days) 天 · "
        if photos {
            if model.captureOneMode == .newSession {
                s += model.currentSession.map { "存入会话“\($0.name)”" } ?? "导入前新建会话"
            } else {
                s += "存储至“\(dest.lastPathComponent)”"
            }
        }
        if videos { s += (photos ? "，视频存储至“" : "视频存储至“") + model.videoDestination.lastPathComponent + "”" }
        if model.backupEnabled {
            s += model.backupAvailable ? " · 备份至“\(model.backupFolder!.lastPathComponent)”" : " · ⚠︎ 备份磁盘未连接"
        }
        if model.isMultiSource { s += model.splitBySlot && model.canSplitBySlot ? " · 按来源和卡槽分子文件夹" : " · 按来源分子文件夹" }
        if model.proxyOnlyWiFi && model.selectionHasWiFiVideo { s += " · 视频只导代理" }
        if model.willDeleteFromSource { s += " · 完成后删除存储卡上的照片" }
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
        if let session = r.session { s += "，已存入会话“\(session)”" }
        if let c = r.lightroom { s += "，收藏夹“\(c)”" + (model.lightroomStatus.map { "：" + $0 } ?? "") }
        if r.resumed > 0 { s += "，其中 \(r.resumed) 个从断点续传" }
        if r.failed > 0 { s += "，\(r.failed) 个失败" }
        if let b = r.backedUp {
            s += r.backupFailed > 0 ? "，\(r.backupFailed) 个备份失败" : (b > 0 ? "，两份均已校验" : "")
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
                if let img = model.previewImage {
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
        .onKeyPress(keys: [.leftArrow, .upArrow]) { _ in model.previewStep(-1); return .handled }
        .onKeyPress(keys: [.rightArrow, .downArrow]) { _ in model.previewStep(1); return .handled }
        .onKeyPress(.space) { model.closePreview(); return .handled }
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
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(copies == 1 ? Theme.warning : Theme.accent)
                        Text(copies >= 2 ? "存有两份" : copies == 1 ? "仅一份" : "已导入")
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
