import AppKit
import SwiftUI

/// 首次启动：选择导入方式（存储位置、是否备份、导入后是否删除存储卡上的文件）。
struct SetupSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("导入设置").font(.title2.weight(.semibold))
                Text("请选择照片的存储与备份方式。以下各项均可在“设置 › 导入”中修改，也可在导入栏中按次调整。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Group {
                section("存储位置") {
                    LocationRow(path: primaryURL.path(percentEncoded: false), note: primaryNote, button: "更改…") {
                        if let u = FolderPicker.choose(start: primaryURL) { setPrimary(u) }
                    }
                }

                section("备份") {
                    Picker("备份", selection: $model.backupEnabled) {
                        Text("仅存储一份").tag(false)
                        Text("同时备份至另一磁盘").tag(true)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    if model.backupEnabled {
                        LocationRow(path: model.backupFolder?.path(percentEncoded: false),
                                    note: "备份文件按“年-月-日-事件”分目录存放。建议选用另一块物理磁盘。",
                                    button: model.backupFolder == nil ? "选择…" : "更改…") {
                            if let u = FolderPicker.choose(start: model.backupFolder) { model.backupFolder = u }
                        }
                    }
                    Text(model.backupEnabled
                         ? "两份文件均以 xxHash64 校验，校验一致后方视为导入完成。"
                         : "文件以 xxHash64 校验后保存。未建立备份时，请勿删除存储卡上的原始文件。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                section("导入完成后") {
                    Picker("导入完成后", selection: $model.deleteAfterImport) {
                        Text("保留存储卡上的文件").tag(false)
                        Text("删除存储卡上已导入的照片").tag(true)
                    }
                    .pickerStyle(.radioGroup).labelsHidden()
                    Text("仅删除校验通过的照片；启用备份时，须两份均校验通过。视频文件不予删除，请于相机上格式化存储卡。此项仅适用于读卡器，经 Wi-Fi 连接相机时不可用。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                Spacer()
                Button("开始使用") { model.setupDone = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.backupEnabled && model.backupFolder == nil)
            }
        }
        .padding(24)
        .frame(width: 540)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private var isSession: Bool { model.captureOneMode == .newSession }
    private var primaryURL: URL { isSession ? model.sessionsFolder : model.destination }
    private var primaryNote: String {
        isSession ? "Capture One 会话建于此目录，照片存入会话的 Capture 文件夹。"
                  : "照片按“年/年-月-日”分目录存放。"
    }
    private func setPrimary(_ u: URL) {
        if isSession { model.sessionsFolder = u } else { model.destination = u }
    }
}

private struct LocationRow: View {
    let path: String?
    let note: String
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.tint).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(path ?? "尚未选择").font(.system(size: 12)).foregroundStyle(path == nil ? .orange : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, action: action)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
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
