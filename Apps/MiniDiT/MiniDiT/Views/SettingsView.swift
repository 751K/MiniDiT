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
                    ForEach([CaptureOneMode.newSession, .c1Settings, .inPlace, .off]) { m in
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
                    HStack {
                        if model.backupFolder != nil {
                            Button("不备份") { model.backupFolder = nil }
                        }
                        Button(model.backupFolder == nil ? "选择…" : "更改…") {
                            if let u = FolderPicker.choose(start: model.backupFolder) { model.backupFolder = u }
                        }
                    }
                } label: {
                    Text("备份位置（第二份）")
                    Text(backupText).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(model.backupFolder != nil && !model.backupAvailable ? .orange : .secondary)
                }
            }
            Section("同时有 RAW 和 JPG/HIF 时") {
                Picker("配对规则", selection: $model.pairPolicy) {
                    Text("都导入").tag(PairPolicy.both)
                    Text("只导 RAW").tag(PairPolicy.rawOnly)
                    Text("只导 JPG/HIF").tag(PairPolicy.jpegOnly)
                }
                .pickerStyle(.segmented).labelsHidden()
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshCaptureOne() }
    }

    private var backupText: String {
        guard let u = model.backupFolder else { return "没有设置，导入时只存一份" }
        let p = u.path(percentEncoded: false)
        return model.backupAvailable ? p + "，按「年-月-日-事件」分文件夹" : p + "（现在找不到这块盘）"
    }

    private var locationText: String {
        if model.captureOneMode == .newSession {
            let explicit = UserDefaults.standard.url(forKey: "sessionsFolder") != nil
            return (explicit ? "" : "跟随 Capture One 当前的会话 · ") + model.sessionsFolder.path(percentEncoded: false)
        }
        return model.destination.path(percentEncoded: false) + "，按「年/年-月-日」分文件夹"
    }

    static func title(_ m: CaptureOneMode) -> String {
        switch m {
        case .newSession: "新建会话"
        case .c1Settings: "按 Capture One 的导入设置"
        case .inPlace: "就地添加"
        case .off: "只下载"
        }
    }

    static func detail(_ m: CaptureOneMode) -> String {
        switch m {
        case .newSession: "每次导入新建一个会话，照片存进它的 Capture 文件夹。"
        case .c1Settings: "交给当前打开的文档，按它的导入设置处理。"
        case .inPlace: "下载到下面的位置，再直接加入当前文档。"
        case .off: "只存到电脑，不打开 Capture One。"
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
                Toggle("启动时自动连接上次的相机", isOn: $model.autoConnect)
            }
            Section {
                if model.knownCameras.isEmpty {
                    Text("还没有连过相机").foregroundStyle(.secondary)
                }
                ForEach(model.knownCameras) { cam in
                    HStack {
                        Image(systemName: "camera").foregroundStyle(.secondary)
                        VStack(alignment: .leading) {
                            Text(cam.name)
                            Text("上次连接：\(Self.when(cam.lastSeen)) · \(cam.host)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("忘记") { model.forget(cam) }
                    }
                }
            } header: {
                Text("连过的相机")
            } footer: {
                Text("忘记后，下次连接要重新核对指纹并填写账号。").font(.caption).foregroundStyle(.secondary)
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
                    Text(count > 0 ? "已记录 \(count.formatted()) 条" : "没有导入记录")
                    Text("清除后，所有照片都会重新显示为未导入。")
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
                    Text("反馈问题时可以附上这份日志。")
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
            Text("清除后，所有照片都会重新显示为未导入。已经导入的文件不会被删除。")
        }
    }
}
