import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

// 侧栏：项目列表、来源卡片、日期和场次。

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
            s += String(localized: " · 仅卡 \(slot)")
        }
        if let t = model.profile(source.id)?.clockOffset, t != 0 { s += String(localized: " · 时间 \(CameraProfile.offsetText(t))") }
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
                    .help(model.isTetherSource(source.id) ? "结束联机拍摄并关闭联机缓存" : source.isCard ? "推出 \(source.detail.replacingOccurrences(of: String(localized: "读卡器") + " · ", with: ""))" : "断开此相机")
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
            Button(model.isTetherSource(source.id) ? "关闭联机缓存" : source.isCard ? "推出存储卡" : "断开相机", role: .destructive) {
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
        let options: [SegmentPicker<UInt32?>.Option] = [.init(title: String(localized: "合并"), value: nil)]
            + model.sourceSlots(id).map { .init(title: String(localized: "卡 \($0)"), value: $0) }
        ChoicePicker(title: String(localized: "卡槽"), options: options,
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

/// 侧栏的日期：「11月4日 周三」（英文「Nov 4 Wed」）拆成日期和星期，日期占固定宽度（按最长的写法留位），星期上下对齐。
struct DayTitle: View {
    let title: String

    private static func placeholder(_ date: String) -> String {
        if date.contains("年") { return "0000年00月00日" }
        if date.contains("月") { return "00月00日" }
        return date.contains(",") ? "Mmm 00, 0000" : "Mmm 00"
    }

    var body: some View {
        // 星期在最后：按最后一个空格拆（英文日期中间也有空格）。
        let parts = title.range(of: " ", options: .backwards).map { [String(title[..<$0.lowerBound]), String(title[$0.upperBound...])] } ?? [title]
        if parts.count == 2 {
            HStack(spacing: 6) {
                ZStack(alignment: .leading) {
                    // 占位：数字换成 0，月和日都按两位算。
                    Text(verbatim: Self.placeholder(parts[0])).hidden()
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
struct ShotCounts: View {
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

/// 「按时间分场次」：不分 / 隔多久分一场。和「设置 › 照片 › 场次」是同一个选项。
struct SceneGapMenu: View {
    @Environment(AppModel.self) private var model

    static let options: [(String, Int)] = [(String(localized: "不分场次"), 0), (String(localized: "30 分钟"), 30), (String(localized: "1 小时"), 60),
                                           (String(localized: "2 小时"), 120), (String(localized: "3 小时"), 180), (String(localized: "4 小时"), 240)]

    var body: some View {
        @Bindable var model = model
        Picker("按时间分场次", selection: $model.sceneGap) {
            ForEach(Self.options, id: \.1) { Text($0.0).tag($0.1) }
        }
    }
}
