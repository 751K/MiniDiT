import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置窗口：通用 / 照片 / 视频 / 备份 / 连接。
struct SettingsView: View {
    var body: some View {
        // 各页同一尺寸：高度不同时，切换标签会让窗口改变大小，标题栏和工具栏随之闪一下。
        TabView {
            ConnectSettings()
                .clipped()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ImportSettings()
                .clipped()
                .tabItem { Label("照片", systemImage: "photo") }
            VideoSettings()
                .clipped()
                .tabItem { Label("视频", systemImage: "video") }
            BackupSettings()
                .clipped()
                .tabItem { Label("备份", systemImage: "externaldrive") }
            AppsSettings()
                .clipped()
                .tabItem { Label("连接", systemImage: "square.grid.2x2") }
        }
        .frame(width: 600, height: 560)
        // 标签栏没有底色，内容滚上去会和标签叠在一起；各页裁在标签栏下方。
        .hiddenToolbarBackground()
    }
}

private extension View {
    /// 顶部标签栏不用系统工具栏的浅色底和分隔线，和下面的内容同一底色（macOS 15 起）。
    @ViewBuilder func hiddenToolbarBackground() -> some View {
        if #available(macOS 15.0, *) {
            toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}

private struct ImportSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("默认存储地址") {
                LabeledContent {
                    Button("更改…") {
                        if model.captureOneMode == .newSession { choose(\.sessionsFolder) } else { choose(\.destination) }
                    }
                } label: {
                    Text(locationText).lineLimit(1).truncationMode(.middle).help(locationText)
                }
                if model.captureOneMode == .off {
                    Picker("导入完成后打开", selection: $model.openAfterImport) {
                        ForEach(FolderApp.allCases.filter { $0.isAvailable || $0 == model.openAfterImport }) { Text($0.title).tag($0) }
                    }
                }
            }
            Section("整理方式") {
                if model.captureOneMode == .newSession {
                    Text("照片存入同名 Capture One 会话的 Capture 文件夹。")
                        .foregroundStyle(.secondary)
                } else {
                    MediaOrganizationOptions(video: false)
                }
            }
            Section {
                ModeRow(title: "文件夹", on: model.captureOneMode == .off) {
                    model.captureOneMode = .off
                }
                ModeRow(title: "Capture One", on: isC1) {
                    if !isC1 { model.captureOneMode = .newSession }
                }
                if isC1 {
                    CaptureOneImportOptions().padding(.leading, 16)
                }
                ModeRow(title: "Lightroom Classic", on: model.captureOneMode == .lightroom) {
                    model.captureOneMode = .lightroom
                }
            } header: {
                Text("导入至")
            } footer: {
                if let d = model.captureOneDocument, isC1 {
                    Text("Capture One 当前打开：\(d.name)").font(.caption).foregroundStyle(.secondary)
                }
            }
            PhotoLookSettings()
            Section("导入完成后") {
                Toggle("删除存储卡上已校验的照片（仅限读卡器）", isOn: $model.deleteAfterImport)
            }
            Section {
                Picker("按时间分场次", selection: $model.sceneGap) {
                    ForEach(SceneGapMenu.options, id: \.1) { Text($0.0).tag($0.1) }
                }
            } header: {
                Text("场次")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            model.refreshCaptureOne()
        }
    }

    private var isC1: Bool { [.newSession, .c1Settings, .inPlace].contains(model.captureOneMode) }

    private var locationText: String {
        if model.captureOneMode == .newSession {
            return model.sessionsFolder.path(percentEncoded: false)
        }
        return model.destination.path(percentEncoded: false)
    }

    private func choose(_ key: ReferenceWritableKeyPath<AppModel, URL>) {
        if let url = FolderPicker.choose(start: model[keyPath: key]) { model[keyPath: key] = url }
    }
}

/// Capture One 是一个导入目标；三种处理方式在选中它后呈现。
struct CaptureOneImportOptions: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Picker("处理方式", selection: $model.captureOneMode) {
            Text("新建会话").tag(CaptureOneMode.newSession)
            Text("按 Capture One 导入设置").tag(CaptureOneMode.c1Settings)
            Text("添加到目录，不复制文件").tag(CaptureOneMode.inPlace)
        }
        .pickerStyle(.menu)
    }
}

