import AppKit
import SwiftUI
@testable import MiniDiT

@main struct ProjectLayoutChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        let model = AppModel(startServices: false)
        let empty = ShootSession(day: "20261119", event: "111", name: "11.19-111")
        let populated = ShootSession(day: "20261119", event: "长名称", name: "跨日期拍摄项目的较长名称", files: ["/tmp/layout-missing.ARW"])
        // Reproduce switching the import target while browsing another project's videos.
        model.sessions = [empty, populated]
        model.browseSession(empty.id, media: .videos)
        precondition(model.currentSessionID == empty.id)
        model.selectSession(populated.id)
        precondition(model.currentSessionID == populated.id)
        precondition(model.browsingSession == nil && model.browsingSessionMedia == nil)

        // Every way to browse a project also selects that same import target.
        model.browseSession(empty.id, media: .photos)
        precondition(model.currentSessionID == empty.id && model.browsingSessionMedia == .photos)
        model.browseSession(populated.id)
        precondition(model.currentSessionID == populated.id && model.browsingSession == populated.id)
        precondition(model.browsingSessionMedia == nil)
        model.browseSession(populated.id, media: .videos)
        model.selectSession(populated.id)
        precondition(model.browsingSession == nil && model.browsingSessionMedia == nil)
        model.browseSession(empty.id, media: .photos)
        model.browseSession(nil)
        precondition(model.currentSessionID == empty.id)
        precondition(model.browsingSession == nil && model.browsingSessionMedia == nil)
        model.selectSession(nil)
        precondition(model.currentSessionID == nil && model.browsingSession == nil)
        print("PASS: project selection and media browsing stay consistent across switches and return")
        let root = URL(filePath: "/tmp/minidit-project-layout")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var windows: [NSWindow] = []
        for (index, entry) in [(empty, 860.0), (populated, 860.0), (empty, 1280.0)].enumerated() {
            let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: entry.1, height: 560),
                                  styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            let host = NSHostingView(rootView: SessionBrowser(session: entry.0, onBack: {}).environment(model))
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try! bitmap.representation(using: .png, properties: [:])!.write(to: root.appending(path: "project-\(index).png"))
                precondition(abs(host.bounds.width - entry.1) < 1)
                print("Rendered project layout \(index): \(host.bounds)")
                if index == 2 {
                    print("PASS: project pages rendered at minimum/default widths, empty and populated")
                    exit(0)
                }
            }
        }
        withExtendedLifetime(windows) { app.run() }
    }
}
