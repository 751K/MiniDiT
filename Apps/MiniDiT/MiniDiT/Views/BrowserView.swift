import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            DayList()
                .navigationSplitViewColumnWidth(min: 230, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                GridView()
                ImportBar()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.disconnect() } label: { Label("断开", systemImage: "xmark.circle") }
                    .disabled(model.progress != nil)
                    .help(model.sourceKind == .card ? "关闭存储卡" : "断开相机")
            }
            ToolbarItemGroup {
                if model.slots.count > 1 {
                    Picker("卡槽", selection: $model.slotFilter) {
                        Text("全部卡槽").tag(UInt32?.none)
                        ForEach(model.slots, id: \.self) { Text("卡 \($0)").tag(UInt32?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("JPG/HIF", isOn: $model.showPhotos)
                Toggle("RAW", isOn: $model.showRaw)
                Toggle("视频", isOn: $model.showVideo)
                Toggle("只看未导入", isOn: $model.onlyNew)
                Slider(value: $model.thumbSize, in: 110...320) { Text("缩略图大小") }
                    .frame(width: 110)
                    .help("缩略图大小（⌘+ / ⌘−）")
            }
        }
        .navigationTitle(model.connectedName ?? "MiniDiT")
        .overlay {
            if model.previewShot != nil {
                PreviewSheet().transition(.opacity)
            }
        }
    }
}

// MARK: - 侧栏

struct DayList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.shownDays) {
            Section {
                ForEach(model.days) { day in
                    HStack(spacing: 8) {
                        Button { model.toggleDay(day) } label: {
                            Image(systemName: Self.icon(model.checkState(day)))
                                .foregroundStyle(model.checkState(day) == .off ? Color.secondary : Color.accentColor)
                                .font(.body)
                        }
                        .buttonStyle(.plain)
                        .help(day.newCount > 0 ? "勾选这一天没导入过的 \(day.newCount) 张" : "勾选这一天全部")
                        Text(day.title)
                        Spacer()
                        if day.newCount > 0 {
                            Text("\(day.newCount) 新").font(.caption).foregroundStyle(Color.accentColor)
                        } else {
                            Text("已导入").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(day.shots.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(minWidth: 30, alignment: .trailing)
                    }
                    .tag(day.id)
                    .contextMenu {
                        Button("选这一天没导入过的") { model.selectNew(in: [day.id]) }
                        Button("选这一天全部") { model.selectAll(in: [day.id]) }
                        Button("取消这一天的选择") { model.deselect(in: [day.id]) }
                    }
                }
            } header: {
                Text("勾选 = 导入这天的新照片")
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.connectedName ?? "").bold()
                Text(sourceText).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
        }
    }

    private var sourceText: String {
        if model.sourceKind == .card { return "存储卡 · 读卡器" }
        return (model.connectedHost ?? "") + (model.usesRemoteTransfer ? " · 远程传输" : " · 内容传输模式")
    }

    static func icon(_ s: CheckState) -> String {
        switch s {
        case .off: "square"
        case .mixed: "minus.square.fill"
        case .on: "checkmark.square.fill"
        }
    }
}

// MARK: - 网格

private struct CellFrameKey: PreferenceKey {
    static let defaultValue: [UInt32: CGRect] = [:]
    static func reduce(value: inout [UInt32: CGRect], nextValue: () -> [UInt32: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct GridView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool
    @State private var frames: [UInt32: CGRect] = [:]
    @State private var box: CGRect?
    @State private var width: CGFloat = 800

    private var spacing: CGFloat { 8 }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: model.thumbSize, maximum: model.thumbSize * 1.5), spacing: spacing)] }
    /// 和 LazyVGrid 的自适应列数算法一致，方向键上下移动用。
    private var columnCount: Int { max(1, Int((width - 24 + spacing) / (model.thumbSize + spacing))) }

    var body: some View {
        if model.visibleDays.isEmpty {
            ContentUnavailableView(model.days.isEmpty ? "没有可导入的内容" : "在左边选择日期", systemImage: "calendar",
                                   description: Text(model.days.isEmpty
                                                     ? (model.onlyNew ? "这张卡上的都导入过了。关掉「只看未导入」可以看到全部。" : "没有符合筛选条件的文件。")
                                                     : "可以按住 ⌘ 或 ⇧ 选择多天。"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
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
                            } header: {
                                DayHeader(day: day)
                            }
                        }
                    }
                    .padding(12)
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
                .background(GeometryReader { g in Color.clear.onAppear { width = g.size.width }.onChange(of: g.size.width) { width = $1 } })
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
                    if let f = model.grid.focus { withAnimation(.none) { proxy.scrollTo(f) } }
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

struct DayHeader: View {
    @Environment(AppModel.self) private var model
    let day: ShootingDay

    var body: some View {
        HStack {
            Text(day.title).font(.headline)
            Text("\(day.shots.count) 张" + (day.importedCount > 0 ? "，\(day.importedCount) 张导入过" : "")).foregroundStyle(.secondary)
            Spacer()
            Button("选未导入的") { model.selectNew(in: [day.id]) }
            Button("全选") { model.selectAll(in: [day.id]) }
            Button("取消选择") { model.deselect(in: [day.id]) }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 6)
        .background(.bar)
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
        VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(.quaternary)
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .overlay {
                        if let img = model.thumbnails[primary] {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: shot?.isVideo == true ? "video" : "photo").foregroundStyle(.tertiary)
                        }
                    }
                    .clipped()
                    .opacity(imported && !selected ? 0.55 : 1)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.white, Color.accentColor)
                        .shadow(radius: 2)
                        .padding(6)
                }
                if let shot {
                    Text(shot.badge).font(.caption2.bold())
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : focused ? Color.secondary : .clear,
                                                              lineWidth: selected ? 3 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 4) {
                Text(item?.baseName ?? "").font(.caption).lineLimit(1)
                if imported {
                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green).help("导入过")
                }
                Spacer()
                Text(Self.time(item)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
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
        .onAppear { model.requestThumbnail(primary) }
        .onDisappear { model.cancelThumbnail(primary) }
    }

    static func time(_ item: CameraContentItem?) -> String {
        guard let raw = item?.captureDateRaw, raw.count >= 13 else { return "" }
        let t = raw.dropFirst(9)
        return "\(t.prefix(2)):\(t.dropFirst(2).prefix(2))"
    }
}

