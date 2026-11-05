import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
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

    private struct ListHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: model.sourceKind == .card ? "sdcard" : "camera")
                    .font(.system(size: 18)).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.connectedName ?? "").font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 5) {
                        Circle().fill(model.offline ? Color.orange : Color.green).frame(width: 6, height: 6)
                        Text(statusText).lineLimit(1)
                    }
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .help(statusHelp)
                }
                Spacer(minLength: 4)
                Button { withAnimation(.snappy(duration: 0.22)) { expanded.toggle() } } label: {
                    Image(systemName: expanded ? "chevron.up" : "chevron.up.chevron.down")
                        .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.progress != nil)
                .help(expanded ? "收起" : "切换来源")
                .accessibilityLabel(expanded ? "收起来源列表" : "切换来源")
            }
            .padding(.horizontal, 12).padding(.vertical, 10)

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

            if model.slots.count > 1 {
                SlotPicker().padding(.horizontal, 10).padding(.bottom, 10)
            }
            if !model.items.isEmpty {
                Divider().padding(.horizontal, 10)
                FormatSafety().padding(.horizontal, 12).padding(.vertical, 10)
            }
        }
        .glassRounded(14)
        .accessibilityElement(children: .contain)
        .onChange(of: model.progress != nil) { _, busy in if busy { expanded = false } }
    }

    private var statusText: String {
        if model.offline { return "已断开，正在重新连接…" }
        if model.sourceKind == .card { return "读卡器" }
        return "已连接 · " + (model.connectedHost ?? "")
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
        let cards = model.cards.filter { $0.lastPathComponent != model.connectedName || model.sourceKind != .card }
        let cameras = model.knownCameras.filter { $0.fingerprint != model.currentFingerprint }
        VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, 10)
            VStack(spacing: 2) {
                ForEach(cards, id: \.self) { url in
                    row(icon: "sdcard", title: url.lastPathComponent, detail: "读卡器") { model.switchTo(card: url) }
                }
                ForEach(cameras) { k in
                    row(icon: "camera", title: k.name,
                        detail: model.switchingTo == k.fingerprint ? "正在检查…" : (k.name == k.host ? "上次连接的相机" : "上次连接：\(k.host)")) {
                        model.switchTo(known: k)
                    }
                }
                if model.sourceKind == .card {
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
                    Text(title).font(.system(size: 12)).lineLimit(1)
                    if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
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

/// 卡槽：全部 / 卡 1 / 卡 2，下面是张数。
private struct SlotPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            segment("全部", count: model.allShots.count, on: model.slotFilter == nil) { model.slotFilter = nil }
            ForEach(model.slots, id: \.self) { slot in
                segment("卡 \(slot)", count: model.shotCount(slot: slot), on: model.slotFilter == slot) { model.slotFilter = slot }
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func segment(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title).font(.system(size: 12, weight: on ? .semibold : .regular))
                Text(count.formatted()).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.primary.opacity(0.12) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 这张卡能不能格式化：卡上每个文件都在电脑上有两份才行。
private struct FormatSafety: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.cardSafety
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: c.canFormat ? "checkmark.shield.fill" : "exclamationmark.shield")
                .font(.system(size: 15)).foregroundStyle(c.canFormat ? .green : .orange).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.canFormat ? "可格式化存储卡" : "暂不可格式化存储卡").font(.system(size: 12, weight: .semibold))
                Text(c.canFormat ? "全部文件均已存有两份" : "\((c.one + c.none).formatted()) 个文件尚未存有两份")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .help("存储卡上共 \(c.total) 个文件：两份 \(c.two) · 一份 \(c.one) · 未导入 \(c.none)（含未显示的类型，如视频）")
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
            .help(day.newCount > 0 ? "勾选当日 \(day.newCount) 张新照片" : "勾选当日全部照片")
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
                    .foregroundStyle(copies == 1 ? Color.orange : Color.secondary)
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
            .help(scene.newCount > 0 ? "勾选该场次 \(scene.newCount) 张新照片" : "勾选该场次全部照片")
            Text(scene.timeRange.isEmpty ? "第 \(scene.number) 场" : scene.timeRange).font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 4)
            ShotCounts(new: scene.newCount, total: scene.shots.count, copies: 2, size: 11)
        }
        .padding(.leading, 18)
        .contextMenu { SceneGapMenu() }
    }
}

