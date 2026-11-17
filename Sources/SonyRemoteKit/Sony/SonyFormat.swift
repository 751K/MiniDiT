import Foundation

/// 把索尼属性的原始数值转成界面文字。
public enum SonyFormat {
    /// 快门：高 16 位分子，低 16 位分母；0 = BULB。
    public static func shutterSpeed(_ v: Int64) -> String {
        let u = UInt32(truncatingIfNeeded: v)
        if u == 0 { return "BULB" }
        if u == 0xFFFF_FFFF { return "--" }
        let num = Int(u >> 16), den = Int(u & 0xFFFF)
        guard den > 0 else { return "--" }
        if num == 1 && den > 1 { return "1/\(den)" }
        if num % den == 0 { return "\(num / den)\"" }
        let seconds = Double(num) / Double(den)
        if seconds >= 0.3 { return String(format: "%.1f\"", seconds).replacingOccurrences(of: ".0\"", with: "\"") }
        return "\(num)/\(den)"
    }

    public static func fNumber(_ v: Int64) -> String {
        switch v {
        case 0, 0xFFFE, 0xFFFF: return "--"
        case 0xFFFD: return "关闭"
        default:
            let f = Double(v) / 100
            return f < 10 ? String(format: "F%.1f", f) : String(format: "F%.0f", f)
        }
    }

    /// ISO：低 24 位为数值（0xFFFFFF = AUTO），高 8 位为多帧降噪等标记。
    public static func iso(_ v: Int64) -> String {
        let u = UInt32(truncatingIfNeeded: v)
        let value = u & 0x00FF_FFFF
        let flags = u >> 24
        let base = value == 0x00FF_FFFF ? "AUTO" : "\(value)"
        if flags & 0x03 != 0 { return "多帧NR \(base)" }
        return base
    }

    /// 曝光补偿：EV × 1000，有符号 16 位。
    public static func exposureBias(_ v: Int64) -> String {
        let ev = Double(Int16(truncatingIfNeeded: v)) / 1000
        if abs(ev) < 0.05 { return "±0.0" }
        return String(format: "%+.1f", ev)
    }

    public static func whiteBalance(_ v: Int64) -> String {
        switch v {
        case 0x0002: "AWB"
        case 0x0004: "日光"
        case 0x0006: "白炽灯"
        case 0x0007: "闪光灯"
        case 0x8001: "荧光灯 暖白"
        case 0x8002: "荧光灯 冷白"
        case 0x8003: "荧光灯 日白"
        case 0x8004: "荧光灯 日光"
        case 0x8010: "阴天"
        case 0x8011: "阴影"
        case 0x8012: "色温"
        case 0x8020: "自定义 1"
        case 0x8021: "自定义 2"
        case 0x8022: "自定义 3"
        case 0x8023: "自定义"
        case 0x8030: "水下自动"
        case 0x0001: "手动"
        case 0x0005: "荧光灯"
        default: String(format: "WB %04X", v)
        }
    }

    /// 曝光模式（协议 3.00 为 UINT32；2.00 为低 16 位）。
    public static func exposureProgram(_ v: Int64) -> String {
        switch UInt32(truncatingIfNeeded: v) {
        case 0x0000_0001: "M 手动曝光"
        case 0x0001_0002: "P 程序自动"
        case 0x0002_0003: "A 光圈优先"
        case 0x0003_0004: "S 快门优先"
        case 0x0004_8000: "智能自动"
        case 0x0004_8001: "超级自动"
        case 0x0007_8050: "动态影像 P"
        case 0x0007_8051: "动态影像 A"
        case 0x0007_8052: "动态影像 S"
        case 0x0007_8053: "动态影像 M"
        case 0x0007_8054: "动态影像 智能自动"
        // α7 V 实测（拨杆拨到 S&Q：M = 0x9805C）；0x8808x 是旧机型的值。
        case 0x0009_8059: "S&Q P"
        case 0x0009_805A: "S&Q A"
        case 0x0009_805B: "S&Q S"
        case 0x0009_805C: "S&Q M"
        case 0x0009_805D: "S&Q 智能自动"
        case 0x0008_8084: "S&Q P"
        case 0x0008_8085: "S&Q A"
        case 0x0008_8086: "S&Q S"
        case 0x0008_8087: "S&Q M"
        // α7 V 实测：远程写 0xC8093 后回读为 Interval P（在 SDK 里叫 Movie_IntervalRec）。
        case 0x000C_8093: "间隔录像 P"
        case 0x000C_8094: "间隔录像 A"
        case 0x000C_8095: "间隔录像 S"
        case 0x000C_8096: "间隔录像 M"
        case 0x000C_8097: "间隔录像 智能自动"
        case 0x0000_8070: "照片效果"
        case 0x0000_8020: "调出记忆"
        default:
            switch UInt16(truncatingIfNeeded: v) {
            case 0x0001: "M 手动曝光"
            case 0x0002: "P 程序自动"
            case 0x0003: "A 光圈优先"
            case 0x0004: "S 快门优先"
            default: String(format: "模式 %X", v)
            }
        }
    }

