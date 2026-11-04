import Foundation

/// PTP 与 PTP/IP 全部使用小端字节序。
public enum PTPDecodeError: Error, Equatable, Sendable {
    case truncated(needed: Int, available: Int)
    case invalid(String)
}

/// 按顺序写入小端二进制数据。
public struct PTPWriter: Sendable {
    public private(set) var bytes: [UInt8] = []

    public init() {}

    public var data: Data { Data(bytes) }

    public mutating func u8(_ v: UInt8) { bytes.append(v) }
    public mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.littleEndian) { bytes.append(contentsOf: $0) } }
    public mutating func i16(_ v: Int16) { u16(UInt16(bitPattern: v)) }
    public mutating func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
    public mutating func raw(_ d: Data) { bytes.append(contentsOf: d) }
    public mutating func raw(_ d: [UInt8]) { bytes.append(contentsOf: d) }

    /// PTP 字符串：1 字节字符数（含结尾 0），随后 UTF-16LE。空串只写一个 0。
    public mutating func ptpString(_ s: String) {
        if s.isEmpty { u8(0); return }
        let units = Array(s.utf16) + [0]
        u8(UInt8(min(units.count, 255)))
        for c in units.prefix(255) { u16(c) }
    }

    /// PTP/IP 握手包里的名字：UTF-16LE，以 0x0000 结尾，没有长度前缀。
    public mutating func utf16CString(_ s: String) {
        for c in s.utf16 { u16(c) }
        u16(0)
    }
}

/// 按顺序读取小端二进制数据，越界时抛错而不是崩溃。
public struct PTPReader: Sendable {
    public let bytes: [UInt8]
    public private(set) var offset: Int = 0

    public init(_ data: Data) { self.bytes = [UInt8](data) }
    public init(_ bytes: [UInt8]) { self.bytes = bytes }

    public var remaining: Int { bytes.count - offset }
    public var isAtEnd: Bool { remaining <= 0 }

    private mutating func take(_ n: Int) throws -> ArraySlice<UInt8> {
        guard n >= 0, remaining >= n else { throw PTPDecodeError.truncated(needed: n, available: remaining) }
        defer { offset += n }
        return bytes[offset..<(offset + n)]
    }

    private mutating func uint<T: FixedWidthInteger>(_: T.Type) throws -> T {
        let s = try take(MemoryLayout<T>.size)
        var v: T = 0
        for (i, b) in s.enumerated() { v |= T(b) << (8 * i) }
        return v
    }

    public mutating func u8() throws -> UInt8 { try uint(UInt8.self) }
    public mutating func u16() throws -> UInt16 { try uint(UInt16.self) }
    public mutating func u32() throws -> UInt32 { try uint(UInt32.self) }
    public mutating func u64() throws -> UInt64 { try uint(UInt64.self) }
    public mutating func i8() throws -> Int8 { Int8(bitPattern: try u8()) }
    public mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    public mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }
    public mutating func i64() throws -> Int64 { Int64(bitPattern: try u64()) }

    public mutating func raw(_ n: Int) throws -> [UInt8] { Array(try take(n)) }
    public mutating func skip(_ n: Int) throws { _ = try take(n) }
    public mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= bytes.count else { throw PTPDecodeError.invalid("seek \(newOffset) out of range") }
        offset = newOffset
    }

    public mutating func ptpString() throws -> String {
        let count = Int(try u8())
        guard count > 0 else { return "" }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    public mutating func utf16CString() throws -> String {
        var units: [UInt16] = []
        while true {
            let c = try u16()
            if c == 0 { break }
            units.append(c)
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// PTP 数组：uint32 元素个数，随后元素。
    public mutating func array<T>(_ read: (inout PTPReader) throws -> T) throws -> [T] {
        let n = Int(try u32())
        guard n <= remaining else { throw PTPDecodeError.invalid("array count \(n) exceeds data") }
        var out: [T] = []
        out.reserveCapacity(n)
        for _ in 0..<n { out.append(try read(&self)) }
        return out
    }
}