/// 「按时间分场次」：不分 / 隔多久分一场。和「设置 › 导入 › 场次」是同一个选项。
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
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                CardSafetyLine()
            }
            Spacer(minLength: 8)
            SelectAllButton()
            CapsuleSegment(options: [("全部", false), ("未导入", true)], selection: $model.onlyNew)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("显示范围")
            HStack(spacing: 2) {
                TypeToggle(label: "RAW", on: $model.showRaw)
                TypeToggle(label: "JPG/HIF", on: $model.showPhotos)
                TypeToggle(label: "视频", on: $model.showVideo)
            }
            Slider(value: $model.thumbSize, in: 110...320)
                .frame(width: 80)
                .accessibilityLabel("缩略图大小")
                .help("缩略图大小（⌘+ / ⌘−）")
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 52)
    }

    private var title: String {
        var t = model.connectedName ?? "MiniDiT"
        if let s = model.slotFilter, model.slots.count > 1 { t += " · 卡 \(s)" }
        return t
    }
}

/// 标题下面一行：新照片数（能不能格式化在侧栏的来源卡片里）。
private struct CardSafetyLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text(model.newShotCount > 0 ? "\(model.newShotCount.formatted()) 张新照片" : "无新照片")
            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// 工具栏里统一的胶囊控件高度。
private let pillHeight: CGFloat = 26

/// 全选右边显示的照片；都选上了就变成「取消全选」。
private struct SelectAllButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let order = model.grid.order
        let all = !order.isEmpty && order.allSatisfy(model.grid.contains)
        Button { all ? model.grid.clear() : model.grid.selectAll() } label: {
            Text(all ? "取消全选" : "全选")
                .font(.system(size: 13))
                .padding(.horizontal, 12).frame(height: pillHeight)
                .background(Capsule().fill(Color.primary.opacity(0.08)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(order.isEmpty)
        .help(all ? "取消选择（⌘D）" : "选择右侧显示的全部照片（⌘A）")
    }
}

/// 导入栏里的两个开关：备份、导入后删除卡上的照片（和设置里是同一个设置）。
private struct ImportOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 2) {
            TypeToggle(label: "备份", on: $model.backupEnabled)
                .help(model.backupEnabled ? "同时备份至另一磁盘" : "仅存储一份")
            TypeToggle(label: "删除原片", on: $model.deleteAfterImport)
                .disabled(!model.canDeleteFromSource)
                .opacity(model.canDeleteFromSource ? 1 : 0.4)
                .help(model.canDeleteFromSource ? "导入并校验通过后，删除存储卡上的照片（视频文件不予删除）"
                                                : "仅适用于读卡器；经 Wi-Fi 连接相机时不可用")
        }
        .fixedSize()
    }
}

