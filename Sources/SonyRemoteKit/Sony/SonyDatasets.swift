import Foundation

/// 0x9209 返回的单个属性描述。
public struct SonyPropertyDesc: Sendable, Equatable {
    public enum Form: Sendable, Equatable {
        case none
        case range(min: Int64, max: Int64, step: Int64)
        case enumeration([Int64])
    }

    public let code: UInt16
    public let dataType: PTPDataType
    public let getSet: UInt8
    public let isEnabled: UInt8
    public let factoryDefault: PTPValue
    public let current: PTPValue
    public let form: Form

    public var isWritable: Bool { getSet == 1 && isEnabled == 1 }
    public var intValue: Int64? { current.intValue }

    /// 可选值列表：枚举直接用；范围在合理数量内展开。
    public var allowedValues: [Int64] {
        switch form {
        case .none: return []
        case .enumeration(let v): return v
        case let .range(lo, hi, step):
            guard step > 0, hi >= lo, (hi - lo) / step <= 400 else { return [] }
            return Array(stride(from: lo, through: hi, by: Int64.Stride(step)))
        }
    }

    public init(code: UInt16, dataType: PTPDataType, getSet: UInt8, isEnabled: UInt8,
                factoryDefault: PTPValue, current: PTPValue, form: Form) {
        self.code = code
        self.dataType = dataType
        self.getSet = getSet
        self.isEnabled = isEnabled
        self.factoryDefault = factoryDefault
        self.current = current
        self.form = form
    }

    /// 解析一条索尼 DPD 记录。
    static func parse(_ r: inout PTPReader) throws -> SonyPropertyDesc {
        let code = try r.u16()
        let rawType = try r.u16()
        guard let type = PTPDataType(rawValue: rawType) else {
            throw PTPDecodeError.invalid(String(format: "unknown datatype 0x%04X for 0x%04X", rawType, code))
        }
        let getSet = try r.u8()
        let enabled = try r.u8()
        let def = try PTPValue.read(type, from: &r)
        // 字符串属性有时在默认值之后就结束了。
        if type == .string && r.isAtEnd {
            return SonyPropertyDesc(code: code, dataType: type, getSet: getSet, isEnabled: enabled,
                                    factoryDefault: def, current: def, form: .none)
        }
        let cur = try PTPValue.read(type, from: &r)
        let formFlag = try r.u8()
        var form = Form.none
        switch formFlag {
        case 1:
            let lo = try PTPValue.read(type, from: &r).intValue ?? 0
            let hi = try PTPValue.read(type, from: &r).intValue ?? 0
            let st = try PTPValue.read(type, from: &r).intValue ?? 0
            form = .range(min: lo, max: hi, step: st)
        case 2:
            var list = try readEnum(type, &r)
            // 2024 年后的机型在第一个列表后还有第二个列表；下一个 u16 若 < 0x200 就是它的长度
            //（否则是下一条记录的属性码，0x5xxx/0xDxxx）。与 libgphoto2 一致，用第二个列表。
            if r.remaining >= 2 {
                let save = r.offset
                let peek = try r.u16()
                try r.seek(to: save)
                if peek < 0x200 {
                    list = try readEnum(type, &r)
                }
            }
            form = .enumeration(list)
        default:
            break
        }
        return SonyPropertyDesc(code: code, dataType: type, getSet: getSet, isEnabled: enabled,
                                factoryDefault: def, current: cur, form: form)
    }

    private static func readEnum(_ type: PTPDataType, _ r: inout PTPReader) throws -> [Int64] {
        let n = Int(try r.u16())
        var out: [Int64] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try PTPValue.read(type, from: &r).intValue ?? 0) }
        return out
    }

    /// 编码一条记录（模拟相机和测试用）。
    public func encoded(twinList: Bool = false) -> [UInt8] {
        var w = PTPWriter()
        w.u16(code)
        w.u16(dataType.rawValue)
        w.u8(getSet)
        w.u8(isEnabled)
        factoryDefault.write(dataType, to: &w)
        current.write(dataType, to: &w)
        switch form {
        case .none: w.u8(0)
        case let .range(lo, hi, st):
            w.u8(1)
            for v in [lo, hi, st] { PTPValue.int(v).write(dataType, to: &w) }
        case .enumeration(let list):
            w.u8(2)
            w.u16(UInt16(list.count))
            for v in list { PTPValue.int(v).write(dataType, to: &w) }
            if twinList {
                w.u16(UInt16(list.count))
                for v in list { PTPValue.int(v).write(dataType, to: &w) }
            }
        }
        return w.bytes
    }
}

