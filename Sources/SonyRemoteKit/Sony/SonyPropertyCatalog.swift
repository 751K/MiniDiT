import Foundation

/// 索尼属性的名字和可读写法：按 SDK 名称（或 0xD20D 这样的编号）找属性，把原始值写成相机菜单里的样子，
/// 也能把「1/1000」「F5.6」「3200K」「ST」「+3」解析回原始值。
///
/// 只有线上取值已经核实（或和公开表吻合）的属性才有可读写法；其余属性一律用原始值，
/// 因为 SDK 的枚举值和线上值不一定相同，写错名字比不写更糟。
public enum SonyPropertyCatalog {
    /// libgphoto2 里有、SDK 表里没有的几个名字。
    static let fallbackNames: [UInt16: String] = [
        0xD215: "ObjectInMemory", 0xD201: "DRO", 0xD241: "Movie_File_Format",
    ]

    public static func name(_ code: UInt16) -> String? { sdkPropertyNames[code] ?? fallbackNames[code] }

    /// 名字（不分大小写；也接受 0xD20D、D20D）→ 属性码。
    public static func code(for text: String) -> UInt16? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let lower = t.lowercased()
        if let c = byLowerName[lower] { return c }
        let hex = lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
        if hex.count == 4, let c = UInt16(hex, radix: 16), name(c) != nil || hex.first == "d" || hex.first == "5" || hex.first == "e" { return c }
        return nil
    }

    private static let byLowerName: [String: UInt16] = {
        var m: [String: UInt16] = [:]
        for (c, n) in fallbackNames { m[n.lowercased()] = c }
        for (c, n) in sdkPropertyNames { m[n.lowercased()] = c }
        // 常用的别名。
        for (alias, c) in ["iso": 0xD21E, "shutter": 0xD20D, "aperture": 0x5007, "fnumber": 0x5007, "colortemp": 0xD20F,
                           "exposuremode": 0x500E, "drivemode": 0x5013, "focusmode": 0x500A] as [String: UInt16] { m[alias] = c }
        return m
    }()

    // MARK: 可读写法

    /// 已核实或和公开表吻合的取值表。
    static let valueLabels: [UInt16: [Int64: String]] = [
        0x5005: [0x0002: "AWB", 0x0004: "Daylight", 0x8011: "Shade", 0x8010: "Cloudy", 0x0006: "Incandescent",
                 0x8001: "Fluor.WarmWhite", 0x8002: "Fluor.CoolWhite", 0x8003: "Fluor.DayWhite", 0x8004: "Fluor.Daylight",
                 0x0007: "Flash", 0x8030: "UnderwaterAuto", 0x8012: "ColorTemp", 0x8020: "Custom1", 0x8021: "Custom2",
                 0x8022: "Custom3", 0x8023: "Custom"],
        0x500A: [1: "MF", 2: "AF-S", 0x8004: "AF-C", 0x8005: "AF-A", 0x8006: "DMF"],
        0x500E: [1: "M", 2: "P", 3: "A", 4: "S"],
        0x5013: [1: "Single"],
        // Creative Look：1–12 按菜单顺序（SKAARHOJ 的 SDK 控制表 1 ST、2 PT、3 NT 与之吻合），257–262 为自定义外观 1–6（SDK 偏移 256）。
        0xD0FA: [1: "ST", 2: "PT", 3: "NT", 4: "VV", 5: "VV2", 6: "FL", 7: "IN", 8: "SH", 9: "BW", 10: "SE", 11: "FL2", 12: "FL3",
                 257: "Custom1", 258: "Custom2", 259: "Custom3", 260: "Custom4", 261: "Custom5", 262: "Custom6"],
        0xD201: [1: "Off", 0x1F: "Auto", 0x11: "Lv1", 0x12: "Lv2", 0x13: "Lv3", 0x14: "Lv4", 0x15: "Lv5"],
        0xD287: [1: "JPEG", 2: "HEIF422", 3: "HEIF420"],
        0xD1A2: [1: "Off", 2: "Auto", 3: "Low"],
        0xD1A3: [1: "Off", 2: "Auto"],
        0xD1A4: [1: "Off", 2: "Auto"],
        0xD15E: [1: "sRGB", 2: "AdobeRGB"],
        0xD222: [0x01: "PC", 0x10: "Card", 0x11: "Card+PC"],
        0xD25A: [0: "Camera", 1: "PC"],
        // α7 V 实测（改菜单前后对比）：RAW = 1、RAW+HEIF = 4；HEIF = 5 与 SDK 和 0xD269 一致。全局与分卡槽的属性同一套值。
        // 压缩格式选 JPEG（0xD287 = 1）时的取值未测。
        0xD253: fileType, 0xD28B: fileType, 0xD28C: fileType,
        // 画质：实测「超精细」= 1、「精细」= 2、「标准」= 3（4 = 轻量，由排除法），和 SDK 的 CrImageQuality（1 = 轻量）正好相反。
        0xD252: quality, 0xD28D: quality, 0xD28E: quality,
        // 图像尺寸：实测 M = 2、S = 3，与 SDK 一致。
        0xD203: [1: "L", 2: "M", 3: "S"], 0xD28F: [1: "L", 2: "M", 3: "S"], 0xD290: [1: "L", 2: "M", 3: "S"],
        // RAW 压缩：实测「无损压缩」= 6、「压缩HQ」= 7、「压缩」= 1（α7 V 没有「未压缩」）。
        0xD288: rawCompression, 0xD289: rawCompression, 0xD28A: rawCompression,
        // 传到电脑的格式（libgphoto2 表；α7 V 实测 4 = ARW + HIF、5 = 只有 HIF）。
        0xD269: [1: "RAW+JPEG", 2: "JPEG", 3: "RAW", 4: "RAW+HEIF", 5: "HEIF"],
    ]

    static let fileType: [Int64: String] = [1: "RAW", 4: "RAW+HEIF", 5: "HEIF"]
    static let quality: [Int64: String] = [1: "ExFine", 2: "Fine", 3: "Standard", 4: "Light"]
    static let rawCompression: [Int64: String] = [6: "Lossless", 7: "CompressedHQ", 1: "Compressed"]

    /// 带符号整数参数（Creative Look 各项、曝光补偿以外的 ±n）。
    static let signedIntegers: Set<UInt16> = [0xD0FB, 0xD0FC, 0xD0FD, 0xD0FE, 0xD0FF, 0xD100, 0xD101, 0xD102]

    public static func label(_ code: UInt16, _ v: Int64) -> String? {
        if let t = valueLabels[code]?[v] { return t }
        switch code {
        case 0xD20D: return SonyFormat.shutterSpeed(v)
        case 0x5007: return SonyFormat.fNumber(v)
        case 0xD21E, 0xD226: return SonyFormat.iso(v)
        case 0x5010, 0xD224: return SonyFormat.exposureBias(v)
        case 0xD20F: return v > 0 ? "\(v)K" : nil
        case 0xD218: return v < 0 ? nil : "\(v)%"
        case 0xD21C, 0xD210: return colorTuning(code, v)
        default: return signedIntegers.contains(code) ? (v > 0 ? "+\(v)" : "\(v)") : nil
        }
    }

    /// 把输入解析成原始值：先认可读写法（在可选值里找），再认数字（十进制、0x 十六进制、+3）。
    /// allowed 为空时只按数字解析。
    public static func parse(_ code: UInt16, _ text: String, allowed: [Int64]) -> Int64? {
        let t = text.trimmingCharacters(in: .whitespaces)
        let key = normalize(t)
        // 1. 在可选值里找写法相同的。
        let candidates = allowed.isEmpty ? Array((valueLabels[code] ?? [:]).keys) : allowed
        if let hit = candidates.first(where: { v in label(code, v).map(normalize) == key }) { return hit }
        // 2. 少量格式差异：f/5.6、5.6、ISO 400、3200、1.8s、+0.3 EV。
        switch code {
        case 0x5007:
            let n = key.replacingOccurrences(of: "f/", with: "").replacingOccurrences(of: "f", with: "")
            if let d = Double(n) { return candidates.first { abs(Double($0) / 100 - d) < 0.051 } }
        case 0xD21E, 0xD226:
            let n = key.replacingOccurrences(of: "iso", with: "")
            if let i = Int64(n), let hit = candidates.first(where: { ($0 & 0x00FF_FFFF) == i && $0 >> 24 == 0 }) { return hit }
        case 0xD20F:
            if let i = Int64(key.replacingOccurrences(of: "k", with: "")) { return i }
        case 0xD20D:
            let s = key.replacingOccurrences(of: "s", with: "\"")
            if let hit = candidates.first(where: { label(code, $0).map(normalize) == s }) { return hit }
        case 0x5010, 0xD224:
            if let d = Double(key.replacingOccurrences(of: "ev", with: "")) {
                return candidates.first { abs(Double(Int16(truncatingIfNeeded: $0)) / 1000 - d) < 0.05 }
            }
        case 0xD21C, 0xD210:
            if let v = parseColorTuning(code, key) { return v }
        default: break
        }
        // 3. 原始值。
        if key.hasPrefix("0x"), let v = Int64(key.dropFirst(2), radix: 16) { return v }
        return Int64(key.hasPrefix("+") ? String(key.dropFirst()) : key)
    }

    // 白平衡微调：0xD21C A–B、0xD210 G–M，中心 192，每格 4（α7 V 实测 A2 = 200、G1 = 196）。
    // AB 的步进是 2（半格），GM 是 1（四分之一格）。A、G 为正。
    static func colorTuning(_ code: UInt16, _ v: Int64) -> String {
        let steps = Double(v - 192) / 4
        if steps == 0 { return "0" }
        let (pos, neg) = code == 0xD21C ? ("A", "B") : ("G", "M")
        let n = abs(steps)
        let text = n == n.rounded() ? String(Int(n)) : String(format: n * 2 == (n * 2).rounded() ? "%.1f" : "%.2f", n)
        return (steps > 0 ? pos : neg) + text
    }

    static func parseColorTuning(_ code: UInt16, _ key: String) -> Int64? {
        let (pos, neg) = code == 0xD21C ? ("a", "b") : ("g", "m")
        guard let first = key.first else { return nil }
        let sign: Double
        switch String(first) { case pos: sign = 1; case neg: sign = -1; default: return key == "0" ? 192 : nil }
        guard let n = Double(key.dropFirst()) else { return nil }
        let units = sign * n * 4
        guard units == units.rounded() else { return nil }
        return 192 + Int64(units)
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "±", with: "")
    }
}
