import AppKit
import UniformTypeIdentifiers
import SwiftUI

/// 设置向导：工作流程 → 照片 → 视频 → 备份 → 完成。第一次打开时出现，也可从“设置 › 通用”再打开。
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
            case .mode: "工作流程"
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

    private var steps: [Step] {
        Step.allCases
    }
    private var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    @State private var recommendedMode: UsageMode?
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
                ForEach(steps, id: \.self) { s in
                    StepRow(step: s, current: s == step)
                        .onTapGesture { if s.rawValue <= reached.rawValue { go(s) } }
                        .opacity(s.rawValue <= reached.rawValue ? 1 : 0.4)
                }
            }
            Spacer()
            Button(reopened ? "关闭向导" : "稍后设置") {
                model.setupDone = true
                close()
            }.controlSize(.regular)
        }
        .padding(20)
        .frame(width: 210, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("第 \(stepIndex + 1) 步，共 \(steps.count) 步")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
            Spacer()
            if step != .mode {
                Button("上一步") { go(steps[max(0, stepIndex - 1)]) }
            }
            if step == .done {
                Button("开始使用") {
                    model.setupDone = true
                    close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("继续") { go(steps[min(steps.count - 1, stepIndex + 1)]) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .backup && model.backupEnabled && model.enabledBackupTargets.isEmpty)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 32).padding(.vertical, 14)
    }

    private var title: String {
        switch step {
        case .mode: reopened ? "工作流程" : "欢迎使用 MiniDiT"
        case .photos: "照片"
        case .video: "视频"
        case .backup: "备份"
        case .done: "设置完成"
        }
    }

    private var subtitle: String? {
        step == .mode ? "先选择要导入的内容。流程推荐可选，保留当前设置也可以直接继续。" : nil
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

    // MARK: 工作流程

    private var modeStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                ModeTile(symbol: "person", title: "个人创作",
                         points: ["自己拍摄、整理和后期", "视频按日期、事件整理", "命名、备份与色彩管理均可设置"],
                         selected: recommendedMode == .personal) { setMode(.personal) }
                ModeTile(symbol: "person.3", title: "团队协作",
                         points: ["多人拍摄，素材交给团队后期", "视频按卷号分文件夹，便于交接", "推荐手动导入，并保留原卡文件"],
                         selected: recommendedMode == .team) { setMode(.team) }
            }
            if let recommendation = recommendedMode {
                Text(recommendation == .team
                     ? "仅在未自定义时建议按卷号整理视频，并关闭自动导入和导入后删除。不会启用尚未配置的备份。"
                     : "仅恢复默认的视频整理建议，保留自定义规则；不会开启自动导入或删除。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("应用这组推荐设置") {
                    model.usageMode = recommendation
                    model.applyModeDefaults()
                    recommendedMode = nil
                }
            }
        }
    }

    private func setMode(_ m: UsageMode) {
        recommendedMode = m
    }

    // MARK: 照片

    private var isC1: Bool { [.newSession, .c1Settings, .inPlace].contains(model.captureOneMode) }

    @ViewBuilder private var photosStep: some View {
        let c1On = apps[.captureOne]?.isInstalled == true, lrOn = apps[.lightroom]?.isInstalled == true
        // 和“设置 › 照片”同一种列表：一组里每行一个开关，选中靠开关表示，不另加描边。
        SectionTitle("存放位置")
        Panel {
            if model.captureOneMode == .newSession {
                FolderRow(title: "Capture One 会话根目录", url: model.sessionsFolder) { model.sessionsFolder = $0 }
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
        SectionTitle("整理方式")
        if model.captureOneMode != .newSession {
            Panel { MediaOrganizationOptions(video: false).padding(14) }
        } else {
            Text("照片直接存入同名 Capture One 会话的 Capture 文件夹。")
                .font(.caption).foregroundStyle(.secondary)
        }
        SectionTitle("导入至")
        Panel {
            ChoiceCard(icon: CaptureOneMode.off.importIcon, title: "文件夹",
                       selected: model.captureOneMode == .off) {
                model.captureOneMode = .off
            }
            if c1On {
                PanelDivider()
                ChoiceCard(icon: CaptureOneMode.newSession.importIcon, title: "Capture One",
                           selected: isC1) {
                    if !isC1 { model.captureOneMode = .newSession }
                }
                if isC1 {
                    CaptureOneImportOptions()
                        .padding(.leading, 60).padding(.trailing, 14).padding(.bottom, 11)
                }
            }
            if lrOn {
                PanelDivider()
                ChoiceCard(icon: CaptureOneMode.lightroom.importIcon, title: "Lightroom Classic",
                           detail: "需安装 MiniDiT 插件。",
                           selected: model.captureOneMode == .lightroom) {
                    model.captureOneMode = .lightroom
                }
            }
        }
    }

    // MARK: 视频

    @ViewBuilder private var videoStep: some View {
        @Bindable var model = model
        let editors = [apps[.resolve], apps[.finalCut], apps[.premiere], apps[.jianying]].compactMap { $0 }.filter(\.isInstalled)
        SectionTitle("存放位置")
        Panel {
            FolderRow(title: "视频存放位置", url: model.videoDestination) { model.videoDestination = $0 }
        }
        SectionTitle("整理方式")
        Panel { MediaOrganizationOptions(video: true).padding(14) }
        SectionTitle("导入至")
        Panel {
            ChoiceCard(icon: CaptureOneMode.off.importIcon, title: "文件夹",
                       selected: !model.sendToResolve && !model.sendToFCP && !model.sendToPremiere && !model.sendToJianying) {
                model.sendToResolve = false
                model.sendToFCP = false
                model.sendToPremiere = false
                model.sendToJianying = false
            }
            ForEach(editors, id: \.kind) { app in
                PanelDivider()
                if app.kind == .resolve {
                    PanelRow(icon: .app(app.url), title: "DaVinci Resolve") {
                        ResolveImportToggle(title: "DaVinci Resolve").labelsHidden().toggleStyle(.switch)
                    }
                } else if app.kind == .premiere {
                    PanelRow(icon: .app(app.url), title: "Adobe Premiere Pro") {
                        PremiereImportToggle().labelsHidden().toggleStyle(.switch)
                    }
                } else if app.kind == .jianying {
                    PanelRow(icon: .app(app.url), title: "剪映专业版") {
                        JianyingImportToggle(title: "剪映专业版").labelsHidden().toggleStyle(.switch)
                    }
                } else {
                    PanelRow(icon: .app(app.url), title: "Final Cut Pro") {
                        Toggle("Final Cut Pro", isOn: $model.sendToFCP).labelsHidden().toggleStyle(.switch)
                    }
                }
            }
        }
        SectionTitle("代理")
        Panel {
            PanelRow(icon: .symbol("square.on.square"), title: "导入原片时，一并导入代理") {
                Toggle("导入原片时，一并导入代理", isOn: $model.importProxies).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    // MARK: 备份

    @ViewBuilder private var backupStep: some View {
        @Bindable var model = model
        // 和“设置 › 备份”一样：一个开关，打开后选位置。
        Panel {
            PanelRow(icon: .symbol("externaldrive.badge.plus"), title: "导入时同时备份") {
                BackupSettingsSwitch(title: "导入时同时备份", isOn: $model.backupEnabled)
            }
            if model.backupEnabled {
                PanelDivider()
                BackupTargetsEditor().padding(14)
            }
        }
        Panel {
            PanelRow(icon: .symbol("sdcard"), title: "导入后删除存储卡上已校验的照片（仅限读卡器）") {
                BackupSettingsSwitch(title: "导入后删除存储卡上的照片", isOn: $model.deleteAfterImport)
            }
        }
    }

    // MARK: 完成

    @ViewBuilder private var doneStep: some View {
        Panel {
            SummaryRow(icon: .symbol(model.usageMode == .personal ? "person" : "person.3"),
                       label: "工作流程", value: model.usageMode.title) { go(.mode) }
            PanelDivider()
            PanelDivider()
            SummaryRow(icon: photoIcon, label: "照片", value: photoTitle, detail: photoDetail) { go(.photos) }
            PanelDivider()
            SummaryRow(icon: .symbol("film"), label: "视频", value: videoTitle, detail: short(model.videoDestination)) { go(.video) }
            PanelDivider()
            SummaryRow(icon: backupOn ? .symbol("externaldrive.badge.checkmark") : .symbol("internaldrive"), label: "备份",
                       value: backupOn ? "同时备份" : "仅存储一份",
                       detail: backupOn ? model.backupSummary : nil) { go(.backup) }
        }
        // 和上面的分组同一种行：图标、文字的位置都对齐。
        Panel {
            PanelRow(icon: .symbol("lightbulb"), title: "后续步骤",
                     detail: "插入存储卡，或将相机接入同一 Wi-Fi 并开启遥控拍摄。") {
                EmptyView()
            }
        }
    }

    private var backupOn: Bool { model.backupEnabled && !model.enabledBackupTargets.isEmpty }

    private var photoIcon: CardIcon { model.captureOneMode.importIcon }

    private var photoTitle: String {
        switch model.captureOneMode {
        case .newSession: "Capture One · 新建会话"
        case .c1Settings: "Capture One · 按导入设置"
        case .inPlace: "Capture One · 添加到目录"
        case .lightroom: "Lightroom Classic"
        case .off: "文件夹"
        }
    }

    private var photoDetail: String? {
        switch model.captureOneMode {
        case .newSession: short(model.sessionsFolder)
        case .c1Settings, .inPlace: "Capture One 当前文档"
        case .lightroom, .off: short(model.destination)
        }
    }

    private var videoTitle: String {
        var to: [String] = []
        if model.sendToResolve, apps[.resolve]?.isInstalled == true { to.append("DaVinci Resolve") }
        if model.sendToFCP, apps[.finalCut]?.isInstalled == true { to.append("Final Cut Pro") }
        if model.sendToPremiere, apps[.premiere]?.isInstalled == true { to.append("Adobe Premiere Pro") }
        if model.sendToJianying, apps[.jianying]?.isInstalled == true { to.append("剪映专业版") }
        return to.isEmpty ? "仅存储至文件夹" : "发送至 " + to.joined(separator: "、")
    }

    /// 「~/Pictures/MiniDiT」
    private func short(_ u: URL) -> String {
        let p = u.path(percentEncoded: false), home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return p.hasPrefix(home) ? "~/" + p.dropFirst(home.count) : p
    }
}

// MARK: - 部件

enum CardIcon {
    /// 主题色的线条符号。
    case symbol(String)
    /// 保留原 Logo 轮廓的黑白版本。
    case logo(SoftwareLogoKind)
    /// 导入目标中的文件夹：黑白，光学尺寸与软件标志一致。
    case importFolder
    /// 第三方软件用它自己的图标，认得出来。
    case app(URL?)
}

/// 软件目标沿用原 Logo 的黑白轮廓，普通操作仍使用系统符号。
extension CaptureOneMode {
    var importIcon: CardIcon {
        switch self {
        case .newSession, .c1Settings, .inPlace: .logo(.captureOne)
        case .lightroom: .logo(.lightroomClassic)
        case .off: .importFolder
        }
    }
}

struct CardIconView: View {
    let icon: CardIcon
    var size: CGFloat = 32

    var body: some View {
        switch icon {
        case .logo(let kind):
            SoftwareLogo(kind: kind, size: size)
        case .importFolder:
            Image(systemName: "folder")
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.9, height: size * 0.9)
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .symbol(let s):
            Image(systemName: s).font(.system(size: size * 0.6, weight: .regular))
                .foregroundStyle(Theme.accent)
                .frame(width: size, height: size)
        case .app(let u):
            if let u {
                Image(nsImage: AppIcon.image(for: u))
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

/// 工作流程的一块：图标、名称、一句话、三条要点。
private struct ModeTile: View {
    let symbol: String
    let title: String
    let points: [String]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    CardIconView(icon: .symbol(symbol), size: 40)
                    Spacer()
                    SelectMark(selected: selected, action: action)
                }
                Text(title).font(.title3.weight(.semibold))
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
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .topLeading)
            .modifier(CardBackground(selected: selected))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 单选的一行（放在 Panel 里）：图标、标题、说明，右边开关。
private struct ChoiceCard: View {
    let icon: CardIcon
    let title: String
    var detail: String? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 14) {
                CardIconView(icon: icon, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                SelectMark(selected: selected, action: action)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 单选卡片右边的开关：和设置、向导里其他开关同一种控件。打开一个即选中这一项；已选中的不能直接关掉。
struct SelectMark: View {
    let selected: Bool
    var action: () -> Void = {}
    var body: some View {
        Toggle("", isOn: Binding(get: { selected }, set: { if $0 { action() } }))
            .labelsHidden().toggleStyle(.switch)
    }
}

private struct CardBackground: ViewModifier {
    let selected: Bool
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.border))
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