private struct ConnectSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            UsageSection()
            SessionNamingSection()
            Section {
                Toggle("自动连接上次使用的相机", isOn: $model.autoConnect)
                Toggle("浏览时自动刷新新照片和视频", isOn: $model.autoRefresh)
                    .help("窗口在前台时每 15 秒检查一次；导入、拖动选择和预览期间暂缓刷新。")
                Toggle("登录时打开 MiniDiT", isOn: $model.launchAtLogin)
                Toggle("关闭窗口后保留在菜单栏", isOn: $model.keepInMenuBar)
                AutomaticUpdatesToggle()
                Toggle("连接过的相机开机时发送通知", isOn: $model.notifyCameraOnline)
                Toggle("连接过的相机开机后自动导入新照片", isOn: $model.autoImportCamera)
                    .disabled(!model.notifyCameraOnline)
                if model.notificationsAllowed == false, model.notifyCameraOnline || model.cardInsertAction == .notify {
                    HStack {
                        Label("系统设置中已关闭 MiniDiT 的通知，将无法收到提醒。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("打开通知设置…") { Notifier.openSystemSettings() }
                    }
                    .font(.callout)
                }
                Picker("插入相机存储卡时", selection: $model.cardInsertAction) {
                    ForEach(CardInsertAction.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("启动与后台")
            }
            Section {
                if model.knownCameras.isEmpty {
                    Text("尚未连接过相机").foregroundStyle(.secondary)
                }
                ForEach(model.knownCameras) { cam in
                    HStack {
                        Image(systemName: "camera")
                        VStack(alignment: .leading) {
                            Text(cam.displayName)
                            Text("上次连接：\(Self.when(cam.lastSeen)) · \(cam.host)").font(Theme.Font.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("忘记") { model.forget(cam) }
                    }
                }
            } header: {
                Text("已连接过的相机")
            }
            RecordSections()
        }
        .formStyle(.grouped)
        .onAppear { Notifier.shared.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Notifier.shared.refreshPermission()
        }
    }

    static func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return String(localized: "今天") }
        if Calendar.current.isDateInYesterday(d) { return String(localized: "昨天") }
        let f = DateFormatter(); f.locale = .app; f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: d)
    }
}

/// 设置 › 通用 最上面：工作流程、重新打开设置向导。
private struct UsageSection: View {
    @Environment(AppModel.self) private var model
    @State private var pending: UsageMode?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var model = model
        Section {
            LabeledContent("工作流程") {
                SegmentPicker(options: UsageMode.allCases.map { .init(title: $0.title, value: $0) },
                             selection: Binding(get: { model.usageMode }, set: { if $0 != model.usageMode { pending = $0 } }))
            }
            LabeledContent {
                // 向导比设置窗口宽，放到主窗口里显示，并关掉设置窗口。
                Button("打开…") {
                    NSApp.keyWindow?.close()
                    openWindow(id: "main")
                    NSApp.activate()
                    model.showingSetup = true
                }
            } label: {
                Text("设置向导")
            }
        }
        .confirmationDialog("切换为“\(pending?.title ?? "")”工作流程？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { m in
            Button("应用推荐设置") { model.usageMode = m; model.applyModeDefaults() }
            Button("保留当前设置") { model.usageMode = m }
            Button("取消", role: .cancel) {}
        } message: { m in
            Text(m == .team
                 ? "推荐按卷号整理视频、手动导入并保留原卡。应用推荐设置会关闭自动导入和导入后删除，仅在未自定义命名时调整视频文件夹。两种流程都可以使用所有功能。"
                 : "推荐按日期、事件整理视频。应用推荐设置只会将团队默认的视频文件夹恢复为按事件整理，保留自定义命名和其他选项。两种流程都可以使用所有功能。")
        }
    }
}

