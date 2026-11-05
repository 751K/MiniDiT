import Foundation
import ImageIO

/// 一张照片的拍摄参数，从 EXIF 里读。缺的项为 nil。
public struct ShotExif: Sendable, Equatable {
    public var camera: String?
    public var lens: String?
    /// 焦距（毫米）。
    public var focalLength: Double?
    public var fNumber: Double?
    /// 快门（秒）。
    public var exposureTime: Double?
    public var iso: Int?
    /// 曝光补偿（EV）。
    public var exposureBias: Double?
    /// 机身序列号（EXIF BodySerialNumber），用来认出是哪台机身拍的。
    public var serial: String?

    public init?(properties p: [CFString: Any]) {
        let exif = p[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = p[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        camera = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        lens = (exif[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespaces)
        focalLength = Self.number(exif[kCGImagePropertyExifFocalLength])
        fNumber = Self.number(exif[kCGImagePropertyExifFNumber])
        exposureTime = Self.number(exif[kCGImagePropertyExifExposureTime])
        iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
        exposureBias = Self.number(exif[kCGImagePropertyExifExposureBiasValue])
        serial = (exif[kCGImagePropertyExifBodySerialNumber] as? String)?.trimmingCharacters(in: .whitespaces)
        if serial?.isEmpty == true { serial = nil }
        if fNumber == nil && exposureTime == nil && iso == nil && focalLength == nil { return nil }
        if lens?.isEmpty == true { lens = nil }
        if camera?.isEmpty == true { camera = nil }
    }

    public init?(imageData: Data) {
        guard let src = CGImageSourceCreateWithData(imageData as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        self.init(properties: p)
    }

    public init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        self.init(properties: p)
    }

    private static func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

    // MARK: 显示

    /// 「35 mm · f/2.8 · 1/250 s · ISO 400 · +0.3 EV」，没有的项省略。
    public var exposureText: String {
        var parts: [String] = []
        if let f = focalLength { parts.append("\(Self.trim(f)) mm") }
        if let n = fNumber { parts.append("f/\(Self.trim(n))") }
        if let t = exposureTime { parts.append(Self.shutter(t)) }
        if let iso { parts.append("ISO \(iso)") }
        if let b = exposureBias, abs(b) >= 0.05 { parts.append((b > 0 ? "+" : "−") + String(format: "%.1f EV", abs(b))) }
        return parts.joined(separator: " · ")
    }

    /// 「ILCE-7M5 · FE 24-70mm F2.8 GM II」。
    public var gearText: String { [camera, lens].compactMap { $0 }.joined(separator: " · ") }

    static func trim(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// 1/250 s、1/2 s、2.5 s、30 s。
    static func shutter(_ t: Double) -> String {
        if t < 0.3 { return "1/\(Int((1 / t).rounded())) s" }
        return "\(trim(t)) s"
    }
}
