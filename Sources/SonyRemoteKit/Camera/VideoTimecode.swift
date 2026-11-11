import Foundation

/// 精确的媒体帧率；时间运算始终保留 1001 分母，避免长片段逐渐偏移。
public struct VideoFrameRate: Sendable, Hashable {
    public let numerator: Int64
    public let denominator: Int64
    public var nominal: Int { Int((Double(numerator) / Double(denominator)).rounded()) }
    public var value: Double { Double(numerator) / Double(denominator) }
    public var isNTSC: Bool { denominator == 1001 }
    public var frameDurationXML: String { "\(denominator)/\(numerator)s" }

    public init?(_ text: String) {
        let text = text.trimmingCharacters(in: CharacterSet(charactersIn: "pi "))
        guard let n = Double(text), n.isFinite, n > 0, n <= 240 else { return nil }
        let whole = (n * 1001 / 1000).rounded()
        if abs(whole * 1000 / 1001 - n) < 0.02, abs(whole - n) > 0.01 {
            numerator = Int64(whole) * 1000; denominator = 1001
        } else {
            guard abs(n.rounded() - n) < 0.0001 else { return nil }
            numerator = Int64(n); denominator = 1
        }
    }

    public func xmlTime(frames: Int64) -> String { "\(frames * denominator)/\(numerator)s" }
}

/// 一天内的 SMPTE 时间码，支持 29.97/59.94 DF、跨午夜及逐帧定位。
public struct VideoTimecode: Sendable, Hashable {
    public let rate: VideoFrameRate
    public let dropFrame: Bool
    public let frameNumber: Int64
    private var dropped: Int64 { dropFrame ? Int64(rate.nominal / 15) : 0 }
    private var framesPerDay: Int64 { Int64(rate.nominal) * 86400 - dropped * 1296 }

    public init?(_ text: String, rate: VideoFrameRate) {
        let characters = Array(text)
        guard [11, 12].contains(characters.count), characters[2] == ":", characters[5] == ":",
              characters[8] == ":" || characters[8] == ";" else { return nil }
        let parts = text.split(whereSeparator: { $0 == ":" || $0 == ";" })
        guard text.count >= 11, parts.count == 4, parts.prefix(3).allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              (2...3).contains(parts[3].count), parts[3].allSatisfy(\.isNumber),
              let h = Int64(parts[0]), let m = Int64(parts[1]), let s = Int64(parts[2]), let f = Int64(parts[3]),
              h < 24, m < 60, s < 60, f < rate.nominal else { return nil }
        let df = text.contains(";")
        guard !df || rate.isNTSC && [30, 60].contains(rate.nominal) else { return nil }
        let drop = df ? Int64(rate.nominal / 15) : 0
        // 每个非十分钟的整分钟，跳过 2 / 4 个时间码标签。
        guard !(df && m % 10 != 0 && s == 0 && f < drop) else { return nil }
        self.rate = rate; dropFrame = df
        let minutes = h * 60 + m
        frameNumber = ((h * 3600 + m * 60 + s) * Int64(rate.nominal) + f) - drop * (minutes - minutes / 10)
    }

    private init(rate: VideoFrameRate, drop: Bool, frames: Int64) {
        self.rate = rate; dropFrame = drop; frameNumber = frames
    }

    public var text: String {
        let day = framesPerDay
        var n = (frameNumber % day + day) % day
        let fps = Int64(rate.nominal), drop = dropped
        if drop > 0 {
            let ten = fps * 600 - drop * 9
            let minute = fps * 60 - drop
            let blocks = n / ten, rest = n % ten
            n += drop * 9 * blocks
            if rest >= drop { n += drop * ((rest - drop) / minute) }
        }
        return String(format: "%02d:%02d:%02d%@%02d", Int(n / fps / 3600), Int(n / fps / 60 % 60),
                      Int(n / fps % 60), dropFrame ? ";" : ":", Int(n % fps))
    }

    public var seconds: Double { Double(frameNumber) / rate.value }
    public var xmlTime: String { rate.xmlTime(frames: frameNumber) }
    public var format: String { dropFrame ? "DF" : "NDF" }

    /// 只换显示时基，不改变源时间（如 25 fps TC 的第 12 帧在 100p 中是第 48 帧）。
    public func converted(to target: VideoFrameRate) -> Self? {
        guard !dropFrame || target.isNTSC && [30, 60].contains(target.nominal) else { return nil }
        let n = frameNumber * rate.denominator * target.numerator
        let d = rate.numerator * target.denominator
        return Self(rate: target, drop: dropFrame, frames: n / d)
    }

    public func adding(frames: Int64) -> Self {
        let n = (frameNumber + frames) % framesPerDay
        return Self(rate: rate, drop: dropFrame, frames: n < 0 ? n + framesPerDay : n)
    }

    public func adding(seconds: Double) -> Self {
        guard seconds.isFinite else { return self }
        return adding(frames: Int64((seconds * rate.value).rounded(.down)))
    }

    /// 从显示的时间码定位到片段内秒数，允许片段跨午夜。
    public func offset(to target: Self) -> Double? {
        guard rate == target.rate, dropFrame == target.dropFrame else { return nil }
        return Double((target.frameNumber - frameNumber + framesPerDay) % framesPerDay) / rate.value
    }

    /// Sony XML 的 4 个 BCD 字节是帧、秒、分、时；50/60p 的第二半帧用秒字节最高位表示。
    public static func sony(_ hex: String, rate: VideoFrameRate, halfStep: Bool) -> Self? {
        guard hex.count == 8, let n = UInt32(hex, radix: 16) else { return nil }
        func bcd(_ b: UInt32) -> Int? {
            guard b & 15 <= 9, b >> 4 <= 9 else { return nil }
            return Int(b >> 4) * 10 + Int(b & 15)
        }
        let ff = n >> 24, ss = n >> 16 & 255
        guard let h = bcd(n & 0x3F), let m = bcd(n >> 8 & 0x7F), let s = bcd(ss & 0x7F),
              let f = bcd(ff & 0x3F) else { return nil }
        let frames = halfStep ? f * 2 + (ss & 0x80 == 0 ? 0 : 1) : f
        let text = String(format: "%02d:%02d:%02d%@%02d", h, m, s, ff & 0x40 == 0 ? ":" : ";", frames)
        return Self(text, rate: rate)
    }
}