private struct RecordSections: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var copied = false
    @State private var count = ImportHistory.shared.count

    var body: some View {
        Group {
            Section("导入记录") {
                if confirmClear {
                    // 就地确认，不另弹窗。
                    LabeledContent {
                        HStack(spacing: 6) {
                            Button("取消") { confirmClear = false }
                            Button("清除", role: .destructive) {
                                ImportHistory.shared.clear()
                                model.rebuild()
                                count = 0
                                confirmClear = false
                            }
                            .foregroundStyle(.red)
                        }
                    } label: {
                        Text("清除全部导入记录？").fontWeight(.semibold)
                        Text("所有照片将重新显示为未导入，已下载的文件不受影响。")
                    }
                } else {
                    LabeledContent {
                        Button("清除…") { confirmClear = true }.disabled(count == 0)
                    } label: {
                        Text(count > 0 ? "已记录 \(count.formatted()) 条" : "无导入记录")
                    }
                }
            }
            Section("诊断") {
                LabeledContent {
                    Button(copied ? "已复制" : "复制日志") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("MiniDiT 诊断日志\n网络：\(CameraFinder.networkSummary())\n\(AppLog.shared.text)", forType: .string)
                        copied = true
                    }
                } label: {
                    Text("诊断日志")
                }
            }
        }
    }
}

/// 导入目标的一行：名称与系统开关。几行之间互斥，打开一个即关闭其他，
/// 已打开的那一行不能直接关掉（总得有一种导入方式）。
private struct ModeRow: View {
    let title: LocalizedStringKey
    let on: Bool
    let action: () -> Void

    var body: some View {
        // 用 Form 自带的开关行（左边标签、右边开关），和其他设置项完全同一种控件。
        Toggle(title, isOn: Binding(get: { on }, set: { if $0 { action() } }))
    }
}

/// 视频：导入目标、存放位置和文件夹命名、代理。
private struct VideoSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let resolve = ResolveBridge.appURL != nil, fcp = FCPXMLWriter.appURL != nil, premiere = PremiereBridge.app.isInstalled
        let jianying = NSWorkspace.shared.urlForApplication(withBundleIdentifier: JianyingDraft.bundleID) != nil
        Form {
            Section {
                LabeledContent {
                    Button("更改…") {
                        if let u = FolderPicker.choose(start: model.videoDestination) { model.videoDestination = u }
                    }
                } label: {
                    let path = model.videoDestination.path(percentEncoded: false)
                    Text(path).lineLimit(1).truncationMode(.middle).help(path)
                }
            } header: {
                Text("默认存储地址")
            }
            Section("整理方式") {
                MediaOrganizationOptions(video: true)
            }
            Section {
                Toggle("文件夹", isOn: Binding(
                    get: { !model.sendToResolve && !model.sendToFCP && !model.sendToPremiere && !model.sendToJianying },
                    set: { folderOnly in
                        if folderOnly {
                            model.sendToResolve = false
                            model.sendToFCP = false
                            model.sendToPremiere = false
                            model.sendToJianying = false
                        }
                    }
                ))
                if resolve {
                    ResolveImportToggle(title: "DaVinci Resolve")
                    if model.sendToResolve {
                        Toggle(isOn: $model.resolveColorSpace) {
                        Text("设置片段的输入色彩空间")
                        Text("需开启色彩管理（RCM 或 ACES）。")
                    }
                    .padding(.leading, 16)
                    }
                }
                if fcp {
                    Toggle("Final Cut Pro", isOn: $model.sendToFCP)
                    if model.sendToFCP {
                        FCPTargetOptions().padding(.leading, 16)
                        Toggle("设置片段的 Log 处理", isOn: $model.fcpLogProcessing)
                    .padding(.leading, 16)
                    }
                }
                if premiere { PremiereImportToggle() }
                if jianying { JianyingImportToggle(title: "剪映专业版") }
                if !resolve && !fcp && !premiere && !jianying {
                    Text("未找到已支持的视频后期软件。").foregroundStyle(.secondary)
                }
            } header: {
                Text("导入至")
            }
            Section {
                Toggle("导入原片时，一并导入代理", isOn: $model.importProxies)
                Toggle("通过 Wi-Fi 导入时，仅导入代理", isOn: $model.proxyOnlyWiFi)
            } header: {
                Text("代理")
            }
        }
        .formStyle(.grouped)
    }
}

