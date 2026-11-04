import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var copied = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section("连接") {
                Toggle("启动时自动连接上次的相机", isOn: $model.autoConnect)
            }
            Section("Capture One 会话") {
                HStack {
                    Text("新会话放在：" + model.sessionsFolder.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择…") { chooseFolder(\.sessionsFolder) }
                }
                Text("「新建 C1 会话」模式下，每次导入新建一个会话（名字默认是「月.日-」，后面补上内容），照片直接下载到会话的 Capture 文件夹。也可以选加入已有的会话。没设置过位置时，跟 C1 当前打开的会话放在同一个文件夹。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("保存位置（其他模式）") {
                HStack {
                    Text(model.destination.path(percentEncoded: false)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("选择…") { chooseFolder(\.destination) }
                }
                Text("按拍摄日期分文件夹：年/年-月-日。文件夹里已有同名同大小的文件时不会重复下载。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Capture One") {
                Picker("下载后", selection: $model.captureOneMode) {
                    ForEach(CaptureOneMode.allCases) { Text($0.title).tag($0) }
                }
                Text("导入到 Capture One 当前打开的目录或会话。「按导入设置」会沿用 C1 里的导入目标、命名和风格；如果 C1 设置的是复制到别处，文件会再复制一份。「就地添加」只对目录有效，文件留在上面的保存位置。")
                    .font(.caption).foregroundStyle(.secondary)
                if let d = model.captureOneDocument {
                    LabeledContent("当前文档", value: "\(d.kind)「\(d.name)」")
                }
                Button("刷新 Capture One 状态") { model.refreshCaptureOne() }
            }
            Section("RAW + JPEG") {
                Picker("同一张同时有 RAW 和 JPEG/HEIF 时", selection: $model.pairPolicy) {
                    ForEach(PairPolicy.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("记录") {
                ForEach(model.knownCameras) { cam in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(cam.name)
                            Text("\(cam.host) · \(cam.fingerprint)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("忘记") { model.forget(cam) }
                    }
                }
                Button("清除导入记录（\(ImportHistory.shared.count) 条）") { ImportHistory.shared.clear(); model.rebuild() }
                Button(copied ? "已复制" : "复制诊断日志") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("MiniDiT 诊断日志\n网络：\(CameraFinder.networkSummary())\n\(AppLog.shared.text)", forType: .string)
                    copied = true
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func chooseFolder(_ key: ReferenceWritableKeyPath<AppModel, URL>) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model[keyPath: key]
        if panel.runModal() == .OK, let url = panel.url { model[keyPath: key] = url }
    }
}
