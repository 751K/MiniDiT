import Foundation

/// xxHash64（种子 0），按 https://github.com/Cyan4973/xxHash 的规范实现，可以分块喂数据。
///
/// 导入时用它校验文件：和 DIT 软件、ASC MHL 报告用的是同一种哈希。
/// App 是 Debug 编译的，热循环加了 `@_optimize(speed)`，否则会慢十几倍。
public struct XXH64: Sendable {
    private static let p1: UInt64 = 11_400_714_785_074_694_791
    private static let p2: UInt64 = 14_029_467_366_897_019_727
    private static let p3: UInt64 = 1_609_587_929_392_839_161
    private static let p4: UInt64 = 9_650_029_242_287_828_579
    private static let p5: UInt64 = 2_870_177_450_012_600_261

    private var v1: UInt64
    private var v2: UInt64
    private var v3: UInt64
    private var v4: UInt64
    private var total: UInt64 = 0
    /// 不满 32 字节的尾巴，等下一块数据凑齐。
    private var buf = [UInt8](repeating: 0, count: 32)
    private var bufLen = 0

    public init(seed: UInt64 = 0) {
        v1 = seed &+ Self.p1 &+ Self.p2
        v2 = seed &+ Self.p2
        v3 = seed
        v4 = seed &- Self.p1
    }

    @inline(__always) private static func rotl(_ x: UInt64, _ r: UInt64) -> UInt64 { (x << r) | (x >> (64 - r)) }

    @inline(__always) private static func round(_ acc: UInt64, _ input: UInt64) -> UInt64 {
        rotl(acc &+ input &* p2, 31) &* p1
    }

    @inline(__always) private static func merge(_ acc: UInt64, _ val: UInt64) -> UInt64 {
        (acc ^ round(0, val)) &* p1 &+ p4
    }

    @inline(__always) private static func load64(_ p: UnsafeRawPointer, _ offset: Int = 0) -> UInt64 {
        UInt64(littleEndian: p.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
    }

    @_optimize(speed)
    public mutating func update(_ data: UnsafeRawBufferPointer) {
        guard var ptr = data.baseAddress, data.count > 0 else { return }
        var len = data.count
        total &+= UInt64(len)

        if bufLen + len < 32 {
            let at = bufLen
            buf.withUnsafeMutableBytes { $0.baseAddress!.advanced(by: at).copyMemory(from: ptr, byteCount: len) }
            bufLen += len
            return
        }

        var a = v1, b = v2, c = v3, d = v4
        if bufLen > 0 {
            let fill = 32 - bufLen, at = bufLen
            buf.withUnsafeMutableBytes { raw in
                let p = raw.baseAddress!
                p.advanced(by: at).copyMemory(from: ptr, byteCount: fill)
                a = Self.round(a, Self.load64(p, 0))
                b = Self.round(b, Self.load64(p, 8))
                c = Self.round(c, Self.load64(p, 16))
                d = Self.round(d, Self.load64(p, 24))
            }
            ptr += fill
            len -= fill
            bufLen = 0
        }
        while len >= 32 {
            a = Self.round(a, Self.load64(ptr, 0))
            b = Self.round(b, Self.load64(ptr, 8))
            c = Self.round(c, Self.load64(ptr, 16))
            d = Self.round(d, Self.load64(ptr, 24))
            ptr += 32
            len -= 32
        }
        v1 = a; v2 = b; v3 = c; v4 = d
        if len > 0 {
            let rest = ptr
            buf.withUnsafeMutableBytes { $0.baseAddress!.copyMemory(from: rest, byteCount: len) }
            bufLen = len
        }
    }

    public mutating func update(_ data: Data) {
        data.withUnsafeBytes { update($0) }
    }

    @_optimize(speed)
    public func digest() -> UInt64 {
        var h: UInt64
        if total >= 32 {
            h = Self.rotl(v1, 1) &+ Self.rotl(v2, 7) &+ Self.rotl(v3, 12) &+ Self.rotl(v4, 18)
            h = Self.merge(h, v1)
            h = Self.merge(h, v2)
            h = Self.merge(h, v3)
            h = Self.merge(h, v4)
        } else {
            h = v3 &+ Self.p5     // v3 就是种子
        }
        h &+= total
        let n = bufLen
        buf.withUnsafeBytes { raw in
            let p = raw.baseAddress!
            var i = 0
            while i + 8 <= n {
                h ^= Self.round(0, Self.load64(p, i))
                h = Self.rotl(h, 27) &* Self.p1 &+ Self.p4
                i += 8
            }
            if i + 4 <= n {
                h ^= UInt64(UInt32(littleEndian: p.loadUnaligned(fromByteOffset: i, as: UInt32.self))) &* Self.p1
                h = Self.rotl(h, 23) &* Self.p2 &+ Self.p3
                i += 4
            }
            while i < n {
                h ^= UInt64(p.load(fromByteOffset: i, as: UInt8.self)) &* Self.p5
                h = Self.rotl(h, 11) &* Self.p1
                i += 1
            }
        }
        h ^= h >> 33
        h &*= Self.p2
        h ^= h >> 29
        h &*= Self.p3
        h ^= h >> 32
        return h
    }

    public static func hash(_ data: Data) -> UInt64 {
        var x = XXH64()
        x.update(data)
        return x.digest()
    }

    /// 16 位小写十六进制（xxhsum 和 MHL 里的写法）。
    public static func hex(_ h: UInt64) -> String {
        let s = String(h, radix: 16)
        return String(repeating: "0", count: 16 - s.count) + s
    }
}