/// Explain Resolve's prerequisite when the user enables it, rather than on every visit.
struct ResolveImportToggle: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    @State private var showingSetupHint = false

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { model.sendToResolve },
            set: { enabled in
                let wasEnabled = model.sendToResolve
                model.sendToResolve = enabled
                if enabled && !wasEnabled { showingSetupHint = true }
            }
        ))
        .alert("启用 DaVinci Resolve 导入", isPresented: $showingSetupHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("导入完成后，视频将加入与 MiniDiT 项目同名的 Resolve 项目；该项目不存在时将自动新建。切换项目前，将先保存 Resolve 当前打开的项目。\n\n请在 DaVinci Resolve 偏好设置中将“外部脚本使用”设为“本地”。")
        }
    }
}

/// 多个备份位置的启用、整理与完成要求。
struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NameTemplate.Kind.backup.key) private var backup = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack {
                    Text("导入时同时备份")
                    Spacer()
                    BackupSettingsSwitch(title: "导入时同时备份", isOn: $model.backupEnabled)
                }
            }
            Section("备份位置") {
                BackupTargetsEditor()
            }
            Section("整理方式") {
                HStack {
                    Text("沿用照片和视频的目录规则")
                    Spacer()
                    BackupSettingsSwitch(title: "沿用照片和视频的目录规则", isOn: $model.backupFollowsOrganization)
                }
                if !model.backupFollowsOrganization {
                    DisclosureGroup("自定义备份命名") {
                        NameField(title: "备份文件夹", kind: .backup, text: $backup)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }


}

/// Project naming is a default for new projects, independent of storage layouts.
struct SessionNamingSection: View {
    @AppStorage(NameTemplate.Kind.session.key) private var session = ""
    @State private var showingTokens = false
    @State private var editingCustom = false

    private enum NamingStyle: String, CaseIterable, Identifiable {
        case dateEvent, fullDateEvent, dateOnly, custom
        var id: Self { self }
        var title: String {
            switch self {
            case .dateEvent: String(localized: "日期 + 事件")
            case .fullDateEvent: String(localized: "完整日期 + 事件")
            case .dateOnly: String(localized: "仅日期")
            case .custom: String(localized: "自定义…")
            }
        }
        var rule: String? {
            switch self {
            case .dateEvent: NameTemplate.Kind.session.defaultValue
            case .fullDateEvent: NameTemplate.localized("{YYYY}-{MM}-{DD}-{事件}")
            case .dateOnly: "{YYYY}-{MM}-{DD}"
            case .custom: nil
            }
        }
        static func matching(_ value: String) -> Self {
            let clean = value.trimmingCharacters(in: .whitespaces)
            if clean.isEmpty { return .dateEvent }
            return allCases.first { $0.rule.map { NameTemplate.same(clean, $0) } ?? false } ?? .custom
        }
    }
    private var namingStyle: Binding<NamingStyle> {
        Binding(get: { editingCustom ? .custom : NamingStyle.matching(session) }, set: { choice in
            editingCustom = choice == .custom
            if let rule = choice.rule { session = rule }
        })
    }

    private var example: String {
        let rule = session.trimmingCharacters(in: .whitespaces).isEmpty ? NameTemplate.Kind.session.defaultValue : session
        return NameTemplate.render(rule, allowsFolders: false, day: "20261028", event: String(localized: "卢森堡"), scene: nil)
    }

    var body: some View {
        Section("项目") {
            Picker("默认名称", selection: namingStyle) {
                ForEach(NamingStyle.allCases) { style in Text(style.title).tag(style) }
            }
            .help("仅用于新建项目，不修改已有项目名称或文件位置。")
            if namingStyle.wrappedValue == .custom {
                HStack {
                    Text("自定义规则")
                    Spacer()
                    TextField("", text: $session, prompt: Text(NameTemplate.Kind.session.defaultValue))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                        .accessibilityLabel("自定义项目名称规则")
                }
            }
            HStack(spacing: 8) {
                Text("名称示例").foregroundStyle(.secondary)
                Spacer()
                Text(example).textSelection(.enabled)
                if namingStyle.wrappedValue == .custom {
                    Button("可用标记…") { showingTokens = true }
                        .buttonStyle(.borderless)
                        .popover(isPresented: $showingTokens, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 14) {
                                Text("可用标记").font(Theme.Font.headline)
                                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                                    token("{YYYY}", detail: "年份，如 2026")
                                    token("{MM} / {DD}", detail: "两位月、日，如 01、09")
                                    token("{M} / {D}", detail: "月、日，如 1、9")
                                    token(NameTemplate.Token.event.localized, detail: "新建项目时填写的事件")
                                }
                                Text("仅影响新建项目的默认名称。")
                                    .font(Theme.Font.caption).foregroundStyle(.secondary)
                            }
                            .font(Theme.Font.body).padding(20)
                        }
                }
            }
        }
    }

    private func token(_ name: String, detail: LocalizedStringKey) -> some View {
        GridRow {
            Text(name).monospaced()
            Text(detail).foregroundStyle(.secondary)
        }
    }
}

