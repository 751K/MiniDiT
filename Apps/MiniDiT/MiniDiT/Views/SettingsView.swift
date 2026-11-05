import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

/// 设置窗口：导入 / 连接 / 记录。
struct SettingsView: View {
    var body: some View {
        // 每页高度不同，切换时窗口跟着变高变矮，不留大片空白。
        TabView {
            ImportSettings().frame(width: 600, height: 560)
                .tabItem { Label("导入", systemImage: "square.and.arrow.down") }
            ConnectSettings().frame(width: 600, height: 380)
                .tabItem { Label("连接", systemImage: "camera") }
            AppsSettings().frame(width: 600, height: 480)
                .tabItem { Label("软件", systemImage: "square.grid.2x2") }
            RecordSettings().frame(width: 600, height: 250)
                .tabItem { Label("记录", systemImage: "list.bullet") }
        }
    }
}

private struct ImportSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ForEach([CaptureOneMode.newSession, .c1Settings, .inPlace, .lightroom, .off]) { m in
                    ModeRow(title: Self.title(m), detail: Self.detail(m), on: model.captureOneMode == m) {
                        model.captureOneMode = m
                    }
                }
                if model.captureOneMode == .off {
                    Picker("导入完成后打开", selection: $model.openAfterImport) {
                        ForEach(FolderApp.allCases.filter { $0.isAvailable || $0 == model.openAfterImport }) { Text($0.title).tag($0) }
                    }
                }
            } header: {
                Text("导入方式")
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
                Toggle("同时备份至备份位置", isOn: Binding(get: { model.backupEnabled && model.backupFolder != nil },
                                                    set: { model.backupEnabled = $0 }))
                    .disabled(model.backupFolder == nil)
            }
            Section("同时存在 RAW 与 JPG/HIF 时") {
                SlidingSegment(options: [("全部导入", PairPolicy.both), ("仅导入 RAW", .rawOnly), ("仅导入 JPG/HIF", .jpegOnly)],
                               selection: $model.pairPolicy, fill: true)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("配对规则")
            }
            Section {
                Toggle("删除存储卡上已导入的照片", isOn: $model.deleteAfterImport)
            } header: {
                Text("导入完成后")
            } footer: {
                Text("仅适用于读卡器，且只删除校验通过的照片。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            NamingSection()
            Section {
                Picker("按时间分场次", selection: $model.sceneGap) {
                    ForEach(SceneGapMenu.options, id: \.1) { Text($0.0).tag($0.1) }
                }
            } header: {
                Text("场次")
            } footer: {
                Text("同一天内相邻照片的间隔超过所选时间，即分为两场。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshCaptureOne() }
    }

    private var backupText: String {
        guard let u = model.backupFolder else { return "尚未设置；设置后方可为照片另存一份" }
        let p = u.path(percentEncoded: false)
        return model.backupAvailable ? p : p + "（磁盘未连接）"
    }

    private var locationText: String {
        if model.captureOneMode == .newSession {
            let explicit = UserDefaults.standard.url(forKey: "sessionsFolder") != nil
            return (explicit ? "" : "与 Capture One 当前会话相同 · ") + model.sessionsFolder.path(percentEncoded: false)
        }
        return model.destination.path(percentEncoded: false) + "，按“\(NameTemplate.current(.folder))”分目录存放"
    }

    static func title(_ m: CaptureOneMode) -> String {
        switch m {
        case .newSession: "新建会话"
        case .c1Settings: "按 Capture One 的导入设置"
        case .inPlace: "就地添加"
        case .lightroom: "导入到 Lightroom Classic"
        case .off: "只下载"
        }
    }

    static func detail(_ m: CaptureOneMode) -> String {
        switch m {
        case .newSession: "照片存入新会话的 Capture 文件夹"
        case .c1Settings: "按当前文档的导入设置处理"
        case .inPlace: "下载后直接添加到当前文档"
        case .lightroom: "下载后添加到当前目录，须安装插件"
        case .off: "仅存储至电脑，可在导入后用访达、Bridge 或 DxO 打开"
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
            Section("启动") {
                Toggle("自动连接上次使用的相机", isOn: $model.autoConnect)
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
            } footer: {
                Text("忘记后，再次连接时须重新核对指纹并填写账号。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static func when(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "今天" }
        if Calendar.current.isDateInYesterday(d) { return "昨天" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = "M月d日"
        return f.string(from: d)
    }
}

private struct RecordSettings: View {
    @Environment(AppModel.self) private var model
    @State private var confirmClear = false
    @State private var copied = false
    @State private var count = ImportHistory.shared.count

    var body: some View {
        Form {
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
                        Text("用于判断哪些照片已导入。")
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
                    Text("反馈问题时可附上。")
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// 导入方式的一行：左边对勾，标题和说明两行，整行可点。
private struct ModeRow: View {
    let title: String
    let detail: String
    let on: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                    .opacity(on ? 1 : 0).frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).fontWeight(on ? .semibold : .regular)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// 命名模板：会话、下载文件夹、备份文件夹。
private struct NamingSection: View {
    @AppStorage(NameTemplate.Kind.session.key) private var session = ""
    @AppStorage(NameTemplate.Kind.folder.key) private var folder = ""
    @AppStorage(NameTemplate.Kind.backup.key) private var backup = ""

    var body: some View {
        Section {
            field("会话", .session, $session)
            field("下载文件夹", .folder, $folder)
            field("备份文件夹", .backup, $backup)
        } header: {
            Text("命名")
        } footer: {
            Text("可用标记：{YYYY} {MM} {DD} {M} {D} {事件} {场次}。留空即恢复默认。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ title: String, _ kind: NameTemplate.Kind, _ text: Binding<String>) -> some View {
        let t = text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty ? kind.defaultValue : text.wrappedValue
        let example = NameTemplate.render(t, allowsFolders: kind.allowsFolders, day: "20261028", event: "卢森堡", scene: 2)
        return VStack(alignment: .leading, spacing: 3) {
            TextField(title, text: text, prompt: Text(kind.defaultValue))
            Text("示例：" + example).font(.caption).foregroundStyle(.secondary)
        }
    }
}
