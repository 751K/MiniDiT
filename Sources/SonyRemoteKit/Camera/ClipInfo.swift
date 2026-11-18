import Foundation

/// 索尼视频片段的拍摄信息，来自和片段同名的 `C0001M01.XML`（NonRealTimeMeta）。
public struct ClipInfo: Sendable, Hashable {
    /// 帧数（按 formatFps 计）。
    public var frames: Int = 0
    /// 「59.94p」「23.98p」「25p」：文件的帧率。
    public var formatFps: String = ""
    /// 拍摄帧率；和 formatFps 不同就是升格 / 降格（S&Q）。
    public var captureFps: String = ""
    /// 「HEVC_3840_2160_M42210P@L51HT」
    public var codec: String = ""
    public var width: Int = 0
    public var height: Int = 0
    /// 「s-log3-cine」「rec2100-hlg」「rec709」…
    public var gamma: String = ""
    /// 「s-gamut3-cine」
    public var primaries: String = ""
    public var model: String = ""
    public var lens: String = ""
    /// 起始时间码「06:05:09;21」。
    public var timecode: String = ""
    /// 时间码的时基可能低于视频帧率（如 100p 素材使用 25 fps TC）。
    public var timecodeRate: String = ""
    public var startTimecode: VideoTimecode? { VideoFrameRate(timecodeRate.isEmpty ? formatFps : timecodeRate).flatMap { VideoTimecode(timecode, rate: $0) } }
    public var mediaTimecode: VideoTimecode? { VideoFrameRate(formatFps).flatMap { startTimecode?.converted(to: $0) } }
    public var endTimecode: String? {
        guard let start = startTimecode, let rate = VideoFrameRate(formatFps), frames > 0 else { return nil }
        return start.adding(frames: Int64(frames - 1), at: rate).text
    }
    /// 有代理（SubStream）。
    public var hasProxy = false
    /// 片段里的标记：Shot Mark 等（KlvPacketTable 里的「_ShotMark1」），按帧号排。
    public var marks: [Mark] = []

    public struct Mark: Sendable, Hashable {
        /// 第几帧（按 formatFps）。
        public var frame: Int
        /// 原名「_ShotMark1」。
        public var name: String
        /// Shot Mark 的编号（1、2…）；不是 Shot Mark 时 nil。
        public var shotMark: Int? {
            guard name.hasPrefix("_ShotMark") else { return nil }
            return Int(name.dropFirst("_ShotMark".count)) ?? 1
        }
    }

    public var shotMarks: [Mark] { marks.filter { $0.shotMark != nil } }

    public init() {}

    // MARK: 显示

    /// 帧率的数值（59.94p → 59.94…，用 1000/1001 的精确值）。
    public static func fpsValue(_ s: String) -> Double? {
        let digits = s.trimmingCharacters(in: CharacterSet(charactersIn: "pi"))
        guard let v = Double(digits), v > 0 else { return nil }
        // 23.98 / 29.97 / 47.95 / 59.94 / 119.88 都是整数帧率 × 1000/1001。
        let whole = (v * 1001 / 1000).rounded()
        return abs(whole * 1000 / 1001 - v) < 0.02 && abs(whole - v) > 0.01 ? whole * 1000 / 1001 : v
    }

    public var duration: Double? {
        guard frames > 0, let f = Self.fpsValue(formatFps) else { return nil }
        return Double(frames) / f
    }