private struct TypeToggle: View {
    let label: String
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            Text(label)
                .font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: pillHeight)
                .foregroundStyle(on ? Color.primary : Color.secondary)
                .background(Capsule().fill(on ? Color.primary.opacity(0.12) : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 胶囊分段控件：灰色底，选中的一项是浮起的亮色胶囊。
private struct CapsuleSegment<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.1) { label, value in
                let on = selection == value
                Button { withAnimation(.snappy(duration: 0.2)) { selection = value } } label: {
                    Text(label)
                        .font(.system(size: 13, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12).frame(height: pillHeight - 4)
                        .background {
                            if on {
                                Capsule().fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                                    .matchedGeometryEffect(id: "on", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
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
            Button("重新连接") { model.reconnectNow() }.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
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
                Text(model.status.isEmpty ? "正在读取照片列表…" : model.status).font(.system(size: 15, weight: .semibold))
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

    private var spacing: CGFloat { 8 }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: model.thumbSize, maximum: model.thumbSize * 1.6), spacing: spacing)] }
    /// 和 LazyVGrid 的自适应列数算法一致，方向键上下移动用。
    private var columnCount: Int { max(1, Int((width - 32 + spacing) / (model.thumbSize + spacing))) }

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
        LazyVGrid(columns: columns, spacing: spacing) {
            ForEach(shots, id: \.self) { id in
                ThumbCell(shotID: id)
                    .id(id)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: CellFrameKey.self, value: [id: g.frame(in: .named("grid"))])
                    })
            }
        }
        .padding(.init(top: 4, leading: 16, bottom: bottom, trailing: 16))
    }

    /// 在空白处或缩略图上拖动 = 框选（按住 ⌘ / ⇧ 在原有选择上增减）。
    private var boxGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("grid"))
            .onChanged { v in
                if box == nil {
                    let flags = NSEvent.modifierFlags
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
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if model.days.isEmpty && model.onlyNew {
                Button("显示全部") { model.onlyNew = false }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).padding(.top, 10)
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
            Text(day.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            if day.partial, day.scenes.count == 1 {
                Text(AppModel.sceneTitle(day.scenes[0])).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            }
            Text("\(day.shots.count) 张" + (day.importedCount > 0 ? " · \(day.importedCount) 张已导入" : ""))
                .font(.system(size: 12))
            Spacer(minLength: 8)
            if day.newCount > 0 {
                Button("选择新照片") { model.selectNew(in: [day.id]) }
            }
            Button(picked ? "取消选择" : "全选") {
                if picked { model.deselect(in: [day.id]) } else { model.selectAll(in: [day.id]) }
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(Color(nsColor: .textBackgroundColor))   // 和标题区、网格同一个底色
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
            Text(AppModel.sceneTitle(scene)).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
            Text("\(scene.shots.count) 张" + (scene.importedCount > 0 ? " · \(scene.importedCount) 张已导入" : ""))
            Spacer(minLength: 8)
            if scene.newCount > 0 {
                Button("选择新照片") { model.grid.set(scene.shots.filter { !model.isImported(shot: $0) }, selected: true) }
            }
            Button(picked ? "取消选择" : "全选") { model.grid.set(scene.shots, selected: !picked) }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 2)
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
            .overlay(alignment: .bottomTrailing) {
                if imported {
                    let copies = model.copyCount(shot: shotID)
                    let text = copies >= 2 ? "两份" : copies == 1 ? "一份" : "已导入"
                    Badge(text: model.thumbSize >= 150 ? text : "", check: true,
                          checkColor: copies == 1 ? .orange : .green).padding(5)
                        .help(copies >= 2 ? "电脑上存有两份，均已校验" : copies == 1 ? "仅存有一份，尚未备份" : "已导入，但电脑上未找到该文件")
                }
            }
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
            .overlay(alignment: .topTrailing) {
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor))
                        .padding(7)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                Text(item?.baseName ?? "").lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
                Text(Self.time(item)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 1)
        }
        .padding(4)
        .overlay {
            // 焦点框（方向键移动到的位置）只在没选中的格子上出现，用灰色细框，免得看着像选中了（选中是蓝框加对勾）。
            if focused && !selected { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.35), lineWidth: 1.5) }
        }
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
    var checkColor: Color = .green

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
                capsule {
                    VStack(alignment: .leading, spacing: 5) {
                        // 第一行：进度（左）和剩余时间（右）。
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.resumingFrom == nil ? "正在导入" : "正在续传").font(.system(size: 14, weight: .semibold))
                            Text("\(p.done + p.skipped + p.reused + p.failed.count) / \(p.total)")
                                .font(.system(size: 14)).foregroundStyle(.secondary).monospacedDigit()
                            if let from = p.resumingFrom {
                                // 续传：明确告诉用户这个文件不是从头来的。
                                Label("从 \(Self.bytes(from)) 处继续传输", systemImage: "arrow.clockwise")
                                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.tint)
                                    .padding(.horizontal, 8).padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                                    .fixedSize()
                            }
                            Spacer(minLength: 12)
                            Text(Self.timeLeft(p.secondsLeft))
                                .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        ProgressView(value: p.fraction).progressViewStyle(.linear)
                        // 第三行：当前文件（左）和数据量、速度（右）。
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.current).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text("\(Self.bytes(p.bytesDone)) / \(Self.bytes(p.bytesTotal))"
                                 + (p.bytesPerSecond.map { " · \(Self.bytes(UInt64($0)))/s" } ?? ""))
                                .monospacedDigit().layoutPriority(1)
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button("取消") { model.cancelImport() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            } else if let i = model.interrupted {
                capsule {
                    twoLines("导入已中断，已完成 \(i.done)/\(i.total) 个文件",
                             (model.offline ? "相机已断开，" : "") + "未完成的 \(i.total - i.done) 个文件仍处于选中状态"
                             + (i.savedBytes > 0 ? "；已保存 \(Self.bytes(i.savedBytes))，继续时将从断点续传" : ""))
                    mainButton("继续导入", disabled: model.offline) { model.continueImport() }
                }
            } else if let r = model.lastResult, r.c1Failed, model.grid.selected.isEmpty {
                capsule {
                    twoLines("未能交由 Capture One 导入", "\(r.files) 个文件已存储至电脑，无需重新下载")
                    mainButton("重新导入 C1") { model.retryCaptureOne() }
                }
            } else if !model.grid.selected.isEmpty {
                capsule {
                    if let r = model.lastResult, r.cancelled, r.savedBytes > 0, !model.offline {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("已选 \(model.selectedShotCount) 张 · \(Self.bytes(model.selectionBytes))")
                                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Label("已保存未传输完成的 \(Self.bytes(r.savedBytes))，再次导入时将从断点续传", systemImage: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(.tint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        twoLines("已选 \(model.selectedShotCount) 张 · \(Self.bytes(model.selectionBytes))", pickedDetail)
                    }
                    ImportOptions()
                    mainButton(importLabel, disabled: model.offline) { model.beginImport() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else if let r = model.lastResult {
                pill {
                    Image(systemName: r.needsAttention ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(r.needsAttention ? .orange : .green)
                    Text(resultText(r)).fontWeight(.semibold)
                }
                .onTapGesture { model.dismissResult() }
            } else if model.phase == .ready {
                pill { Text("勾选日期或点选照片（⇧ 连选，⌘ 加选）") }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.grid.selected.isEmpty)
    }

    private var importLabel: String {
        switch model.captureOneMode {
        case .newSession: "导入到新会话…"
        case .lightroom: "导入到 Lightroom…"
        case .off: "下载"
        default: "导入到 Capture One"
        }
    }

    private var pickedDetail: String {
        if model.offline { return "相机重新连接后方可导入" }
        let files = model.selectedFiles()
        let days = Set(files.map(AppModel.dayKey)).count
        let dest = model.captureOneMode == .newSession ? model.sessionsFolder : model.destination
        var s = "\(files.count) 个文件 · \(days) 天 · 存储至 \(Self.short(dest))"
        if model.backupEnabled {
            s += model.backupAvailable ? " · 备份至 \(Self.short(model.backupFolder!))" : " · ⚠︎ 备份磁盘未连接"
        }
        if model.willDeleteFromSource { s += " · 完成后删除存储卡上的照片" }
        return s
    }

    private func resultText(_ r: AppModel.ImportResult) -> String {
        var s = "已导入 \(r.files) 个文件"
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

    private func capsule<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 16) { content() }
            .padding(.init(top: 8, leading: 24, bottom: 8, trailing: 8))
            .frame(maxWidth: 760)
            .glassCapsule()
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassCapsule()
    }

    private func twoLines(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func mainButton(_ title: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 15, weight: .semibold)).padding(.horizontal, 8).frame(height: 28)
        }
        .glassProminentButton()
        .controlSize(.large)
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

    /// 路径太长时只留首尾：/Volumes/…/Pic
    static func short(_ url: URL) -> String {
        let parts = url.path(percentEncoded: false).split(separator: "/").map(String.init)
        guard parts.count > 2 else { return url.path(percentEncoded: false) }
        return "/" + parts[0] + "/…/" + parts[parts.count - 1]
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
        let index = model.grid.order.firstIndex(of: id) ?? 0
        ZStack {
            Color.black
            Group {
                if let img = model.previewImage {
                    Image(nsImage: img).resizable().scaledToFit()
                        .overlay { if selected { Rectangle().strokeBorder(Color.accentColor, lineWidth: 3) } }
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    ProgressView().tint(.white)
                }
            }
            .padding(.init(top: 40, leading: 80, bottom: 84, trailing: 80))

            HStack {
                roundButton("chevron.left", "上一张") { model.previewStep(-1) }.disabled(index == 0).opacity(index == 0 ? 0.3 : 1)
                Spacer()
                let atEnd = index >= model.grid.order.count - 1
                roundButton("chevron.right", "下一张") { model.previewStep(1) }.disabled(atEnd).opacity(atEnd ? 0.3 : 1)
            }
            .padding(.horizontal, 18)

            VStack {
                HStack { Spacer(); roundButton("xmark", "关闭预览", size: 32) { model.closePreview() } }
                    .padding(.init(top: 10, leading: 0, bottom: 0, trailing: 16))
                Spacer()
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(item?.baseName ?? "").font(.system(size: 15, weight: .semibold))
                        HStack(spacing: 6) {
                            Text([shot.map(model.badge(of:)) ?? "", ThumbCell.time(item)].filter { !$0.isEmpty }.joined(separator: " · ")
                                 + (model.previewLoaded ? "" : " · 正在加载大图…"))
                            if model.isImported(shot: id) {
                                let copies = model.copyCount(shot: id)
                                Label(copies >= 2 ? "两份" : copies == 1 ? "仅一份" : "已导入", systemImage: "checkmark")
                            }
                        }
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
                        if let x = model.previewExif {
                            Text(x.exposureText).font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.9)).padding(.top, 4)
                            if !x.gearText.isEmpty {
                                Text(x.gearText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text("← → 翻页 · P 选中 · Esc 关闭").font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
                    HStack {
                        Spacer()
                        Button { model.togglePreviewSelection() } label: {
                            HStack(spacing: 6) {
                                if selected { Image(systemName: "checkmark") }
                                Text(selected ? "已选中" : "选中")
                            }
                            .font(.system(size: 17, weight: .semibold))
                            .padding(.horizontal, 22).frame(height: 44)
                            .foregroundStyle(.white)
                            .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.14)))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.init(top: 0, leading: 80, bottom: 16, trailing: 80))
            }
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.previewStep(-1); return .handled }
        .onKeyPress(.rightArrow) { model.previewStep(1); return .handled }
        .onKeyPress(.space) { model.closePreview(); return .handled }
        .onKeyPress(.escape) { model.closePreview(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { _ in model.togglePreviewSelection(); return .handled }
        .accessibilityAddTraits(.isModal)
    }

    private func roundButton(_ icon: String, _ label: String, size: CGFloat = 44, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.38, weight: .semibold))
                .frame(width: size, height: size)
                .contentShape(Circle())
                .glassCircle()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
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

    @ViewBuilder func glassCircle() -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular.interactive(), in: Circle())
        } else {
            background(Circle().fill(Color.white.opacity(0.14)))
        }
    }

    @ViewBuilder func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }
}
