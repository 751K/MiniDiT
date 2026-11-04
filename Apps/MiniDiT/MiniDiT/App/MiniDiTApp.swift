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
