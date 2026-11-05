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
        .alert(model.backupFolder == nil ? "还没有设置备份盘" : "没有找到备份盘", isPresented: $model.backupMissingPrompt) {
            Button("只存一份，继续") { model.beginImport(checkBackup: false) }
            if model.backupFolder == nil {
                Button("选择备份位置…") {
                    if let u = FolderPicker.choose(start: nil) { model.backupFolder = u; model.beginImport() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let u = model.backupFolder {
                Text("「\(u.path(percentEncoded: false))」现在找不到（备份盘可能没接上）。\n这次只会存一份；接上以后对这些照片再导入一次，会补上第二份。")
            } else {
                Text("这次只会存一份。也可以在「设置 › 导入」里选择备份位置。")
            }
        }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