/// 照片、视频各自的整理偏好；在设置与首次向导中使用相同控件。
struct MediaOrganizationOptions: View {
    @Environment(AppModel.self) private var model
    let video: Bool
    @AppStorage("template.folder") private var photoTemplate = ""
    @AppStorage("template.video") private var videoTemplate = ""

    private var layout: ImportFolderLayout { video ? model.videoFolderLayout : model.photoFolderLayout }
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Picker("文件夹", selection: video ? $model.videoFolderLayout : $model.photoFolderLayout) {
                ForEach(ImportFolderLayout.allCases) { Text($0.title).tag($0) }
            }
            if layout == .custom {
                DisclosureGroup("自定义命名规则") {
                    NameField(title: "规则", kind: video ? .video : .folder,
                              text: video ? $videoTemplate : $photoTemplate)
                    Text("支持 / 分层；日期取自素材拍摄日。项目名称不受此规则影响。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if video {
                Divider()
                if layout == .custom, NameTemplate.uses(.roll, in: NameTemplate.current(.video)) {
                    Text("自定义规则已包含卷号，将按该规则分文件夹。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Toggle("按照卷号整理", isOn: $model.splitVideoByRoll)
                }
            }
        }
    }
}

struct ImportDestinationPreview: View {
    @Environment(AppModel.self) private var model
    let files: [CameraContentItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本次存放位置").font(.headline)
            if let project = model.currentSession {
                Text("项目：\(project.name)").foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(paths.enumerated()), id: \.offset) { _, row in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(row.0).fontWeight(.medium)
                                Text(row.1.path(percentEncoded: false))
                                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 320)
                if needsRoll, files.contains(where: { $0.kind == .video }) {
                    Text("“〈卷号〉”在开始导入时分配；已有卷号会沿用。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("请先选择或新建项目").foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: model.currentSession == nil ? nil : 420, alignment: .leading)
        .fixedSize(horizontal: model.currentSession == nil, vertical: false)
    }

    private var needsRoll: Bool {
        model.splitVideoByRoll || (model.videoFolderLayout == .custom && NameTemplate.uses(.roll, in: NameTemplate.current(.video)))
    }

    private var paths: [(String, URL)] {
        var result: [(String, URL)] = []
        var seen = Set<String>()
        for item in files {
            let video = item.kind == .video
            let roll = video && needsRoll ? (RollStore.shared.roll(of: item) ?? String(localized: "〈卷号〉")) : nil
            let primary = model.plannedFolder(for: item, roll: roll)
            let key = (video ? "video:" : "photo:") + primary.path
            guard seen.insert(key).inserted else { continue }
            result.append((video ? String(localized: "视频") : String(localized: "照片"), primary))
            if model.backupEnabled {
                for target in model.enabledBackupTargets {
                    let root = target.root
                    let backup: URL
                    if model.backupFollowsOrganization {
                        let primaryRoot = video ? model.videoDestination :
                            (model.captureOneMode == .newSession ? model.sessionsFolder : model.destination)
                        backup = ImportOrganization.mirroredBackup(root: root, primaryFolder: primary,
                                                                   primaryRoot: primaryRoot, video: video)
                    } else {
                        var custom = FileImporter.backupFolder(for: item, root: root, event: model.currentSession?.event)
                        if video { custom = ProjectMedia.videos.folder(in: custom) }
                        if let source = model.sourceFolder(for: item, in: model.sourceFolders()) {
                            custom.append(path: source, directoryHint: .isDirectory)
                        }
                        backup = custom
                    }
                    result.append((video ? String(localized: "\(target.name) · 视频") : String(localized: "\(target.name) · 照片"), backup))
                }
            }
            if seen.count == 8 { break }
        }
        return result
    }
}

/// 一个命名模板：输入框和示例。
private struct NameField: View {
    let title: LocalizedStringKey
    let kind: NameTemplate.Kind
    @Binding var text: String

    var body: some View {
        let t = text.trimmingCharacters(in: .whitespaces).isEmpty ? kind.defaultValue : text
        let example = NameTemplate.render(t, allowsFolders: kind.allowsFolders, day: "20261028", event: String(localized: "卢森堡"), scene: 2)
        VStack(alignment: .leading, spacing: 3) {
            TextField(title, text: $text, prompt: Text(kind.defaultValue))
            Text("示例：\(example)").font(.caption).foregroundStyle(.secondary)
        }
    }
}


/// MiniDiT 项目在 FCP 里作为资源库还是事件；作为事件时选放进哪个资源库。
struct FCPTargetOptions: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            Picker("MiniDiT 项目作为", selection: $model.fcpProjectAs) {
                ForEach(FCPXMLWriter.ProjectMapping.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            if model.fcpProjectAs == .event {
                LabeledContent {
                    Menu("选择…") {
                        Button("已有资源库…") { openExisting() }
                        Button("新建资源库…") { createNew() }
                    }
                    .fixedSize()
                } label: {
                    let path = model.fcpEventLibrary.path(percentEncoded: false)
                    Text(path).lineLimit(1).truncationMode(.middle).help(path)
                }
            }
        }
    }
    private var libraryType: UTType { UTType(filenameExtension: "fcpbundle", conformingTo: .package) ?? .package }
    private func openExisting() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "选择资源库"); panel.prompt = String(localized: "选择")
        panel.allowedContentTypes = [libraryType]
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = model.fcpEventLibrary.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url, url.pathExtension == "fcpbundle" else { return }
        model.fcpEventLibrary = url
    }
    /// 只定下位置和名字，第一次发送时由 FCP 新建。
    private func createNew() {
        let panel = NSSavePanel()
        panel.title = String(localized: "新建资源库"); panel.prompt = String(localized: "选择"); panel.nameFieldLabel = String(localized: "资源库：")
        panel.allowedContentTypes = [libraryType]
        panel.directoryURL = model.fcpEventLibrary.deletingLastPathComponent()
        panel.nameFieldStringValue = "MiniDiT"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.fcpEventLibrary = url.pathExtension == "fcpbundle" ? url : url.appendingPathExtension("fcpbundle")
    }
}

