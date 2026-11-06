import AppKit
import SonyRemoteKit

/// 导入的视频交给 Final Cut Pro：写一份 FCPXML（每个视频文件夹一个事件，片段原地引用、不复制，
/// 代理作为 proxy-media 一起挂上），再用 FCP 打开，由 FCP 询问放进哪个资源库。
enum FCPXMLWriter {
    static let bundleID = "com.apple.FinalCutApp"

    struct Clip {
        let url: URL
        let proxy: URL?
    }

    struct Event {
        let name: String
        let clips: [Clip]
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    static func xml(_ events: [Event]) -> String {
        var res: [String] = [], body: [String] = []
        var formats: [String: String] = [:]
        var n = 0
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        for e in events {
            var clips: [String] = []
            for c in e.clips {
                n += 1
                let id = "r\(n)"
                let info = ClipInfo.sidecar(for: c.url).flatMap(ClipInfo.read)
                var attrs = "id=\"\(id)\" name=\"\(esc(c.url.deletingPathExtension().lastPathComponent))\" hasVideo=\"1\" hasAudio=\"1\""
                var clipAttrs = ""
                if let info, let fd = frameDuration(info.formatFps), info.width > 0 {
                    let key = "\(info.width)x\(info.height)@\(fd.text)"
                    let fid = formats[key] ?? {
                        let f = "f\(formats.count + 1)"
                        formats[key] = f
                        res.append("    <format id=\"\(f)\" frameDuration=\"\(fd.text)\" width=\"\(info.width)\" height=\"\(info.height)\"/>")
                        return f
                    }()
                    attrs += " format=\"\(fid)\""
                    if info.frames > 0 {
                        let d = "\(Int64(info.frames) * fd.num)/\(fd.den)s"
                        attrs += " duration=\"\(d)\""
                        clipAttrs = " duration=\"\(d)\""
                    }
                }
                var reps = "      <media-rep kind=\"original-media\" src=\"\(esc(c.url.absoluteString))\"/>\n"
                if let p = c.proxy { reps += "      <media-rep kind=\"proxy-media\" src=\"\(esc(p.absoluteString))\"/>\n" }
                var md = ""
                if let info {
                    var items: [String] = []
                    if !info.model.isEmpty { items.append("        <md key=\"com.apple.proapps.mio.cameraName\" value=\"\(esc(info.model))\"/>") }
                    let desc = [info.gammaText, info.primariesText, info.fpsText, info.lens].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !desc.isEmpty { items.append("        <md key=\"com.apple.proapps.spotlight.kMDItemDescription\" value=\"\(esc(desc))\"/>") }
                    if !items.isEmpty { md = "      <metadata>\n" + items.joined(separator: "\n") + "\n      </metadata>\n" }
                }
                res.append("    <asset \(attrs)>\n\(reps)\(md)    </asset>")
                clips.append("    <asset-clip ref=\"\(id)\" name=\"\(esc(c.url.deletingPathExtension().lastPathComponent))\"\(clipAttrs)/>")
            }
            body.append("  <event name=\"\(esc(e.name))\">\n" + clips.joined(separator: "\n") + "\n  </event>")
        }
        // format 要排在引用它的 asset 前面。
        let fmt = res.filter { $0.hasPrefix("    <format") }, assets = res.filter { !$0.hasPrefix("    <format") }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.14">
          <import-options>
            <option key="copy assets" value="0"/>
            <option key="suppress warnings" value="1"/>
          </import-options>
          <resources>
        \((fmt + assets).joined(separator: "\n"))
          </resources>
        \(body.joined(separator: "\n"))
        </fcpxml>

        """
    }

    /// 「59.94p」→ 1001/60000s，「25p」→ 100/2500s。
    static func frameDuration(_ fps: String) -> (num: Int64, den: Int64, text: String)? {
        guard let v = ClipInfo.fpsValue(fps) else { return nil }
        let whole = Int64((v * 1001 / 1000).rounded())
        let ntsc = abs(Double(whole) * 1000 / 1001 - v) < 0.001
        let (num, den) = ntsc ? (Int64(1001), whole * 1000) : (Int64(100), Int64(v.rounded()) * 100)
        return (num, den, "\(num)/\(den)s")
    }

    /// 写到 Application Support/SonyImport/FCP/ 里，用 FCP 打开。返回写下的文件。
    @MainActor
    static func send(_ events: [Event]) throws -> URL? {
        guard let app = appURL, !events.isEmpty else { return nil }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SonyImport/FCP", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appending(path: "MiniDiT-\(f.string(from: Date())).fcpxml")
        try xml(events).write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        return url
    }
}