    /// 「1:23」「12:05」「1:02:03」
    public var durationText: String? {
        guard let d = duration else { return nil }
        let s = Int(d.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 「59.94p」；升格时「120p→23.98p」。
    public var fpsText: String {
        guard !captureFps.isEmpty, captureFps != formatFps else { return formatFps }
        return captureFps + "→" + formatFps
    }

    /// 升格 / 降格。
    public var isSlowOrQuick: Bool { !captureFps.isEmpty && !formatFps.isEmpty && captureFps != formatFps }

    public var gammaText: String {
        let g = gamma.lowercased()
        if g.contains("s-log3") { return "S-Log3" }
        if g.contains("s-log2") { return "S-Log2" }
        if g.contains("hlg") { return "HLG" }
        if g.contains("cinetone") { return "S-Cinetone" }
        if g.contains("709") { return "709" }
        return gamma
    }

    public var primariesText: String {
        switch primaries.lowercased() {
        case "s-gamut3-cine": "S-Gamut3.Cine"
        case "s-gamut3": "S-Gamut3"
        case "rec2020": "Rec.2020"
        case "rec709": "Rec.709"
        default: primaries
        }
    }

    /// 「H.265 4:2:2 10bit」
    public var codecText: String {
        let c = codec.uppercased()
        var parts: [String] = []
        if c.hasPrefix("HEVC") { parts.append("H.265") } else if c.hasPrefix("AVC") { parts.append("H.264") } else if !c.isEmpty {
            parts.append(String(c.prefix { $0 != "_" }))
        }
        let profile = c.split(separator: "_").last.map(String.init) ?? ""
        if profile.contains("422") { parts.append("4:2:2") } else if profile.contains("420") { parts.append("4:2:0") }
        if profile.contains("10") || profile.hasPrefix("H422") { parts.append("10bit") }
        if profile.contains("422I") || profile.contains("INTRA") { parts.append(String(localized: "帧内", bundle: .miniDiT)) }
        return parts.joined(separator: " ")
    }

    /// 「3840×2160」→「4K」这类简称。
    public var resolutionText: String {
        guard width > 0, height > 0 else { return "" }
        switch (width, height) {
        case (3840, 2160): return "4K"
        case (4096, 2160): return "DCI 4K"
        case (1920, 1080): return "HD"
        default: return "\(width)×\(height)"
        }
    }

    // MARK: 读取

    /// C0001.MP4 → 同一文件夹里的 C0001M01.XML（老机型是 C0001.XML）。
    public static func sidecar(for clip: URL) -> URL? {
        let dir = clip.deletingLastPathComponent(), base = clip.deletingPathExtension().lastPathComponent
        for name in [base + "M01.XML", base + ".XML"] {
            let u = dir.appending(path: name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    public static func read(_ xml: URL) -> ClipInfo? {
        guard let data = try? Data(contentsOf: xml) else { return nil }
        return parse(data)
    }

    /// 索尼 MP4 末尾的 meta 盒子里内嵌着和 M01.XML 一字不差的同一份 XML。从文件末尾一段数据里把它切出来。
    public static func embeddedXML(in tail: Data) -> Data? {
        guard let start = tail.range(of: Data("<?xml".utf8)),
              let end = tail.range(of: Data("</NonRealTimeMeta>".utf8), in: start.upperBound..<tail.endIndex) else { return nil }
        // 卡上的 M01.XML 末尾有一个换行，MP4 里内嵌的那份后面也跟着，一起带上才一字不差。
        let stop = end.upperBound < tail.endIndex && tail[end.upperBound] == 0x0A ? end.upperBound + 1 : end.upperBound
        return tail.subdata(in: start.lowerBound..<stop)
    }

    /// 读本地 MP4 末尾 64 KB 里内嵌的 XML。
    public static func embeddedXML(inFile url: URL) -> Data? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd() else { return nil }
        try? h.seek(toOffset: size > tailLength ? size - tailLength : 0)
        return (try? h.readToEnd()).flatMap(embeddedXML(in:))
    }

    /// 末尾读多少：XML 只有几 KB，留足余量。
    public static let tailLength: UInt64 = 64 * 1024

    public static func parse(_ data: Data) -> ClipInfo? {
        let p = Parser()
        let x = XMLParser(data: data)
        x.delegate = p
        guard x.parse() || p.info.frames > 0 else { return nil }
        p.finishTimecode()
        p.info.marks.sort { $0.frame < $1.frame }
        return p.info
    }

    private final class Parser: NSObject, XMLParserDelegate {
        var info = ClipInfo()
        var ltc: String?
        var tcFps: String?
        var halfStep = false

        func finishTimecode() {
            guard let ltc, let videoRate = VideoFrameRate(info.formatFps) else { return }
            let half = halfStep || (tcFps == nil && [50, 60].contains(videoRate.nominal))
            let base = tcFps.flatMap(Double.init) ?? Double(half ? videoRate.nominal / 2 : videoRate.nominal)
            let nominal = base * (half ? 2 : 1)
            let rateText = videoRate.isNTSC ? String(nominal * 1000 / 1001) : String(nominal)
            guard let rate = VideoFrameRate(rateText), let tc = VideoTimecode.sony(ltc, rate: rate, halfStep: half) else { return }
            info.timecode = tc.text
            info.timecodeRate = rateText
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch name {
            case "Duration": info.frames = Int(a["value"] ?? "") ?? 0
            case "LtcChangeTable": tcFps = a["tcFps"]; halfStep = a["halfStep"] == "true"
            case "LtcChange":
                if ltc == nil, a["frameCount"] == "0", let v = a["value"] { ltc = v }
            case "VideoFrame":
                info.codec = a["videoCodec"] ?? ""
                info.captureFps = a["captureFps"] ?? ""
                info.formatFps = a["formatFps"] ?? ""
            case "VideoLayout":
                info.width = Int(a["pixel"] ?? "") ?? 0
                info.height = Int(a["numOfVerticalLine"] ?? "") ?? 0
            case "SubStream": info.hasProxy = true
            case "KlvPacket":
                // lengthValue：一个字节的长度 + ASCII，比如「095F5265635374617274」= 9 字节「_RecStart」。
                if let hex = a["lengthValue"], let frame = Int(a["frameCount"] ?? ""), let name = Self.klvText(hex) {
                    info.marks.append(Mark(frame: frame, name: name))
                }
            case "Device": info.model = a["modelName"] ?? ""
            case "Lens": info.lens = a["modelName"] ?? ""
            case "Item":
                switch a["name"] {
                case "CaptureGammaEquation": info.gamma = a["value"] ?? ""
                case "CaptureColorPrimaries": info.primaries = a["value"] ?? ""
                default: break
                }
            default: break
            }
        }

        static func klvText(_ hex: String) -> String? {
            var bytes: [UInt8] = []
            var i = hex.startIndex
            while let j = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex), i < hex.endIndex {
                guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
                bytes.append(b)
                i = j
            }
            // lengthValue 的第一个字节是长度；长度为 0 时 1...0 是非法区间，会直接崩。
            guard let n = bytes.first, n > 0, bytes.count > Int(n) else { return nil }
            return String(bytes: bytes[1...Int(n)], encoding: .ascii)
        }

    }
}
