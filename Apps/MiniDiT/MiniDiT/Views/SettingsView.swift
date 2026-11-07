import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

/// 设置窗口：通用 / 照片 / 视频 / 备份 / 软件。
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
                .tabItem { Label("软件", systemImage: "square.grid.2x2") }
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
            Section {
                // 和其他设置一样用系统的弹出菜单，不另做单选样式。
                Picker("导入方式", selection: $model.captureOneMode) {
                    ForEach(modes) { Text(Self.title($0)).tag($0) }
                }
            } footer: {
                if let d = model.captureOneDocument, model.captureOneMode != .off, model.captureOneMode != .lightroom {
                    Text("Capture One 当前打开：\(d.name)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("存放位置") {
                LabeledContent {
                    Button("更改…") {
                        if model.captureOneMode == .newSession { choose(\.sessionsFolder) } else { choose(\.destination) }
                    }
                } label: {
                    Text(model.captureOneMode == .newSession ? "新会话的位置" : "下载位置")
                    Text(locationText).lineLimit(1).truncationMode(.middle)
                }
                if model.captureOneMode == .off {
                    Picker("导入完成后打开", selection: $model.openAfterImport) {
                        ForEach(FolderApp.allCases.filter { $0.isAvailable || $0 == model.openAfterImport }) { Text($0.title).tag($0) }
                    }
                }
            }
            Section("同时存在 RAW 与 JPG/HIF 时") {
                SlidingSegment(options: [("全部导入", PairPolicy.both), ("仅导入 RAW", .rawOnly), ("仅导入 JPG/HIF", .jpegOnly)],
                               selection: $model.pairPolicy, fill: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("配对规则")
            }
            if !model.isPro || model.deleteAfterImport {
                Section("导入完成后") {
                    Toggle("删除存储卡上已校验的照片（仅限读卡器）", isOn: $model.deleteAfterImport)
                }
            }
            if model.isPro { NamingSection() }
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


    /// 个人模式只列常用的三种；当前用的是另外两种时也列出来。
    private var modes: [CaptureOneMode] {
        let all: [CaptureOneMode] = [.newSession, .c1Settings, .inPlace, .lightroom, .off]
        return model.isPro ? all : all.filter { [.newSession, .lightroom, .off].contains($0) || $0 == model.captureOneMode }
    }

    private var locationText: String {
        if model.captureOneMode == .newSession {
            return model.sessionsFolder.path(percentEncoded: false)
        }
        return model.destination.path(percentEncoded: false)
    }

    static func title(_ m: CaptureOneMode) -> String {
        switch m {
        case .newSession: "Capture One · 新建会话"
        case .c1Settings: "Capture One · 按导入设置"
        case .inPlace: "Capture One · 就地添加"
        case .lightroom: "Lightroom Classic"
        case .off: "仅存储至文件夹"
        }
    }

    private func choose(_ key: ReferenceWritableKeyPath<AppModel, URL>) {
        if let url = FolderPicker.choose(start: model[keyPath: key]) { model[keyPath: key] = url }
    }
}

private struct ConnectSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            UsageSection()
            Section {
                Toggle("自动连接上次使用的相机", isOn: $model.autoConnect)
                Toggle("登录时打开 MiniDiT", isOn: $model.launchAtLogin)
                Toggle("关闭窗口后保留在菜单栏", isOn: $model.keepInMenuBar)
                Toggle("连接过的相机开机时发送通知", isOn: $model.notifyCameraOnline)
                if !model.isPro || model.autoImportCamera {
                    Toggle("连接过的相机开机后自动导入新照片", isOn: $model.autoImportCamera)
                        .disabled(!model.notifyCameraOnline)
                }
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
                            Text(cam.name)
                            Text("上次连接：\(Self.when(cam.lastSeen)) · \(cam.host)").font(.caption).foregroundStyle(.secondary)
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
        if Calendar.current.isDateInToday(d) { return "今天" }
        if Calendar.current.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}

/// 设置 › 通用 最上面：使用方式、重新打开设置向导。
private struct UsageSection: View {
    @Environment(AppModel.self) private var model
    @State private var pending: UsageMode?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            Picker("使用方式", selection: Binding(get: { model.usageMode }, set: { if $0 != model.usageMode { pending = $0 } })) {
                ForEach(UsageMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
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
        } header: {
            Text("使用方式")
        }
        .confirmationDialog("按“\(pending?.title ?? "")”模式重设默认值？", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { m in
            Button("重设默认值") { model.usageMode = m; model.applyModeDefaults() }
            Button("只更改显示的选项") { model.usageMode = m }
            Button("取消", role: .cancel) {}
        } message: { m in
            Text(m == .pro
                 ? "视频文件夹改为按卷号分子文件夹，并关闭自动导入和导入后删除存储卡上的照片。其他设置不变。"
                 : "视频文件夹不再按卷号分子文件夹。其他设置不变。")
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

/// 视频：存放位置和文件夹命名、代理、导完交给剪辑软件。
private struct VideoSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NameTemplate.Kind.video.key) private var template = ""

    var body: some View {
        @Bindable var model = model
        let t = template.trimmingCharacters(in: .whitespaces).isEmpty ? NameTemplate.Kind.video.defaultValue : template
        let example = NameTemplate.render(t, allowsFolders: true, day: "20261021", event: "采访", scene: nil, roll: "A001")
        let resolve = ResolveBridge.appURL != nil, fcp = FCPXMLWriter.appURL != nil
        Form {
            Section {
                LabeledContent {
                    Button("更改…") {
                        if let u = FolderPicker.choose(start: model.videoDestination) { model.videoDestination = u }
                    }
                } label: {
                    Text("保存位置")
                    Text(model.videoDestination.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                }
                if model.isPro {
                    VStack(alignment: .leading, spacing: 3) {
                        TextField("文件夹", text: $template, prompt: Text(NameTemplate.Kind.video.defaultValue))
                        Text("示例：\(example)/C0001.MP4").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("存放")
            }
            Section {
                Toggle("同时导入代理文件", isOn: $model.importProxies)
                Toggle("通过 Wi-Fi 导入时仅导入代理", isOn: $model.proxyOnlyWiFi)
            } header: {
                Text("代理")
            }
            Section {
                if resolve {
                    Toggle(isOn: $model.sendToResolve) {
                        Text("添加至 DaVinci Resolve 当前项目")
                        Text("需在 Resolve 中将“外部脚本使用”设为“本地”。")
                    }
                    if model.isPro {
                        Toggle(isOn: $model.resolveColorSpace) {
                            Text("设置片段的输入色彩空间")
                            Text("需开启色彩管理（RCM 或 ACES）。")
                        }
                        .padding(.leading, 16)
                        .disabled(!model.sendToResolve)
                    }
                }
                if fcp {
                    Toggle("发送至 Final Cut Pro", isOn: $model.sendToFCP)
                    if model.isPro {
                        Toggle("设置片段的 Log 处理", isOn: $model.fcpLogProcessing)
                        .padding(.leading, 16)
                        .disabled(!model.sendToFCP)
                    }
                }
                if !resolve && !fcp {
                    Text("未找到 DaVinci Resolve 或 Final Cut Pro。").foregroundStyle(.secondary)
                }
            } header: {
                Text("导入完成后")
            }
        }
        .formStyle(.grouped)
    }
}

/// 备份：第二份放在哪、要不要备份、备份文件夹怎么命名。照片和视频都备份。
private struct BackupSettings: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NameTemplate.Kind.backup.key) private var backup = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                LabeledContent {
                    Button(model.backupFolder == nil ? "选择…" : "更改…") {
                        if let u = FolderPicker.choose(start: model.backupFolder) { model.backupFolder = u }
                    }
                } label: {
                    Text("备份位置")
                    Text(backupText).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.backupFolder != nil && !model.backupAvailable ? .orange : .secondary)
                }
                // 没设置备份位置时显示为关，设置后恢复原来的选择。
                Toggle("导入时同时备份", isOn: Binding(get: { model.backupEnabled && model.backupFolder != nil },
                                                 set: { model.backupEnabled = $0 }))
                    .disabled(model.backupFolder == nil)
                if model.isPro { NameField(title: "备份文件夹", kind: .backup, text: $backup) }
            }
        }
        .formStyle(.grouped)
    }

    private var backupText: String {
        guard let u = model.backupFolder else { return "尚未设置" }
        let p = u.path(percentEncoded: false)
        return model.backupAvailable ? p : p + "（磁盘未连接）"
    }
}

/// 命名模板：会话、下载文件夹（备份文件夹在“备份”里）。
private struct NamingSection: View {
    @AppStorage(NameTemplate.Kind.session.key) private var session = ""
    @AppStorage(NameTemplate.Kind.folder.key) private var folder = ""

    var body: some View {
        Section {
            NameField(title: "会话", kind: .session, text: $session)
            NameField(title: "下载文件夹", kind: .folder, text: $folder)
        } header: {
            Text("命名")
        } footer: {
            Text("可用标记：{YYYY} {MM} {DD} {M} {D} {事件} {场次}。留空即恢复默认。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 一个命名模板：输入框和示例。
private struct NameField: View {
    let title: String
    let kind: NameTemplate.Kind
    @Binding var text: String

    var body: some View {
        let t = text.trimmingCharacters(in: .whitespaces).isEmpty ? kind.defaultValue : text
        let example = NameTemplate.render(t, allowsFolders: kind.allowsFolders, day: "20261028", event: "卢森堡", scene: 2)
        VStack(alignment: .leading, spacing: 3) {
            TextField(title, text: $text, prompt: Text(kind.defaultValue))
            Text("示例：" + example).font(.caption).foregroundStyle(.secondary)
        }
    }
}