// MARK: - 大图预览

struct PreviewSheet: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let id = model.previewShot ?? 0
        let shot = model.shots[id]
        let item = shot.flatMap { model.item($0.primary) }
        let selected = model.grid.contains(id)
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let img = model.previewImage {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(item?.baseName ?? "").bold()
                Text(shot?.badge ?? "").foregroundStyle(.secondary)
                Text(ThumbCell.time(item)).foregroundStyle(.secondary)
                if model.isImported(shot: id) { Label("导入过", systemImage: "checkmark.seal.fill").foregroundStyle(.green) }
                Spacer()
                Text("← → 翻页 · P 选中 · Esc 关闭").font(.caption).foregroundStyle(.secondary)
                Button(selected ? "取消选中" : "选中") { model.togglePreviewSelection() }
                    .buttonStyle(.borderedProminent).tint(selected ? .gray : .accentColor)
                Button("关闭") { model.closePreview() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(.bar)
        }
        .background(Color.black)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { model.previewStep(-1); return .handled }
        .onKeyPress(.rightArrow) { model.previewStep(1); return .handled }
        .onKeyPress(.space) { model.closePreview(); return .handled }
        .onKeyPress(.escape) { model.closePreview(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { _ in model.togglePreviewSelection(); return .handled }
    }
}

// MARK: - 底部

struct ImportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = model.progress {
                HStack {
                    ProgressView(value: p.fraction)
                    Text("\(p.done + p.skipped + p.reused + p.failed.count)/\(p.total)").monospacedDigit()
                    Button("取消") { model.cancelImport() }
                }
                Text("正在导入 \(p.current) · \(Self.bytes(p.bytesDone)) / \(Self.bytes(p.bytesTotal))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectionText)
                        Text(targetText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let s = model.lastSummary {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if s.contains("Capture One 导入失败") { Button("重新交给 C1") { model.retryCaptureOne() } }
                    }
                    if model.sourceKind == .card {
                        Button("推出存储卡") { model.ejectCard() }
                    }
                    Button("设置…") { openSettings() }
                    Button {
                        model.beginImport()
                    } label: {
                        Label(model.captureOneMode == .off ? "下载" : model.captureOneMode == .newSession ? "导入到新会话…" : "导入到 Capture One",
                              systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.grid.selected.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(12)
        .background(.bar)
        .onAppear { model.refreshCaptureOne() }
    }

    private var selectionText: String {
        guard !model.grid.selected.isEmpty else { return "勾选左边的日期，或在右边点选照片（⇧ 连选、⌘ 加选、拖动框选）" }
        let files = model.selectedFiles()
        let days = Set(files.map(AppModel.dayKey)).count
        return "已选 \(model.selectedShotCount) 张（\(files.count) 个文件）· \(days) 天 · \(Self.bytes(files.reduce(0) { $0 + $1.size }))"
    }

    private var targetText: String {
        if model.captureOneMode == .newSession {
            return "新建会话放在 \(model.sessionsFolder.path(percentEncoded: false))，照片直接存进会话的 Capture 文件夹"
        }
        var s = "存到 \(model.destination.path(percentEncoded: false))/年/年-月-日"
        switch model.captureOneMode {
        case .off, .newSession: break
        case .c1Settings, .inPlace:
            if let d = model.captureOneDocument { s += " → C1 \(d.kind)「\(d.name)」" } else { s += " → Capture One（导入时自动打开）" }
        }
        return s
    }

    static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}
