import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// 设置向导：使用方式 → 照片 → 视频 → 备份 → 完成。第一次打开时出现，也可从“设置 › 通用”再打开。
/// 左边是步骤栏，右边是这一步的内容。每一步直接改设置（和设置窗口里是同一份），中途关掉也不会丢。
struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    /// 从设置里打开的：可以直接关闭。
    var reopened = false
    var close: () -> Void = {}

    fileprivate enum Step: Int, CaseIterable {
        case mode, photos, video, backup, done

        var title: String {
            switch self {
            case .mode: "使用方式"
            case .photos: "照片"
            case .video: "视频"
            case .backup: "备份"
            case .done: "完成"
            }
        }
        var symbol: String {
            switch self {
            case .mode: "person"
            case .photos: "photo"
            case .video: "film"
            case .backup: "externaldrive"
            case .done: "checkmark.circle"
            }
        }
    }

    @State private var step = Step.mode
    /// 走到过的最远一步：侧栏里这一步之前的都可以点回去。
    @State private var reached = Step.mode
    /// 装了哪些软件：打开时找一次（要扫各个“应用程序”文件夹）。
    @State private var apps: [AppInfo.Kind: AppInfo] = [:]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header
                        content
                    }
                    .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(step)
                    .transition(.opacity)
                }
                .scrollBounceBehavior(.basedOnSize)
                Divider()
                footer
            }
        }
        .frame(width: 780, height: 560)
        .background(Theme.surface)
        .task {
            apps = Dictionary(uniqueKeysWithValues: AppInfo.Kind.allCases.map { ($0, AppInfo.find($0)) })
            model.refreshCaptureOne()
        }
    }

    private func go(_ s: Step) {
        withAnimation(.easeInOut(duration: 0.15)) {
            step = s
            if s.rawValue > reached.rawValue { reached = s }
        }
    }

    // MARK: 框架

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text("MiniDiT").font(.headline)
                    Text("设置向导").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 24)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Step.allCases, id: \.self) { s in
                    StepRow(step: s, current: s == step)
                        .onTapGesture { if s.rawValue <= reached.rawValue { go(s) } }
                        .opacity(s.rawValue <= reached.rawValue ? 1 : 0.4)
                }
            }
            Spacer()
            if reopened {
                Button("关闭向导") { close() }.controlSize(.regular)
            }
        }
        .padding(20)
        .frame(width: 210, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            Text(subtitle).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("第 \(step.rawValue + 1) 步，共 \(Step.allCases.count) 步")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if step != .mode {
                Button("上一步") { go(Step(rawValue: step.rawValue - 1)!) }
            }
            if step == .done {
                Button("开始使用") {
                    model.setupDone = true
                    close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("继续") { go(Step(rawValue: step.rawValue + 1)!) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .backup && model.backupEnabled && model.backupFolder == nil)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 32).padding(.vertical, 14)
    }

    private var title: String {
        switch step {
        case .mode: reopened ? "选择使用方式" : "欢迎使用 MiniDiT"
        case .photos: "照片交给哪个软件"
        case .video: "视频放在哪里"
        case .backup: "要不要备份"
        case .done: "一切就绪"
        }
    }

    private var subtitle: String {
        switch step {
        case .mode: "它只决定默认设置和显示哪些选项，不会锁住任何功能。\n之后可在“设置 › 通用”中更改。"
        case .photos: "照片导入后直接进入你修图用的软件。只列出这台 Mac 上安装了的软件。"
        case .video: "视频保留原文件名，按日期和事件建文件夹存放，不进入修图软件。"
        case .backup: "导入时可同时在另一块磁盘上再存一份，照片和视频都会备份。"
        case .done: "以下设置随时可在“设置”中修改，也可以点“更改”回到对应的步骤。"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .mode: modeStep
        case .photos: photosStep
        case .video: videoStep
        case .backup: backupStep
        case .done: doneStep
        }
    }

    // MARK: 使用方式

    private var modeStep: some View {
        HStack(alignment: .top, spacing: 14) {
            ModeTile(symbol: "person", title: "个人", tagline: "自己拍，自己修图剪辑",
                     points: ["照片直接进入 Capture One 或 Lightroom", "校验和备份在后台完成", "设置只显示常用选项"],
                     selected: model.usageMode == .personal) { setMode(.personal) }
            ModeTile(symbol: "person.3", title: "专业", tagline: "给团队或客户交付素材",
                     points: ["视频按卷号分文件夹，写入卷名和色彩空间", "显示命名模板等全部选项", "不自动导入，不删除存储卡上的文件"],
                     selected: model.usageMode == .pro) { setMode(.pro) }
        }
    }

    private func setMode(_ m: UsageMode) {
        guard model.usageMode != m else { return }
        model.usageMode = m
        model.applyModeDefaults()
    }

    // MARK: 照片

    private var isC1: Bool { [.newSession, .c1Settings, .inPlace].contains(model.captureOneMode) }

    @ViewBuilder private var photosStep: some View {
        VStack(spacing: 10) {
            if let c1 = apps[.captureOne], c1.isInstalled {
                ChoiceCard(icon: .app(c1.url), title: "Capture One",
                           detail: "每次导入新建一个会话（如“11.7-公园”），照片存入会话的 Capture 文件夹。",
                           selected: isC1) {
                    if !isC1 { model.captureOneMode = .newSession }
                }
            }
            if let lr = apps[.lightroom], lr.isInstalled {
                ChoiceCard(icon: .app(lr.url), title: "Lightroom Classic",
                           detail: "下载后添加到当前目录，按收藏夹整理。第一次导入时会提示安装 MiniDiT 插件。",
                           selected: model.captureOneMode == .lightroom) {
                    model.captureOneMode = .lightroom
                }
            }
            ChoiceCard(icon: .symbol("folder"), title: "只存到文件夹",
                       detail: "按日期分文件夹存放，之后用访达、Bridge 或其他软件打开。",
                       selected: model.captureOneMode == .off) {
                model.captureOneMode = .off
            }
        }
        if model.captureOneMode != .c1Settings && model.captureOneMode != .inPlace {
            Panel {
                if model.captureOneMode == .newSession {
                    FolderRow(title: "新会话的位置", url: model.sessionsFolder) { model.sessionsFolder = $0 }
                } else {
                    FolderRow(title: "照片存放位置", url: model.destination) { model.destination = $0 }
                }
                if model.captureOneMode == .off {
                    @Bindable var model = model
                    PanelDivider()
                    PanelRow(icon: .symbol("arrow.up.forward.app"), title: "导入完成后打开") {
                        Picker("导入完成后打开", selection: $model.openAfterImport) {
                            ForEach(FolderApp.allCases.filter { $0.isAvailable || $0 == model.openAfterImport }) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
            }
        }
    }

    // MARK: 视频

    @ViewBuilder private var videoStep: some View {
        @Bindable var model = model
        Panel {
            FolderRow(title: "视频存放位置", url: model.videoDestination) { model.videoDestination = $0 }
            PanelDivider()
            PanelRow(icon: .symbol("square.on.square"), title: "同时导入代理文件",
                     detail: "存入旁边的“Proxy”文件夹，剪辑软件会自动链接。") {
                Toggle("同时导入代理文件", isOn: $model.importProxies).labelsHidden().toggleStyle(.switch)
            }
        }
        let editors = [apps[.resolve], apps[.finalCut]].compactMap { $0 }.filter(\.isInstalled)
        if !editors.isEmpty {
            SectionTitle("导入完成后交给剪辑软件")
            Panel {
                ForEach(Array(editors.enumerated()), id: \.element.kind) { i, app in
                    if i > 0 { PanelDivider() }
                    if app.kind == .resolve {
                        PanelRow(icon: .app(app.url), title: "DaVinci Resolve",
                                 detail: "加入当前项目，每个视频文件夹一个媒体夹。须在 Resolve 的“偏好设置 › 系统 › 常规”中把“外部脚本使用”设为“本地”。") {
                            Toggle("DaVinci Resolve", isOn: $model.sendToResolve).labelsHidden().toggleStyle(.switch)
                        }
                    } else {
                        PanelRow(icon: .app(app.url), title: "Final Cut Pro",
                                 detail: "每个视频文件夹一个事件，片段原地引用，不复制进资源库。") {
                            Toggle("Final Cut Pro", isOn: $model.sendToFCP).labelsHidden().toggleStyle(.switch)
                        }
                    }
                }
            }
        }
    }

    // MARK: 备份

    @ViewBuilder private var backupStep: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            ChoiceCard(icon: .symbol("internaldrive"), title: "仅存储一份",
                       detail: "只存到前面选的照片和视频存放位置。",
                       selected: !model.backupEnabled) { model.backupEnabled = false }
            ChoiceCard(icon: .symbol("externaldrive.badge.plus"), title: "同时备份",
                       detail: "在另一块磁盘上再存一份，两份都校验通过才算导入完成。备份磁盘没接上时会先询问。",
                       selected: model.backupEnabled) { model.backupEnabled = true }
        }
        if model.backupEnabled || !model.isPro {
            Panel {
                if model.backupEnabled {
                    FolderRow(title: "备份位置", url: model.backupFolder, empty: "尚未选择，请选择另一块磁盘上的文件夹") { model.backupFolder = $0 }
                    if !model.isPro { PanelDivider() }
                }
                if !model.isPro {
                    PanelRow(icon: .symbol("sdcard"), title: "导入后删除存储卡上的照片",
                             detail: "仅适用于读卡器，且只删除校验通过的照片。") {
                        Toggle("导入后删除存储卡上的照片", isOn: $model.deleteAfterImport).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
    }

    // MARK: 完成

    @ViewBuilder private var doneStep: some View {
        Panel {
            SummaryRow(icon: .symbol(model.usageMode == .personal ? "person" : "person.3"),
                       label: "使用方式", value: model.usageMode.title, detail: model.isPro ? "显示全部选项" : "只显示常用选项") { go(.mode) }
            PanelDivider()
            SummaryRow(icon: photoIcon, label: "照片", value: photoTitle, detail: photoDetail) { go(.photos) }
            PanelDivider()
            SummaryRow(icon: .symbol("film"), label: "视频", value: videoTitle, detail: short(model.videoDestination)) { go(.video) }
            PanelDivider()
            SummaryRow(icon: backupOn ? .symbol("externaldrive.badge.checkmark") : .symbol("internaldrive"), label: "备份",
                       value: backupOn ? "同时备份" : "仅存储一份",
                       detail: backupOn ? short(model.backupFolder!) : nil) { go(.backup) }
        }
        // 和上面的分组同一种行：图标、文字的位置都对齐。
        Panel {
            PanelRow(icon: .symbol("lightbulb"), title: "接下来",
                     detail: "插入存储卡，或让相机连上与 Mac 相同的 Wi-Fi 并开启遥控拍摄，MiniDiT 会自动找到它。"
                        + (model.captureOneMode == .lightroom ? "第一次导入到 Lightroom Classic 时，会提示安装 MiniDiT 插件。" : "")) {
                EmptyView()
            }
        }
    }

    private var backupOn: Bool { model.backupEnabled && model.backupFolder != nil }

    private var photoIcon: CardIcon {
        switch model.captureOneMode {
        case .newSession, .c1Settings, .inPlace: .app(apps[.captureOne]?.url)
        case .lightroom: .app(apps[.lightroom]?.url)
        case .off: .symbol("folder")
        }
    }

    private var photoTitle: String {
        switch model.captureOneMode {
        case .newSession: "Capture One · 新建会话"
        case .c1Settings: "Capture One · 按导入设置"
        case .inPlace: "Capture One · 就地添加"
        case .lightroom: "Lightroom Classic"
        case .off: "只存到文件夹"
        }
    }

    private var photoDetail: String? {
        switch model.captureOneMode {
        case .newSession: short(model.sessionsFolder)
        case .c1Settings, .inPlace: "Capture One 当前打开的文档"
        case .lightroom, .off: short(model.destination)
        }
    }

    private var videoTitle: String {
        var to: [String] = []
        if model.sendToResolve, apps[.resolve]?.isInstalled == true { to.append("DaVinci Resolve") }
        if model.sendToFCP, apps[.finalCut]?.isInstalled == true { to.append("Final Cut Pro") }
        return to.isEmpty ? "存到文件夹，不交给剪辑软件" : "交给 " + to.joined(separator: " 和 ")
    }

    /// 「~/Pictures/MiniDiT」
    private func short(_ u: URL) -> String {
        let p = u.path(percentEncoded: false), home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return p.hasPrefix(home) ? "~/" + p.dropFirst(home.count) : p
    }
}

// MARK: - 部件

fileprivate enum CardIcon {
    /// 主题色的线条符号。
    case symbol(String)
    /// 第三方软件用它自己的图标，认得出来。
    case app(URL?)
}

private struct CardIconView: View {
    let icon: CardIcon
    var size: CGFloat = 32

    var body: some View {
        switch icon {
        case .symbol(let s):
            Image(systemName: s).font(.system(size: size * 0.6, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: size, height: size)
        case .app(let u):
            if let u {
                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path(percentEncoded: false)))
                    .resizable().interpolation(.high).frame(width: size + 6, height: size + 6).padding(-3)
            } else {
                CardIconView(icon: .symbol("app"), size: size)
            }
        }
    }
}

/// 侧栏里的一步：当前这步用主题色，其余灰色。
private struct StepRow: View {
    let step: SetupSheet.Step
    let current: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: step.symbol).font(.system(size: 14))
                .frame(width: 20)
            Text(step.title).font(.body.weight(current ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .foregroundStyle(current ? Theme.accent : Color.secondary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

/// 使用方式的一块：图标、名称、一句话、三条要点。
private struct ModeTile: View {
    let symbol: String
    let title: String
    let tagline: String
    let points: [String]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    CardIconView(icon: .symbol(symbol), size: 40)
                    Spacer()
                    SelectMark(selected: selected)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(tagline).font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(points, id: \.self) { p in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.tint)
                            Text(p).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
            .modifier(CardBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 单选的一张卡片：图标、标题、说明，选中时描边。
private struct ChoiceCard: View {
    let icon: CardIcon
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                CardIconView(icon: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                SelectMark(selected: selected)
            }
            .padding(.horizontal, 16).padding(.vertical, 13)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            .modifier(CardBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SelectMark: View {
    let selected: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 1.5)
            if selected {
                Circle().fill(Color.accentColor)
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: 20, height: 20)
    }
}

private struct CardBackground: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.border, lineWidth: selected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }
}

/// 一组设置：圆角底，行之间有分隔线（和“设置”窗口里的分组一个样子）。
private struct Panel<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct PanelDivider: View {
    var body: some View { Divider().padding(.leading, 62) }
}

private struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline).padding(.bottom, -10)
    }
}

/// 面板里的一行：图标、标题和说明，右边放控件。
private struct PanelRow<Trailing: View>: View {
    let icon: CardIcon
    let title: String
    var detail: String? = nil
    /// 说明是一条路径：一行显示，中间省略。
    var isPath = false
    var warn = false
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 14) {
            CardIconView(icon: icon, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(warn ? Color.orange : Color.secondary)
                        .lineLimit(isPath ? 1 : nil).truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: !isPath)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// 选文件夹的一行：路径显示在标题下面，右边“更改…”。
private struct FolderRow: View {
    let title: String
    let url: URL?
    var empty = "尚未选择"
    let set: (URL) -> Void

    var body: some View {
        PanelRow(icon: .symbol("folder"), title: title, detail: url?.path(percentEncoded: false) ?? empty,
                 isPath: url != nil, warn: url == nil) {
            Button(url == nil ? "选择…" : "更改…") {
                if let u = FolderPicker.choose(start: url) { set(u) }
            }
        }
    }
}

/// 完成页的一行：图标、类别、选了什么、路径，右边“更改”。
private struct SummaryRow: View {
    let icon: CardIcon
    let label: String
    let value: String
    var detail: String?
    let change: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            CardIconView(icon: icon, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body.weight(.medium))
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            Button("更改", action: change).buttonStyle(.link)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }
}

enum FolderPicker {
    @MainActor
    static func choose(start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}
