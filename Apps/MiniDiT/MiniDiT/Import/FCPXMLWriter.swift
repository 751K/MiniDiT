import AppKit
import CryptoKit
import SonyRemoteKit
import MiniDiTCore

/// 导入的视频交给 Final Cut Pro：写一份 FCPXML（每个视频文件夹一个事件，片段原地引用、不复制，
/// 代理作为 proxy-media 一起挂上），再用 FCP 打开，由 FCP 询问放进哪个资源库。
enum FCPXMLWriter {
    static let bundleID = "com.apple.FinalCutApp"

    struct Clip: Sendable {
        let url: URL
        let proxy: URL?
        /// 卷号「A001」，写进 FCP 的卷名 / Resolve 的 Reel Name。
        var roll: String? = nil
        var uid: String? = nil
    }

    struct Event: Sendable {
        let name: String
        let clips: [Clip]
        var uid: String? = nil
    }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    /// FCP 内置的 Log 处理（customLUTOverride，「编号 (名字)」）。编号是 FCP 12.4 自己导出的；
    /// S-Log2 的编号还没核实过，先不写。
    static func logProcessing(_ info: ClipInfo) -> String? {
        let g = info.gamma.lowercased(), p = info.primaries.lowercased()
        if g.contains("s-log3") { return p.contains("cine") ? "35 (Sony_SLog3_SGamut3Cine_v2)" : "36 (Sony_SLog3_SGamut3)" }
        return nil
    }

    static func xml(_ events: [Event], logProcessing setLog: Bool = false) -> String {
        var res: [String] = [], body: [String] = []
        var formats: [String: String] = [:]
        var n = 0
        for e in events {
            var clips: [String] = []
            for c in e.clips {
                n += 1
                let id = "r\(n)"
                let info = ClipInfo.sidecar(for: c.url).flatMap(ClipInfo.read)
                var attrs = "id=\"\(id)\" name=\"\(XMLText.escape(c.url.deletingPathExtension().lastPathComponent))\" hasVideo=\"1\" hasAudio=\"1\""
                if let uid = c.uid { attrs += " uid=\"\(XMLText.escape(uid))\"" }
                var clipAttrs = ""
                let start = info?.startTimecode
                if let start {
                    attrs += " start=\"\(start.xmlTime)\""
                    clipAttrs += " start=\"\(start.xmlTime)\" tcStart=\"\(start.xmlTime)\" tcFormat=\"\(start.format)\""
                }
                if setLog, let info, let lut = logProcessing(info) { attrs += " customLUTOverride=\"\(lut)\"" }
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
                        clipAttrs += " duration=\"\(d)\""
                    }
                }
                var reps = "      <media-rep kind=\"original-media\" src=\"\(XMLText.escape(c.url.absoluteString))\"/>\n"
                if let p = c.proxy { reps += "      <media-rep kind=\"proxy-media\" src=\"\(XMLText.escape(p.absoluteString))\"/>\n" }
                var md = ""
                if info != nil || c.roll != nil {
                    var items: [String] = []
                    if let r = c.roll { items.append("        <md key=\"com.apple.proapps.studio.reel\" value=\"\(XMLText.escape(r))\"/>") }
                    if let info, !info.model.isEmpty { items.append("        <md key=\"com.apple.proapps.mio.cameraName\" value=\"\(XMLText.escape(info.model))\"/>") }
                    let desc = info.map { [$0.gammaText, $0.primariesText, $0.fpsText, $0.lens].filter { !$0.isEmpty }.joined(separator: " · ") } ?? ""
                    if !desc.isEmpty { items.append("        <md key=\"com.apple.proapps.spotlight.kMDItemDescription\" value=\"\(XMLText.escape(desc))\"/>") }
                    if !items.isEmpty { md = "      <metadata>\n" + items.joined(separator: "\n") + "\n      </metadata>\n" }
                }
                res.append("    <asset \(attrs)>\n\(reps)\(md)    </asset>")
                // Shot Mark → 片段上的标记点（时间从片段开头算，一帧长）。
                var markers: [String] = []
                if let info, let fd = frameDuration(info.formatFps) {
                    for m in info.shotMarks {
                        // 片段标记使用源时间坐标，带上素材起始 TC；时基不同也保持有理数精度。
                        let tc = start.map { $0.frameNumber * $0.rate.denominator } ?? 0
                        let den = start?.rate.numerator ?? 1
                        let num = tc * fd.den + Int64(m.frame) * fd.num * den
                        markers.append("      <marker start=\"\(num)/\(den * fd.den)s\" duration=\"\(fd.text)\" value=\"Shot Mark \(m.shotMark ?? 1)\"/>")
                    }
                }
                let clipOpen = "    <asset-clip ref=\"\(id)\" name=\"\(XMLText.escape(c.url.deletingPathExtension().lastPathComponent))\"\(clipAttrs)"
                clips.append(markers.isEmpty ? clipOpen + "/>" : clipOpen + ">\n" + markers.joined(separator: "\n") + "\n    </asset-clip>")
            }
            let eventUID = e.uid.map { " uid=\"\(XMLText.escape($0))\"" } ?? ""
            body.append("  <event\(eventUID) name=\"\(XMLText.escape(e.name))\">\n" + clips.joined(separator: "\n") + "\n  </event>")
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
        guard let rate = VideoFrameRate(fps) else { return nil }
        return (rate.denominator, rate.numerator, rate.frameDurationXML)
    }

    static func stableUID(_ value: String) -> String {
        let hex = SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02X", $0) }.joined()
        return hex
    }
    /// A retry uses the same immutable document; opening is awaited, not mistaken for an import receipt.
    static func prepare(id: UUID, payload: Data, directory: URL? = nil) throws -> URL {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "SonyImport/FCP")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "MiniDiT-" + id.uuidString + ".fcpxml")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Data(contentsOf: url) == payload else { throw VideoDelivery.Failure("交接文件已被修改，请保留现有文件，并在 Final Cut Pro 中检查接收结果。") }
        } else { try payload.write(to: url, options: .withoutOverwriting) }
        return url
    }
    @MainActor static func open(_ url: URL) async throws {
        guard let app = appURL else { throw MiniDiTCore.VideoDelivery.Failure("未找到 Final Cut Pro，请安装后重试。") }
        _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
