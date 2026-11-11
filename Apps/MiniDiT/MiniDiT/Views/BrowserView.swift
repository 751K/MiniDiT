import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            ProjectSidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 264, max: 320)
                .background(SidebarWidthFix(min: 220, ideal: 240, max: 280, column: 0))
                .toolbar(removing: .sidebarToggle)
        } content: {
            SourceDateSidebar()
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 360)
                .background(SidebarWidthFix(min: 250, ideal: 300, max: 360, column: 1))
        } detail: {
            if let id = model.browsingSession, let session = model.sessions.first(where: { $0.id == id }) {
                SessionBrowser(session: session, media: model.browsingSessionMedia) { model.browseSession(nil) }
            } else {
                ZStack(alignment: .bottom) {
                    VStack(spacing: 0) {
                        BrowseHeader()
                        if model.offline { OfflineBanner() }
                        if model.phase == .loading {
                            LoadingGrid()
                        } else {
                            GridView()
                        }
                    }
                    // 窗口没有标题栏：顶栏直接放进标题栏那一行，不另留一条空白。
                    .ignoresSafeArea(.container, edges: .top)
                    FloatingBar()
                        .padding(.horizontal, 20)
                        .padding(.bottom, 16)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
        }
        .overlay {
            if model.previewShot != nil { PreviewOverlay() }
        }
    }
}

/// 主窗口改成单个 Window 场景后，系统不再遵守上面的列宽，侧栏每次打开都被挤到 144 pt。
/// 直接找到底下的 NSSplitViewController，把侧栏的最小 / 最大宽度设上，太窄时拉到合适宽度。
private struct SidebarWidthFix: NSViewRepresentable {
    let min: CGFloat, ideal: CGFloat, max: CGFloat
    let column: Int

    func makeNSView(context: Context) -> NSView { Probe(fix: self) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
        let fix: SidebarWidthFix
        init(fix: SidebarWidthFix) { self.fix = fix; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        private func apply() {
            var v: NSView? = superview
            while let cur = v, !(cur is NSSplitView) { v = cur.superview }
            guard let split = v as? NSSplitView,
                  split.arrangedSubviews.indices.contains(fix.column) else { return }
            if let ctrl = split.delegate as? NSSplitViewController,
               ctrl.splitViewItems.indices.contains(fix.column) {
                let item = ctrl.splitViewItems[fix.column]
                item.minimumThickness = fix.min
                item.maximumThickness = fix.max
            }
            if split.arrangedSubviews[fix.column].frame.width < fix.min {
                let leading = split.arrangedSubviews.prefix(fix.column).reduce(0) { $0 + $1.frame.width }
                split.setPosition(leading + fix.ideal, ofDividerAt: fix.column)
            }
        }
    }
}
