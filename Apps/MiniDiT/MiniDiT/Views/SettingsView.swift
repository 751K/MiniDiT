import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

/// 设置窗口：导入 / 连接 / 记录。
struct SettingsView: View {
    var body: some View {
        TabView {
            ImportSettings().tabItem { Label("导入", systemImage: "square.and.arrow.down") }
            ConnectSettings().tabItem { Label("相机", systemImage: "camera") }
            AppsSettings().tabItem { Label("软件", systemImage: "square.grid.2x2") }
            RecordSettings().tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
        }
        .frame(width: 560, height: 560)
    }
}

private struct ImportSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("导入方式") {
                Picker("导入方式", selection: $model.captureOneMode) {
                    ForEach([CaptureOneMode.newSession, .c1Settings, .inPlace, .lightroom, .off]) { m in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(Self.title(m))
                            Text(Self.detail(m)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(m)
                    }
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if let d = model.captureOneDocument {
                    Text("Capture One 当前打开的文档：\(d.name)").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("存储位置") {
                LabeledContent {
                    Button("更改…") {
                        if model.captureOneMode == .newSession { choose(\.sessionsFolder) } else { choose(\.destination) }
                    }
                } label: {
                    Text(model.captureOneMode == .newSession ? "新会话位置" : "下载位置")
                    Text(locationText).lineLimit(1).truncationMode(.middle)
                }
            }
            Section {
                Toggle("同时备份至另一磁盘", isOn: $model.backupEnabled)
                if model.backupEnabled {
                    LabeledContent {
                        Button(model.backupFolder == nil ? "选择…" : "更改…") {
                            if let u = FolderPicker.choose(start: model.backupFolder) { model.backupFolder = u }
                        }
                    } label: {
                        Text("备份位置")
                        Text(backupText).lineLimit(1).truncationMode(.middle)
                            .foregroundStyle(model.backupFolder == nil || !model.backupAvailable ? .orange : .secondary)
                    }
                }
            } header: {
                Text("备份")
            } footer: {
                Text("两份文件均以 xxHash64 校验，校验一致后方视为导入完成。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("删除存储卡上已导入的照片", isOn: $model.deleteAfterImport)
            } header: {
                Text("导入完成后")
            } footer: {
                Text("仅删除校验通过的照片；启用备份时，须两份均校验通过。视频文件不予删除。此项仅适用于读卡器。")
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
                Text("默认不分场次。选择间隔后，同一天内相邻两张照片的拍摄时间间隔超过所选值，即划分为两场，可按场次查看、选择和导入。也可在侧栏的日期上右键设置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("同时存在 RAW 与 JPG/HIF 时") {
                Picker("配对规则", selection: $model.pairPolicy) {
                    Text("全部导入").tag(PairPolicy.both)
                    Text("仅导入 RAW").tag(PairPolicy.rawOnly)
                    Text("仅导入 JPG/HIF").tag(PairPolicy.jpegOnly)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshCaptureOne() }
    }

    private var backupText: String {
        guard let u = model.backupFolder else { return "尚未选择" }
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
        case .newSession: "每次导入时新建会话，照片存入该会话的 Capture 文件夹。"
        case .c1Settings: "交由当前打开的文档，按其导入设置处理。"
        case .inPlace: "下载至下方的存储位置，再直接添加到当前文档。"
        case .lightroom: "下载至下方的存储位置，再由 MiniDiT 插件添加到 Lightroom Classic 当前目录，每次导入时新建收藏夹（须在“软件”中安装插件）。"
        case .off: "仅存储至电脑，不使用 Capture One。"
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
            Section {
                Toggle("启动时自动连接上次使用的相机", isOn: $model.autoConnect)
            }
            Section {
                if model.knownCameras.isEmpty {
                    Text("尚未连接过相机").foregroundStyle(.secondary)
                }
                ForEach(model.knownCameras) { cam in
                    HStack {
                        Image(systemName: "camera").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(cam.name)
                            Text("上次连接：\(Self.when(cam.lastSeen)) · \(cam.host)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("移除") { model.forget(cam) }
                    }
                }
            } header: {
                Text("已连接过的相机")
            } footer: {
                Text("移除后，再次连接时须重新核对指纹并输入账户信息。").font(.caption).foregroundStyle(.secondary)
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
                LabeledContent {
                    Button("清除记录…") { confirmClear = true }.disabled(count == 0)
                } label: {
                    Text(count > 0 ? "已记录 \(count.formatted()) 条" : "无导入记录")
                    Text("清除后，所有照片将重新显示为未导入。")
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
                    Text("反馈问题时可附上此日志。")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("清除全部 \(count) 条导入记录？", isPresented: $confirmClear) {
            Button("清除", role: .destructive) {
                ImportHistory.shared.clear()
                model.rebuild()
                count = 0
            }
        } message: {
            Text("清除后，所有照片将重新显示为未导入。已导入的文件不会被删除。")
        }
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
            Text("可用标记：{YYYY} 年，{MM} {DD} 两位月日，{M} {D} 不补零的月日，{事件}，{场次}。未填写的标记自动省略；仅下载文件夹可用“/”分层。留空即恢复默认。")
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
