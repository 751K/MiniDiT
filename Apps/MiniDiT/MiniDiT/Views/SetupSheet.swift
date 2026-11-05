import AppKit
import SwiftUI

/// 第一次打开：设置照片存到哪、第二份备份到哪。
struct SetupSheet: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("先设置两个存放位置").font(.title2.weight(.semibold))
                Text("每张照片存两份：一份用来修图，一份放在另一块盘上备份。两份都校验过，才算导好。")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            LocationRow(title: "第一份", detail: primaryDetail, path: primaryURL.path(percentEncoded: false),
                        button: "更改…") {
                if let u = FolderPicker.choose(start: primaryURL) { setPrimary(u) }
            }
            LocationRow(title: "第二份（备份盘）",
                        detail: "存成「年-月-日-事件」文件夹。最好选另一块硬盘，电脑坏了也不丢。",
                        path: model.backupFolder?.path(percentEncoded: false), button: model.backupFolder == nil ? "选择…" : "更改…") {
                if let u = FolderPicker.choose(start: model.backupFolder) { model.backupFolder = u }
            }

            Text("以后可以在「设置 › 导入」里改。").font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                if model.backupFolder == nil {
                    Button("先不备份") { model.setupDone = true }
                }
                Button("完成") { model.setupDone = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.backupFolder == nil)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private var isSession: Bool { model.captureOneMode == .newSession }
    private var primaryURL: URL { isSession ? model.sessionsFolder : model.destination }
    private var primaryDetail: String {
        isSession ? "Capture One 会话放在这里，照片存进会话的 Capture 文件夹。"
                  : "照片按「年/年-月-日」存在这里。"
    }
    private func setPrimary(_ u: URL) {
        if isSession { model.sessionsFolder = u } else { model.destination = u }
    }
}

private struct LocationRow: View {
    let title: String
    let detail: String
    let path: String?
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "folder.fill").font(.title2).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.semibold)
                Text(path ?? "还没有选择").font(.system(size: 12)).foregroundStyle(path == nil ? .orange : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(button, action: action)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
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