struct PremiereImportToggle: View {
    @Environment(AppModel.self) private var model
    @State private var showingHint = false
    var body: some View {
        Toggle("Adobe Premiere Pro", isOn: Binding(
            get: { model.sendToPremiere },
            set: { enabled in
                let previous = model.sendToPremiere; model.sendToPremiere = enabled
                if enabled && !previous { showingHint = true }
            }
        ))
        .alert("启用 Premiere Pro 导入", isPresented: $showingHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("导入完成后，视频将加入与 MiniDiT 项目同名的 Premiere Pro 项目；该项目不存在时将在“影片”文件夹中新建。\n\n使用前，请在“设置 › 连接”中安装 MiniDiT 插件，并在 Premiere Pro 的“窗口 › UXP 插件”中打开 MiniDiT 面板。")
        }
    }
}

/// 剪映没有脚本接口：通过草稿文件交接，打开开关时说明一次。
struct JianyingImportToggle: View {
    @Environment(AppModel.self) private var model
    let title: LocalizedStringKey
    @State private var showingHint = false
    var body: some View {
        Toggle(title, isOn: Binding(
            get: { model.sendToJianying },
            set: { enabled in
                let previous = model.sendToJianying; model.sendToJianying = enabled
                if enabled && !previous { showingHint = true }
            }
        ))
        .alert("启用剪映专业版", isPresented: $showingHint) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("导入完成后，视频将加入与 MiniDiT 项目同名的剪映草稿素材区；该草稿不存在时将自动新建。草稿一经在剪映中打开，即由剪映加密，此后 MiniDiT 无法再向其中加入素材，需在剪映中手动导入。\n\n草稿保存于剪映的默认草稿位置。如已在剪映中更改草稿位置，请恢复为默认位置。")
        }
    }
}
