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
        .commands {
            CommandGroup(replacing: .newItem) {}
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
            SettingsView().environment(model).frame(width: 520)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Group {
            if model.phase == .ready || (model.phase == .loading && !model.days.isEmpty) {
                BrowserView()
            } else {
                ConnectView()
            }
        }
        .sheet(item: $model.credentialRequest) { CredentialSheet(request: $0) }
        .sheet(item: $model.fingerprintRequest) { FingerprintSheet(request: $0) }
        .sheet(item: $model.sessionRequest) { SessionSheet(request: $0) }
        .alert("出错了", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