    /// 联机窗口侧栏用的中文取值（和机身菜单的叫法一致）；没有中文写法的返回 nil，界面再用 SonyPropertyCatalog.label。
    public static func settingLabel(_ code: UInt16, _ v: Int64) -> String? {
        switch code {
        case 0x5013: return driveMode(v)?.label
        case 0xD201: return [1: "关", 0x1F: "自动", 0x11: "Lv1", 0x12: "Lv2", 0x13: "Lv3", 0x14: "Lv4", 0x15: "Lv5"][v]
        case 0xD287: return [1: "JPEG", 2: "HEIF 4:2:2", 3: "HEIF 4:2:0"][v]
        case 0xD252, 0xD28D, 0xD28E: return [1: "超精细", 2: "精细", 3: "标准", 4: "轻量"][v]
        case 0xD288, 0xD289, 0xD28A: return [6: "无损压缩", 7: "压缩 HQ", 1: "压缩"][v]
        case 0xD1A2: return [1: "关", 2: "自动", 3: "弱"][v]
        case 0xD1A3, 0xD1A4: return [1: "关", 2: "自动"][v]
        case 0xD135: return [1: "S", 2: "M", 3: "L"][v]
        case 0xD15F: return [1: "卡槽 1", 2: "卡槽 2", 257: "同时记录", 258: "分类记录"][v]
        // 触摸功能（SDK CrFunctionOfTouchOperation；α7 V 列出 1、5、8–11，名称已和机身核对，没有单独的触摸快门）。
        case 0xD283: return [1: "关", 2: "触摸快门", 3: "触摸对焦", 4: "触摸跟踪", 5: "触摸 AE", 6: "触摸快门 + AE",
                             7: "触摸快门", 8: "触摸对焦 + AE", 9: "触摸对焦", 10: "触摸跟踪 + AE", 11: "触摸跟踪"][v]
        case 0xD23F: return v == 0 ? "关" : nil
        case 0xD04D: return [1: "关", 2: "开"][v]
        // 间隔录像的拍摄间隔：取值就是秒数（α7 V 实测 5 = 机身显示 5 秒）。
        case 0xD055: return "\(v) 秒"
        case 0xE000: return [1: "关", 0x501: "开（Flexible ISO）"][v]
        case 0xD0E9: return v == 7 ? "黑白" : nil
        case 0xD03C:
            let i = v & 0xFF
            switch v >> 8 {
            case 0: return SonyPropertyCatalog.basePresets[i] ?? "预设 \(i)"
            case 1: return "用户 \(i)"
            case 2: return "场景文件 \(i)"
            default: return nil
            }
        // 褪色、锐度、锐度范围、清晰度没有负值：不加「+」。
        case 0xD0FE, 0xD100, 0xD101, 0xD102: return "\(v)"
        default: return nil
        }
    }

