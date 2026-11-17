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
        // 曝光模式：低 16 位与 SDK 的 CrExposureProgram 相同，高位是机身的模式组。α7 V 实测：拨杆在录像时 M = 0x78053，在 S&Q 时 M = 0x9805C。
        0x500E: [1: "M", 2: "P", 3: "A", 4: "S",
                 0x48000: "Auto", 0x10002: "P", 0x20003: "A", 0x30004: "S",
                 0x78054: "Movie Auto", 0x78050: "Movie P", 0x78051: "Movie A", 0x78052: "Movie S", 0x78053: "Movie M",
                 0x9805D: "S&Q Auto", 0x98059: "S&Q P", 0x9805A: "S&Q A", 0x9805B: "S&Q S", 0x9805C: "S&Q M",
                 // 间隔录像（SDK CrExposure_Movie_IntervalRec_*，0x8093–0x8097）：α7 V 实测写 0xC8093 回读为 Interval P。
                 0xC8097: "Interval Auto", 0xC8093: "Interval P", 0xC8094: "Interval A", 0xC8095: "Interval S", 0xC8096: "Interval M"],
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
        // 取白框大小（libgphoto2 / SDK：1 S、2 M、3 L）。
        0xD135: [1: "S", 2: "M", 3: "L"],
        // 记录媒体：α7 V 实测 1 只记录到卡槽 1、2 只记录到卡槽 2、257 同时记录、258 分类记录。
        0xD15F: [1: "Slot1", 2: "Slot2", 257: "Simultaneous", 258: "Sort"],
        // 图片配置文件：和 SDK 的 CrPictureProfile 一致（α7 V 列出 0、1–6、10、11、0x41–0x44，没有 PP7–9）。
        0xD23F: pictureProfile,
        // 伽马、色彩模式：和 SDK 一致，α7 V 实测 0x303 = S-Log3、8 = S-Gamut3.Cine（改 PP1 后对照机身菜单）。没有 S-Log2。
        0xD0E1: [1: "Movie", 2: "Still", 3: "S-Cinetone", 0x101: "Cine1", 0x102: "Cine2", 0x103: "Cine3", 0x104: "Cine4",
                 0x201: "ITU709", 0x202: "ITU709(800%)", 0x302: "S-Log2", 0x303: "S-Log3",
                 0x401: "HLG", 0x402: "HLG1", 0x403: "HLG2", 0x404: "HLG3"],
        0xD0E9: [1: "Movie", 2: "Still", 3: "S-Cinetone", 4: "Cinema", 5: "Pro", 6: "ITU709 Matrix", 7: "Black&White",
                 8: "S-Gamut3.Cine", 9: "S-Gamut3", 10: "BT.2020", 11: "709", 12: "S-Gamut", 13: "709tone"],
        0xD04D: [1: "Off", 2: "On"],
        0xD26A: [1: "Low", 2: "High"],
        // Log 拍摄（α7 V 用 0xE000 MovieShootingMode，只在 0x9209 带扩展参数时报告）：1 关、0x501 Flexible ISO（SDK CrLogShootingMode）。
        0xE000: [1: "Off", 0x501: "FlexibleISO"],
        0xE001: [1: "S-Gamut3.Cine", 2: "S-Gamut3"],
        // 触摸功能（SDK CrFunctionOfTouchOperation，从 1 开始）。α7 V 列出 {9, 8, 11, 10, 5, 1}，名称已和机身核对。
        0xD283: [1: "Off", 2: "Shutter", 3: "Focus", 4: "Tracking", 5: "AE", 6: "ShutterAE", 7: "ShutterNoAE",
                 8: "FocusAE", 9: "FocusNoAE", 10: "TrackingAE", 11: "TrackingNoAE"],
        0xD222: [0x01: "PC", 0x10: "Card", 0x11: "Card+PC"],
        0xD25A: [0: "Camera", 1: "PC"],
        // α7 V 实测（改菜单前后对比）：RAW = 1、RAW+HEIF = 4；HEIF = 5 与 SDK 和 0xD269 一致。全局与分卡槽的属性同一套值。
        // 压缩格式选 JPEG（0xD287 = 1）时可选 {1 RAW, 3 JPEG}（实测 3 在机身上显示 JPEG）。
        0xD253: fileType, 0xD28B: fileType, 0xD28C: fileType,
        // 画质：实测「超精细」= 1、「精细」= 2、「标准」= 3、「轻量」= 4，和 SDK 的 CrImageQuality（1 = 轻量）正好相反。
        0xD252: quality, 0xD28D: quality, 0xD28E: quality,
        // 图像尺寸：实测 M = 2、S = 3，与 SDK 一致。
        0xD203: [1: "L", 2: "M", 3: "S"], 0xD28F: [1: "L", 2: "M", 3: "S"], 0xD290: [1: "L", 2: "M", 3: "S"],
        // RAW 压缩：实测「无损压缩」= 6、「压缩HQ」= 7、「压缩」= 1（α7 V 没有「未压缩」）。
        0xD288: rawCompression, 0xD289: rawCompression, 0xD28A: rawCompression,
        // 传到电脑的格式（libgphoto2 表；α7 V 实测 4 = ARW + HIF、5 = 只有 HIF）。
        0xD269: [1: "RAW+JPEG", 2: "JPEG", 3: "RAW", 4: "RAW+HEIF", 5: "HEIF"],
        // 录像格式：α7 V 的取值和 SDK 的 CrFileFormatMovie 不同。逐个改值对照机身菜单核实：
        // 11 XAVC HS 4K、8 XAVC S 4K、9 XAVC S HD、14 XAVC S-I 4K、15 XAVC S-I HD。
        0xD241: [11: "XAVC HS 4K", 8: "XAVC S 4K", 9: "XAVC S HD", 14: "XAVC S-I 4K", 15: "XAVC S-I HD"],
        // 录像设置（码率 / 采样 / 位深）：和 SDK 的 CrRecordingSettingMovie 一致（实测 46 时录到 4K 59.94p 4:2:2 HEVC = 200M 4:2:2 10bit）。
        0xD242: movieRecordingSetting,
        // 录像帧率：和 SDK 的 CrRecordingFrameRateSettingMovie 一致（实测 3 时录到 59.94p）。NTSC 地区 60p 即 59.94p。
        0xD286: movieFrameRate,
        // S&Q 的记录帧率、录像设置：SDK 里和录像用同一套枚举。
        0xD0D0: movieFrameRate,
        0xD0D1: movieRecordingSetting,
        // 间隔录像的记录帧率、录像设置：α7 V 在间隔录像下列出的取值（10/8、46…64）和录像的一致，按同一套枚举。
        0xD151: movieFrameRate,
        0xD152: movieRecordingSetting,
    ]

    static let movieFrameRate: [Int64: String] = [1: "120p", 2: "100p", 3: "60p", 4: "50p", 5: "30p", 6: "25p", 7: "24p",
                                                   8: "23.98p", 9: "29.97p", 10: "59.94p", 0x16: "24.00p", 0x17: "119.88p"]

    /// SDK 2.00 的 CrRecordingSettingMovie，按枚举顺序从 1 开始。
    static let movieRecordingSetting: [Int64: String] = {
        let names = [
            "60p 50M", "30p 50M", "24p 50M", "50p 50M", "25p 50M", "60i 24M", "50i 24M", "60i 17M", "50i 17M", "60p 28M",
            "50p 28M", "24p 24M", "25p 24M", "24p 17M", "25p 17M", "120p 50M 720", "100p 50M 720", "30p 16M", "25p 16M", "30p 6M 720",
            "25p 6M 720", "60p 28M", "50p 28M", "60p 25M", "50p 25M", "30p 16M", "25p 16M", "120p 100M", "100p 100M", "120p 60M",
            "100p 60M", "30p 100M", "25p 100M", "24p 100M", "30p 60M", "25p 60M", "24p 60M",
            "600M 4:2:2 10bit", "500M 4:2:2 10bit", "400M 4:2:0 10bit", "300M 4:2:2 10bit", "280M 4:2:2 10bit", "250M 4:2:2 10bit",
            "240M 4:2:2 10bit", "222M 4:2:2 10bit", "200M 4:2:2 10bit", "200M 4:2:0 10bit", "200M 4:2:0 8bit", "185M 4:2:2 10bit",
            "150M 4:2:0 10bit", "150M 4:2:0 8bit", "140M 4:2:2 10bit", "111M 4:2:2 10bit", "100M 4:2:2 10bit", "100M 4:2:0 10bit",
            "100M 4:2:0 8bit", "93M 4:2:2 10bit", "89M 4:2:2 10bit", "75M 4:2:0 10bit", "60M 4:2:0 8bit", "50M 4:2:2 10bit",
            "50M 4:2:0 10bit", "50M 4:2:0 8bit", "45M 4:2:0 10bit", "30M 4:2:0 10bit", "25M 4:2:0 8bit", "16M 4:2:0 8bit",
            "520M 4:2:2 10bit", "260M 4:2:2 10bit",
        ]
        return Dictionary(uniqueKeysWithValues: names.enumerated().map { (Int64($0.offset + 1), $0.element) })
    }()

    static let basePresets: [Int64: String] = [1: "S-Log3", 2: "s709", 3: "709(800%)"]

    static let pictureProfile: [Int64: String] = {
        var m: [Int64: String] = [0: "Off"]
        for i in 1...11 { m[Int64(i)] = "PP\(i)" }
        for i in 1...4 { m[Int64(0x40 + i)] = "PP-LUT\(i)" }
        return m
    }()

    /// 文件格式：α7 V 实测 1 RAW、2 RAW+JPEG、3 JPEG、4 RAW+HEIF、5 HEIF（RAW+JPEG 只在统一记录时列出）。
    static let fileType: [Int64: String] = [1: "RAW", 2: "RAW+JPEG", 3: "JPEG", 4: "RAW+HEIF", 5: "HEIF"]
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
        // S&Q 帧率：取值就是帧数（α7 V 列出 120、60、30、15、8、4、2、1）。
        case 0xD052: return v > 0 ? "\(v)fps" : nil
        // Base Look：高字节是类型（0 预设、1 用户、2 场景文件、0x80 临时），低字节是序号。
        case 0xD03C:
            let i = v & 0xFF
            // α7 V 实测预设：1 S-Log3（不套 LUT）、2 s709、3 709(800%)。
            switch v >> 8 { case 0: return basePresets[i] ?? "Preset\(i)"; case 1: return "User\(i)"; case 2: return "Scene\(i)"; default: return nil }
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

    // MARK: 拍照 / 录像

    public enum ShootingMode: String, Sendable, CaseIterable { case photo, movie, sq, interval }

    /// 各模式组里的曝光模式值（照片的 P/A/S 另收旧机型的 2/3/4）。
    static let exposureGroups: [ShootingMode: [String: [Int64]]] = [
        .photo: ["auto": [0x48000], "p": [0x10002, 2], "a": [0x20003, 3], "s": [0x30004, 4], "m": [1]],
        .movie: ["auto": [0x78054], "p": [0x78050], "a": [0x78051], "s": [0x78052], "m": [0x78053]],
        .sq: ["auto": [0x9805D], "p": [0x98059], "a": [0x9805A], "s": [0x9805B], "m": [0x9805C]],
        // 间隔录像（视频延时，直接出成片）：α7 V 实测远程写 0xC8093 后回读为 Interval P。
        .interval: ["auto": [0xC8097], "p": [0xC8093], "a": [0xC8094], "s": [0xC8095], "m": [0xC8096]],
    ]

    /// 曝光模式值 → (拍照 / 录像, 曝光字母 auto/p/a/s/m)。不认识的返回 nil。
    public static func shootingMode(_ v: Int64) -> (mode: ShootingMode, exposure: String)? {
        for (mode, group) in exposureGroups {
            if let hit = group.first(where: { $0.value.contains(v) }) { return (mode, hit.key) }
        }
        return nil
    }

    /// 目标模式 + 曝光字母 → 相机可选值里对应的那个值。
    public static func exposureProgram(_ mode: ShootingMode, exposure: String, allowed: [Int64]) -> Int64? {
        guard let list = exposureGroups[mode]?[exposure.lowercased()] else { return nil }
        return list.first { allowed.isEmpty || allowed.contains($0) }
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
