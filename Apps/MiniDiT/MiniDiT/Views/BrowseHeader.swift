import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

// 标题区：筛选、导入选项、离线提示。

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
            if model.isTethering || model.canStartTether {
                Button {
                    if model.isTethering { model.tetherWindowRequest += 1 }
                    else { model.startTetherFromCurrent() }
                } label: {
                    Label(model.isTethering ? "联机拍摄窗口" : "联机拍摄", systemImage: "camera.aperture")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .disabled(!model.isTethering && model.progress != nil)
                .help(model.isTethering ? "显示联机拍摄窗口" : "断开当前导入连接，改为遥控这台相机拍摄，拍好的照片自动导入当前项目（⇧⌘T）")
            }
            Slider(value: $model.thumbSize, in: 110...320)
                .frame(width: 76)
                .accessibilityLabel("缩略图大小")
                .help("缩略图大小（⌘+ / ⌘−）")
        }
        .padding(.leading, 20).padding(.trailing, 16)
        .frame(minHeight: 52)
    }
}

struct BrowseFilters: View {
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
            if let session = model.currentSession {
                VStack(alignment: .leading, spacing: 4) {
                    Text("项目类型").font(Theme.Font.caption).foregroundStyle(.secondary)
                    Text(session.contentType.title).font(Theme.Font.body)
                        .frame(minHeight: 22)
                        .help("“\(session.name)”只导入\(session.contentType.title)；可在侧栏右键菜单中更改")
                }
                .accessibilityElement(children: .combine)
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

struct ImportOptions: View {
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