    /// 驱动模式（0x5013，UINT32）。取值表来自 libgphoto2 的 sony3_capturemode，包围档位按位解出：
    /// 高 16 位是类别（1 连拍、3 自拍、4 连续包围、5 单拍包围 …）；包围时次低字节 0x83/85/87/89 = 3/5/7/9 张、0xC2 = 2 张，
    /// 最低字节去掉 0x08（2 张时的「−」）后是档位，连续包围比单拍包围大 1。
    /// group 是菜单里的分组，sub 是包围的档位子菜单。
    public static func driveMode(_ v: Int64) -> (group: String, sub: String?, label: String)? {
        let named: [Int64: (String, String)] = [
            0x0000_0001: ("单张拍摄", "单张拍摄"),
            0x0001_0002: ("连拍", "连拍：高"), 0x0001_8010: ("连拍", "连拍：高+"), 0x0001_8011: ("连拍", "连拍：高（实时）"),
            0x0001_8012: ("连拍", "连拍：低"), 0x0001_8013: ("连拍", "连拍"), 0x0001_8014: ("连拍", "连拍：速度优先"),
            0x0001_8015: ("连拍", "连拍：中"), 0x0001_8016: ("连拍", "连拍：中（实时）"), 0x0001_8017: ("连拍", "连拍：低（实时）"),
            0x0002_0003: ("其他", "延时拍摄"),
            0x0003_8005: ("自拍", "自拍 2 秒"), 0x0003_8003: ("自拍", "自拍 5 秒"), 0x0003_8004: ("自拍", "自拍 10 秒"),
            0x0008_800E: ("自拍", "连续自拍 2 秒 3 张"), 0x0008_800F: ("自拍", "连续自拍 2 秒 5 张"),
            0x0008_800C: ("自拍", "连续自拍 5 秒 3 张"), 0x0008_800D: ("自拍", "连续自拍 5 秒 5 张"),
            0x0008_8008: ("自拍", "连续自拍 10 秒 3 张"), 0x0008_8009: ("自拍", "连续自拍 10 秒 5 张"),
            0x0007_8006: ("自拍", "自拍像 1 人"), 0x0007_8007: ("自拍", "自拍像 2 人"),
            0x0006_8018: ("其他包围", "白平衡包围：低"), 0x0006_8028: ("其他包围", "白平衡包围：高"),
            0x0007_8019: ("其他包围", "DRO 包围：低"), 0x0007_8029: ("其他包围", "DRO 包围：高"),
            0x0007_801A: ("其他包围", "LPF 包围"), 0x000A_8040: ("其他包围", "对焦包围"),
            0x0009_8030: ("连拍", "点连拍：低"), 0x0009_8031: ("连拍", "点连拍：中"), 0x0009_8032: ("连拍", "点连拍：高"),
            0x0007_800A: ("其他", "遥控器"), 0x0007_800B: ("其他", "反光镜预升"),
        ]
        if let n = named[v] { return (n.0, nil, n.1) }
        let kind = v >> 16, count = (v >> 8) & 0xFF, low = v & 0xFF
        guard kind == 4 || kind == 5 else { return nil }
        let steps: [Int64: String] = [0x36: "0.3", 0x56: "0.5", 0x76: "0.7", 0x10: "1.0", 0x40: "1.3", 0x60: "1.5",
                                      0x80: "1.7", 0x20: "2.0", 0x50: "2.3", 0x70: "2.5", 0x90: "2.7", 0x30: "3.0"]
        guard let ev = steps[(low & ~0x08) - (kind == 4 ? 1 : 0)] else { return nil }
        let pics: String
        switch count {
        case 0x83, 0x85, 0x87, 0x89:
            guard low & 0x08 == 0 else { return nil }
            pics = "\(count & 0x0F) 张"
        case 0xC2: pics = low & 0x08 == 0 ? "2 张 +" : "2 张 −"
        default: return nil
        }
        let group = kind == 4 ? "连续包围" : "单拍包围"
        return (group, "\(ev) EV", "\(group) \(ev) EV \(pics)")
    }

    public static func format(_ kind: CameraSettingKind, _ v: Int64) -> String {
        switch kind {
        case .shutterSpeed: shutterSpeed(v)
        case .aperture: fNumber(v)
        case .iso: iso(v)
        case .exposureCompensation: exposureBias(v)
        case .whiteBalance: whiteBalance(v)
        }
    }
}
