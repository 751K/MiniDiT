import AppKit

/// 「MiniDiT › 关于 MiniDiT」：系统的关于窗口，下面的滚动区域列出开源软件的许可（Resources/Acknowledgements.txt）。
/// 文字用系统的标签颜色，深色模式下也看得清。
@MainActor
enum AboutPanel {
    static func show() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let credits { options[.credits] = credits }
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private static let credits: NSAttributedString? = {
        guard let url = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]
        let heading: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        let out = NSMutableAttributedString()
        var inHeading = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                out.append(NSAttributedString(string: String(line.dropFirst(3)) + "\n", attributes: heading))
                inHeading = true
            } else {
                // 标题下一行是网址，和标题放在一起。
                out.append(NSAttributedString(string: line + "\n", attributes: inHeading && !line.isEmpty ? heading : body))
                if line.isEmpty { inHeading = false }
            }
        }
        return out
    }()
}
