import AppKit
import SonyRemoteKit
import SwiftUI

@main
struct MiniDiTApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("MiniDiT") {
            RootView()
                .environment(model)
                .frame(minWidth: 860, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("切换来源…") { model.disconnect() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.progress != nil || model.connectedName == nil)
            }
            CommandMenu("选择") {
                Button("选所有没导入过的") { model.selectNew(in: Set(model.days.map(\.id))) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("反选") { model.grid.invert() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("取消选择") { model.grid.clear() }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("大图预览") { model.openPreview() }
                    .keyboardShortcut("y", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button("放大缩略图") { model.thumbSize = min(320, model.thumbSize + 30) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小缩略图") { model.thumbSize = max(110, model.thumbSize - 30) }
                    .keyboardShortcut("-", modifiers: .command)
            }
        }
        Settings {
            SettingsView().environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.phase == .ready || model.offline || (model.phase == .loading && model.connectedName != nil) {
                BrowserView()
            } else {
                ConnectView()
            }
        }
        .sheet(item: $model.credentialRequest) { CredentialSheet(request: $0) }
        .sheet(item: $model.fingerprintRequest) { FingerprintSheet(request: $0) }
        .sheet(item: $model.sessionRequest) { SessionSheet(request: $0) }
        .sheet(isPresented: Binding(get: { !model.setupDone }, set: { if !$0 { model.setupDone = true } })) {
            SetupSheet().interactiveDismissDisabled()
        }
        .alert(model.backupFolder == nil ? "尚未设置备份位置" : "未找到备份磁盘", isPresented: $model.backupMissingPrompt) {
            Button("仅存储一份并继续") { model.beginImport(checkBackup: false) }
            if model.backupFolder == nil {
                Button("选择备份位置…") {
                    if let u = FolderPicker.choose(start: nil) { model.backupFolder = u; model.beginImport() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let u = model.backupFolder {
                Text("备份位置“\(u.path(percentEncoded: false))”当前不可用，磁盘可能未连接。\n本次将仅存储一份，且不会删除存储卡上的文件。连接磁盘后再次导入这些照片，即可补全备份。")
            } else {
                Text("本次将仅存储一份，且不会删除存储卡上的文件。可在“设置 › 导入”中选择备份位置。")
            }
        }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