public enum SonyDatasets {
    /// 解析 0x9209 的全部属性。遇到无法解析的记录时停止，保留已解析的部分（与 libgphoto2 行为一致）。
    public static func parseAllProperties(_ data: Data) -> [UInt16: SonyPropertyDesc] {
        var r = PTPReader(data)
        guard (try? r.skip(8)) != nil else { return [:] }
        var out: [UInt16: SonyPropertyDesc] = [:]
        while r.remaining >= 6 {
            guard let d = try? SonyPropertyDesc.parse(&r) else { break }
            out[d.code] = d
        }
        return out
    }

    public static func encodeAllProperties(_ props: [SonyPropertyDesc], twinList: Bool = false) -> Data {
        var w = PTPWriter()
        w.u32(UInt32(props.count))
        w.u32(0)
        for p in props { w.raw(p.encoded(twinList: twinList)) }
        return w.data
    }

    public struct ExtDeviceInfo: Sendable, Equatable {
        public let version: UInt16
        public let codes: Set<UInt16>
    }

    /// 解析 0x9202：u16 版本 + 两个 u16 数组（属性 / 控制码）。
    public static func parseExtDeviceInfo(_ data: Data) throws -> ExtDeviceInfo {
        var r = PTPReader(data)
        let version = try r.u16()
        var codes = Set<UInt16>()
        if r.remaining >= 4 { codes.formUnion(try r.array { try $0.u16() }) }
        if r.remaining >= 4 { codes.formUnion(try r.array { try $0.u16() }) }
        return ExtDeviceInfo(version: version, codes: codes)
    }

    /// 从 0xFFFFC002 的数据里取出 JPEG。头部：u32 JPEG 偏移、u32 JPEG 长度。
    /// 取景数据集里的对焦框信息（头部 8–11 字节是偏移、12–15 是长度）。没有或解不出时为空。
    public static func extractFocalFrames(_ data: Data) -> FocalFrameInfo? {
        let bytes = [UInt8](data)
        var r = PTPReader(bytes)
        guard (try? r.u32()) != nil, (try? r.u32()) != nil, let o = try? r.u32(), let n = try? r.u32(),
              n >= 56, Int(o) + Int(n) <= bytes.count else { return nil }
        return FocalFrameInfo.parse(Array(bytes[Int(o)..<Int(o) + Int(n)]))
    }

    public static func extractLiveViewJPEG(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        var r = PTPReader(bytes)
        if let offset = try? r.u32(), let size = try? r.u32(), size > 0 {
            let o = Int(offset), s = Int(size)
            if o >= 8, o + 1 < bytes.count, bytes[o] == 0xFF, bytes[o + 1] == 0xD8 {
                return Data(bytes[o..<min(bytes.count, o + s)])
            }
        }
        // 兜底：跳过头部再找 FFD8 … FFD9，避免误匹配到头部里的 FF D8。
        let searchStart = min(bytes.count, 8)
        guard let start = findMarker(bytes, 0xD8, from: searchStart) else { return nil }
        var end = bytes.count
        var i = bytes.count - 2
        while i > start {
            if bytes[i] == 0xFF && bytes[i + 1] == 0xD9 { end = i + 2; break }
            i -= 1
        }
        return Data(bytes[start..<end])
    }

    private static func findMarker(_ b: [UInt8], _ marker: UInt8, from: Int) -> Int? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 0xFF && b[i + 1] == marker { return i }
            i += 1
        }
        return nil
    }
}


/// 取景画面上的对焦框、人脸框、跟踪框（Sony PTP 的 FocalFrameInfo，结构照 sony-alpha-python 的解析）。
/// 坐标归一化到 0…1：cx、cy 是框中心，w、h 是宽高，都相对整幅取景画面。
public struct FocalFrameInfo: Sendable, Equatable {
    public struct Frame: Sendable, Equatable {
        public enum Kind: String, Sendable { case focus, face, tracking }
        public let kind: Kind
        /// 类型：对焦框 1 相位检测（AF 传感器）、2 相位检测（图像传感器）、3 广域、4 区域…；跟踪框 2 = 正在对焦的目标。
        public let type: UInt16
        /// 状态：1 未合焦、2 合焦（对焦框另有 3 选择中、4 移动中等）。
        public let state: UInt16
        public let cx: Double, cy: Double, w: Double, h: Double
        public var focused: Bool { state == 2 }
    }
    /// 版本 ×100（100 = 1.00）。1.01 起有人脸框和跟踪框。
    public let version: UInt16
    public let frames: [Frame]

