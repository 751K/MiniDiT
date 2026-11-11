import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

// 网格：缩略图、日期和场次标题、空状态。

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
