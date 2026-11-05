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
            Section {
                SourceRow(icon: model.sourceKind == .card ? "sdcard" : "camera",
                          name: model.connectedName ?? "",
                          detail: sourceDetail,
                          current: true,
                          connected: !model.offline,
                          eject: model.sourceKind == .card ? { model.ejectCard() } : nil,
                          pick: { model.slotFilter = nil })
                    .listRowBackground(rowHighlight(model.slotFilter == nil))
                if model.slots.count > 1 {
                    ForEach(model.slots, id: \.self) { slot in
                        Button { model.slotFilter = slot } label: {
                            HStack {
                                Text("卡 \(slot)").fontWeight(model.slotFilter == slot ? .semibold : .regular)
                                Spacer()
                                Text("\(model.shotCount(slot: slot))").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.leading, 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(rowHighlight(model.slotFilter == slot))
                        .accessibilityAddTraits(model.slotFilter == slot ? .isSelected : [])
                    }
                }
                // 其他来源：插着的卡、连过的相机，点一下切换过去。
                ForEach(model.cards.filter { $0.lastPathComponent != model.connectedName || model.sourceKind != .card }, id: \.self) { url in
                    SourceRow(icon: "sdcard", name: url.lastPathComponent, detail: "读卡器 · 点一下切换", current: false, eject: nil) {
                        model.switchTo(card: url)
                    }
                    .disabled(model.progress != nil)
                }
                ForEach(model.knownCameras.filter { $0.fingerprint != model.currentFingerprint }) { k in
                    SourceRow(icon: "camera", name: k.name,
                              detail: model.switchingTo == k.fingerprint ? "正在检查…" : "上次 \(k.host) · 点一下切换",
                              current: false, eject: nil) {
                        model.switchTo(known: k)
                    }
                    .opacity(0.75)
                    .disabled(model.progress != nil)
                }
            } header: {
                HStack {
                    Text("来源")
                    Spacer()
                    Button { model.disconnect() } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .help("切换来源…（搜索相机、选存储卡）")
                        .accessibilityLabel("切换来源")
                        .disabled(model.progress != nil)
                }
            }

            Section("日期") {
                ForEach(model.days) { day in
                    DayRow(day: day).tag(day.id)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { openSettings() } label: {
                Label("设置…", systemImage: "gearshape").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    /// 和日期列表的选中效果一致的圆角底色。
    @ViewBuilder private func rowHighlight(_ on: Bool) -> some View {
        if on {
            RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)).padding(.horizontal, 10)
        } else {
            Color.clear
        }
    }

    private var sourceDetail: String {
        if model.offline { return "已断开，正在重新连接…" }
        if model.sourceKind == .card { return "读卡器" }
        var parts = [model.connectedHost ?? ""]
        if let v = model.deviceInfo?.version, !v.isEmpty { parts.append("固件 \(v)") }
        if !model.usesRemoteTransfer { parts.append("内容传输模式") }
        return parts.joined(separator: " · ")
    }
}

private struct SourceRow: View {
    let icon: String
    let name: String
    let detail: String
    let current: Bool
    var connected = false
    let eject: (() -> Void)?
    let pick: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: pick) {
                HStack(spacing: 8) {
                    Image(systemName: icon).frame(width: 18)
                        .foregroundStyle(current ? Color.accentColor : Color.secondary)
                        .overlay(alignment: .bottomTrailing) {
                            if current {
                                Circle().fill(connected ? Color.green : Color.orange)
                                    .frame(width: 7, height: 7)
                                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                                    .offset(x: 3, y: 2)
                                    .help(connected ? "已连接" : "已断开，正在重新连接")
                            }
                        }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(name).fontWeight(current ? .semibold : .regular).lineLimit(1)
                        Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let eject {
                Button(action: eject) { Image(systemName: "eject") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("推出存储卡").accessibilityLabel("推出存储卡")
            }
        }
        .padding(.vertical, 2)
        .accessibilityValue(current ? (connected ? "当前来源，已连接" : "当前来源，已断开") : "")
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
            .help(day.newCount > 0 ? "勾选这一天没导入过的 \(day.newCount) 张" : "勾选这一天全部")
            Text(day.title).lineLimit(1)
            Spacer(minLength: 4)
            if day.newCount > 0 {
                Text("\(day.newCount) 新").font(.system(size: 12, weight: .semibold))
            } else {
                let copies = day.shots.map { model.copyCount(shot: $0) }.min() ?? 0
                Image(systemName: copies >= 2 ? "checkmark.shield.fill" : copies == 1 ? "exclamationmark.shield.fill" : "checkmark")
                    .font(.system(size: copies >= 1 ? 12 : 10, weight: .semibold))
                    .foregroundStyle(model.shownDays.contains(day.id) ? .white : copies >= 2 ? .green : copies == 1 ? .orange : .secondary)
                    .help(copies >= 2 ? "这一天的照片都有两份" : copies == 1 ? "都导入过了，但有的只有一份" : "都导入过了")
            }
            Text("\(day.shots.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                .frame(minWidth: 18, alignment: .trailing)
        }
        .contextMenu {
            Button("选这一天没导入过的") { model.selectNew(in: [day.id]) }
            Button("选这一天全部") { model.selectAll(in: [day.id]) }
            Button("取消这一天的选择") { model.deselect(in: [day.id]) }
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

/// 标题下面一行：新照片数，以及这张卡能不能格式化（每个文件是否都有两份）。
private struct CardSafetyLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.cardSafety
        Group {
            if c.canFormat {
                Label("全部文件已有两份，可以格式化存储卡", systemImage: "checkmark.shield.fill")
                    .foregroundStyle(.green)
            } else {
                let newText = model.newShotCount > 0 ? "\(model.newShotCount) 张新照片" : "没有新照片"
                let unsafe = c.one + c.none
                Text(c.two + c.one == 0 ? newText : newText + " · \(unsafe) 个文件尚未存够两份，暂不要格式化")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11)).lineLimit(1)
        .help("卡上 \(c.total) 个文件：两份 \(c.two) · 一份 \(c.one) · 未导入 \(c.none)（包括没有显示的类型，比如视频）")
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
        .help(all ? "取消选择（⌘D）" : "选中右边显示的全部照片（⌘A）")
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
                .help(model.canDeleteFromSource ? "导入并校验通过后，删除存储卡上的照片（视频不删）"
                                                : "仅适用于读卡器；经 Wi-Fi 连接相机时不能删除")
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
            Text("你的选择已保留").foregroundStyle(.secondary)
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
                                LazyVGrid(columns: columns, spacing: spacing) {
                                    ForEach(day.shots, id: \.self) { id in
                                        ThumbCell(shotID: id)
                                            .id(id)
                                            .background(GeometryReader { g in
                                                Color.clear.preference(key: CellFrameKey.self, value: [id: g.frame(in: .named("grid"))])
                                            })
                                    }
                                }
                                .padding(.init(top: 4, leading: 16, bottom: 20, trailing: 16))
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
        if !model.days.isEmpty { return "在左边选择日期" }
        return model.onlyNew ? "这些照片都导入过了" : "没有符合筛选条件的文件"
    }

    private var detail: String {
        if !model.days.isEmpty { return "点日期查看照片，按住 ⌘ 或 ⇧ 可以选择多天。" }
        return model.onlyNew ? "切换到「全部」可以看到它们。" : "在上面打开更多文件类型，或换一张卡。"
    }
}

struct DayHeader: View {
    @Environment(AppModel.self) private var model
    let day: ShootingDay

    var body: some View {
        let picked = day.shots.contains(where: model.grid.contains)
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(day.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
            Text("\(day.shots.count) 张" + (day.importedCount > 0 ? " · \(day.importedCount) 张导入过" : ""))
                .font(.system(size: 12))
            Spacer(minLength: 8)
            if day.newCount > 0 {
                Button("选未导入的") { model.selectNew(in: [day.id]) }
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
                if let shot { Badge(text: shot.badge).padding(5) }
            }
            .overlay(alignment: .bottomTrailing) {
                if imported {
                    let copies = model.copyCount(shot: shotID)
                    let text = copies >= 2 ? "两份" : copies == 1 ? "一份" : "已导入"
                    Badge(text: model.thumbSize >= 150 ? text : "", check: true,
                          checkColor: copies == 1 ? .orange : .green).padding(5)
                        .help(copies >= 2 ? "电脑上有两份，都校验过" : copies == 1 ? "只有一份，还没有备份" : "导入过，但电脑上找不到这个文件了")
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
            // 和访达一样：选中的格子只显示选中框；焦点框只在没选中的格子上出现（方向键移动时）。
            if focused && !selected { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2) }
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
                Button("选这一天没导入过的") { model.selectNew(in: [day.id]) }
                Button("选这一天全部") { model.selectAll(in: [day.id]) }
            }
            Button("反选") { model.grid.invert() }
            if let url = model.localFile(of: shotID) {
                Divider()
                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
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
                                Label("从 \(Self.bytes(from)) 处接着传", systemImage: "arrow.clockwise")
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
                    twoLines("导入中断，完成了 \(i.done)/\(i.total) 个文件",
                             (model.offline ? "相机已断开，" : "") + "没导完的 \(i.total - i.done) 个仍然选中"
                             + (i.savedBytes > 0 ? "；已保存 \(Self.bytes(i.savedBytes))，继续时从断点接着传" : ""))
                    mainButton("继续导入", disabled: model.offline) { model.continueImport() }
                }
            } else if let r = model.lastResult, r.c1Failed, model.grid.selected.isEmpty {
                capsule {
                    twoLines("没能交给 Capture One", "\(r.files) 个文件已存到电脑，不用重新下载")
                    mainButton("重新交给 C1") { model.retryCaptureOne() }
                }
            } else if !model.grid.selected.isEmpty {
                capsule {
                    if let r = model.lastResult, r.cancelled, r.savedBytes > 0, !model.offline {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("已选 \(model.selectedShotCount) 张 · \(Self.bytes(model.selectionBytes))")
                                .font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Label("已保存未传完的 \(Self.bytes(r.savedBytes))，再次导入时从断点接着传", systemImage: "arrow.clockwise")
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
        case .off: "下载"
        default: "导入到 Capture One"
        }
    }

    private var pickedDetail: String {
        if model.offline { return "相机重新连上后可以导入" }
        let files = model.selectedFiles()
        let days = Set(files.map(AppModel.dayKey)).count
        let dest = model.captureOneMode == .newSession ? model.sessionsFolder : model.destination
        var s = "\(files.count) 个文件 · \(days) 天 · 存到 \(Self.short(dest))"
        if model.backupEnabled {
            s += model.backupAvailable ? " · 备份到 \(Self.short(model.backupFolder!))" : " · ⚠︎ 备份磁盘未连接"
        }
        if model.willDeleteFromSource { s += " · 完成后删除卡上照片" }
        return s
    }

    private func resultText(_ r: AppModel.ImportResult) -> String {
        var s = "导入了 \(r.files) 个文件"
        if let session = r.session { s += "，已存入会话「\(session)」" }
        if r.resumed > 0 { s += "，其中 \(r.resumed) 个从断点续传" }
        if r.failed > 0 { s += "，\(r.failed) 个失败" }
        if let b = r.backedUp {
            s += r.backupFailed > 0 ? "，\(r.backupFailed) 个没备份成功" : (b > 0 ? "，两份都已校验" : "")
        } else {
            s += "，只存了一份"
        }
        if r.cardReadOnly {
            s += "；存储卡为只读，未删除文件"
        } else if r.deleteFailed > 0 {
            s += "；\(r.deleteFailed) 个文件未能从卡上删除"
        } else if r.deleted == 0, r.keptOnCard > 0 {
            s += r.backedUp == nil ? "；因未备份，卡上文件均已保留" : "；卡上文件均已保留"
        } else if let d = r.deleted {
            s += "，从卡上删除 \(d) 个" + (r.keptOnCard > 0 ? "（\(r.keptOnCard) 个保留）" : "")
        }
        if !r.reports.isEmpty { s += "，已写入校验清单" }
        if r.cancelled { s += r.savedBytes > 0 ? "（已取消；已保存 \(Self.bytes(r.savedBytes))，下次从断点接着传）" : "（已取消）" }
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
                            Text([shot?.badge ?? "", ThumbCell.time(item)].filter { !$0.isEmpty }.joined(separator: " · ")
                                 + (model.previewLoaded ? "" : " · 正在加载大图…"))
                            if model.isImported(shot: id) {
                                let copies = model.copyCount(shot: id)
                                Label(copies >= 2 ? "两份" : copies == 1 ? "只有一份" : "已导入", systemImage: "checkmark")
                            }
                        }
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.72))
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