    static func parse(_ b: [UInt8]) -> FocalFrameInfo? {
        func u16(_ i: Int) -> Int? { i + 2 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : nil }
        func u32(_ i: Int) -> Int? { i + 4 <= b.count ? Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 : nil }
        guard let version = u16(0) else { return nil }
        var pos = 48                                     // 版本 + 保留 6 + 保留 40
        guard let reserved = u16(pos) else { return nil }
        pos += 8 + reserved * 24
        var frames: [Frame] = []
        // 一段：X 分母、Y 分母、个数、保留 6，然后每个 24 字节：类型、状态、优先级…、X、Y、高、宽。
        func section(_ kind: Frame.Kind) {
            guard let xd = u32(pos), let yd = u32(pos + 4), let count = u16(pos + 8) else { pos = b.count; return }
            var e = pos + 16
            for _ in 0..<count {
                guard e + 24 <= b.count else { break }
                if xd > 0, yd > 0, let t = u16(e), let st = u16(e + 2), let x = u32(e + 8), let y = u32(e + 12),
                   let h = u32(e + 16), let w = u32(e + 20), w > 0 || h > 0 {
                    frames.append(Frame(kind: kind, type: UInt16(t), state: UInt16(st), cx: Double(x) / Double(xd),
                                        cy: Double(y) / Double(yd), w: Double(w) / Double(xd), h: Double(h) / Double(yd)))
                }
                e += 24
            }
            pos += 16 + count * 24
        }
        section(.focus)
        if version >= 101, pos < b.count { section(.face) }
        if version >= 101, pos < b.count { section(.tracking) }
        return FocalFrameInfo(version: UInt16(version), frames: frames)
    }
}


/// 跟焦位置 ↔ 对焦距离的换算表（0x9223 SDIO_GetLensInformation，type 2 = 米表）。
/// α7 V 实测格式：头部 u32 偏移、u32 长度；表本身是 u16 版本（100）、u16 类型、u16 条数、2 字节保留，
/// 然后每条 u32 跟焦位置 + u32 距离（厘米，0xFFFF = ∞），从近到远（位置从大到小）。
public struct LensDistanceTable: Sendable, Equatable {
    public struct Entry: Sendable, Equatable { public let position: Int64; public let centimeters: Int64 }
    public let entries: [Entry]

    public static func parse(_ data: Data) -> LensDistanceTable? {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int64? {
            i + 4 <= b.count ? Int64(b[i]) | Int64(b[i + 1]) << 8 | Int64(b[i + 2]) << 16 | Int64(b[i + 3]) << 24 : nil
        }
        guard let offset = u32(0), let size = u32(4), offset >= 8, Int(offset + size) <= b.count, size >= 8 else { return nil }
        let o = Int(offset)
        let count = Int(b[o + 4]) | Int(b[o + 5]) << 8
        guard count >= 2, o + 8 + count * 8 <= b.count else { return nil }
        let entries = (0..<count).compactMap { i -> Entry? in
            guard let p = u32(o + 8 + i * 8), let d = u32(o + 12 + i * 8) else { return nil }
            return Entry(position: p, centimeters: d)
        }.sorted { $0.position > $1.position }
        return LensDistanceTable(entries: entries)
    }

    /// 某个跟焦位置的距离（米）：在相邻两条之间按 1 / 距离插值（对焦行程大致和它成正比，∞ 那一段也能自然过渡）。
    public func meters(at position: Int64) -> Double? {
        guard let first = entries.first, let last = entries.last else { return nil }
        func inverse(_ e: Entry) -> Double { e.centimeters >= 0xFFFF ? 0 : 100 / Double(e.centimeters) }
        let inv: Double
        if position >= first.position { inv = inverse(first) }
        else if position <= last.position { inv = inverse(last) }
        else {
            guard let (near, far) = zip(entries, entries.dropFirst()).first(where: { position <= $0.0.position && position >= $0.1.position })
            else { return nil }
            let t = Double(near.position - position) / Double(near.position - far.position)
            inv = inverse(near) + (inverse(far) - inverse(near)) * t
        }
        return inv <= 0 ? .infinity : 1 / inv
    }

    /// 反过来：某个距离（米，∞ 用 .infinity）对应的跟焦位置，同样按 1 / 距离插值；超出镜头范围时取最近 / 最远端。
    public func position(forMeters meters: Double) -> Int64? {
        guard let first = entries.first, let last = entries.last, meters > 0 else { return nil }
        func inverse(_ e: Entry) -> Double { e.centimeters >= 0xFFFF ? 0 : 100 / Double(e.centimeters) }
        let want = meters.isInfinite ? 0 : 1 / meters
        if want >= inverse(first) { return first.position }
        if want <= inverse(last) { return last.position }
        for (near, far) in zip(entries, entries.dropFirst()) where want <= inverse(near) && want >= inverse(far) {
            let span = inverse(near) - inverse(far)
            let t = span > 0 ? (inverse(near) - want) / span : 0
            return near.position - Int64((Double(near.position - far.position) * t).rounded())
        }
        return nil
    }

    /// 显示用：0.45 m、1.2 m、12 m、∞。
    public static func text(_ meters: Double) -> String {
        if meters.isInfinite { return "∞" }
        if meters < 1 { return String(format: "%.2f m", meters) }
        if meters < 10 { return String(format: "%.1f m", meters) }
        return String(format: "%.0f m", meters)
    }
}
