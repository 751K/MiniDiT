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
