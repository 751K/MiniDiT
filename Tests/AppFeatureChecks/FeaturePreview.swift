import AppKit
import SonyRemoteKit
import SwiftUI
@testable import MiniDiT

/// 同步 AppKit 入口，让主事件循环正常调度播放器及来源读取任务。
@main struct FeaturePreview {
    @MainActor static func main() {
        let app = NSApplication.shared
        guard CommandLine.arguments.count > 1 else { return }
        let root = URL(filePath: CommandLine.arguments[1])
        let model = AppModel(startServices: false)
        model.onlyNew = false; model.showVideo = true; model.autoRefresh = false
        model.sourceKind = .card; model.cardRoot = root; model.connectedName = "功能检查卡"
        model.library = LocalCardLibrary(root: root)
        let window = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "MiniDiT 功能检查"
        window.contentView = NSHostingView(rootView: BrowserView().environment(model))
        app.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        Task { @MainActor in
            await model.loadAll()
            if let shot = model.allShots.first(where: { model.items[$0.primary]?.filename == "C0001.MP4" }) { model.openPreview(shot.id) }
        }
        withExtendedLifetime(window) { app.run() }
    }
}
