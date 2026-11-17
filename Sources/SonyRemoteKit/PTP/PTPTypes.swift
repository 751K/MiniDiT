import Foundation

/// 标准 PTP（ISO 15740）操作码。
public enum PTPOperation {
    public static let getDeviceInfo: UInt16 = 0x1001
    public static let openSession: UInt16 = 0x1002
    public static let closeSession: UInt16 = 0x1003
    public static let getStorageIDs: UInt16 = 0x1004
    public static let getObjectHandles: UInt16 = 0x1007
    public static let getObjectInfo: UInt16 = 0x1008
    public static let getObject: UInt16 = 0x1009
    public static let getDevicePropDesc: UInt16 = 0x1014
    public static let getDevicePropValue: UInt16 = 0x1015
    public static let setDevicePropValue: UInt16 = 0x1016
}

/// 标准 PTP 响应码。
public enum PTPResponse {
    public static let ok: UInt16 = 0x2001
    public static let generalError: UInt16 = 0x2002
    public static let sessionNotOpen: UInt16 = 0x2003
    public static let operationNotSupported: UInt16 = 0x2005
    public static let deviceBusy: UInt16 = 0x2019
    public static let accessDenied: UInt16 = 0x200F
    public static let invalidObjectHandle: UInt16 = 0x2009
    public static let sessionAlreadyOpen: UInt16 = 0x201E

    public static func name(_ code: UInt16) -> String {
        switch code {
        case ok: "OK"
        case generalError: "GeneralError"
        case sessionNotOpen: "SessionNotOpen"
        case operationNotSupported: "OperationNotSupported"
        case deviceBusy: "DeviceBusy"
        case accessDenied: "AccessDenied"
        case invalidObjectHandle: "InvalidObjectHandle"
        case sessionAlreadyOpen: "SessionAlreadyOpen"
        default: String(format: "0x%04X", code)
        }
    }
}

/// 标准 PTP 事件码。
public enum PTPEventCode {
    public static let objectAdded: UInt16 = 0x4002
    public static let devicePropChanged: UInt16 = 0x4006
}

/// PTP 数据类型码。
public enum PTPDataType: UInt16, Sendable {
    case undefined = 0x0000
    case int8 = 0x0001, uint8 = 0x0002
    case int16 = 0x0003, uint16 = 0x0004
    case int32 = 0x0005, uint32 = 0x0006
    case int64 = 0x0007, uint64 = 0x0008
    case int128 = 0x0009, uint128 = 0x000A
    case aint8 = 0x4001, auint8 = 0x4002
    case aint16 = 0x4003, auint16 = 0x4004
    case aint32 = 0x4005, auint32 = 0x4006
    case aint64 = 0x4007, auint64 = 0x4008
    case string = 0xFFFF
}

/// 设备属性的取值。所有整数统一存成 Int64，方便界面与编码互转。
public enum PTPValue: Sendable, Hashable, CustomStringConvertible {
    case int(Int64)
    case string(String)
    case array([Int64])
    case none

    public var intValue: Int64? { if case .int(let v) = self { v } else { nil } }

    public var description: String {
        switch self {
        case .int(let v): "\(v)"
        case .string(let s): "\"\(s)\""
        case .array(let a): "\(a)"
        case .none: "none"
        }
    }

    public static func read(_ type: PTPDataType, from r: inout PTPReader) throws -> PTPValue {
        switch type {
        case .undefined: return .none
        case .int8: return .int(Int64(try r.i8()))
        case .uint8: return .int(Int64(try r.u8()))
        case .int16: return .int(Int64(try r.i16()))
        case .uint16: return .int(Int64(try r.u16()))
        case .int32: return .int(Int64(try r.i32()))
        case .uint32: return .int(Int64(try r.u32()))
        case .int64: return .int(try r.i64())
        case .uint64: return .int(Int64(bitPattern: try r.u64()))
        case .int128, .uint128:
            try r.skip(16); return .none
        case .string: return .string(try r.ptpString())
        case .aint8, .auint8, .aint16, .auint16, .aint32, .auint32, .aint64, .auint64:
            let elem = PTPDataType(rawValue: type.rawValue & 0x0FFF) ?? .uint8
            let items = try r.array { r in try PTPValue.read(elem, from: &r).intValue ?? 0 }
            return .array(items)
        }
    }

    public func write(_ type: PTPDataType, to w: inout PTPWriter) {
        let v = intValue ?? 0
        switch type {
        case .int8, .uint8: w.u8(UInt8(truncatingIfNeeded: v))
        case .int16, .uint16: w.u16(UInt16(truncatingIfNeeded: v))
        case .int32, .uint32: w.u32(UInt32(truncatingIfNeeded: v))
        case .int64, .uint64: w.u64(UInt64(bitPattern: v))
        case .string:
            if case .string(let s) = self { w.ptpString(s) } else { w.ptpString("") }
        default: break
        }
    }
}

public struct PTPError: Error, LocalizedError, Sendable {
    public let operation: UInt16
    public let code: UInt16
    public init(operation: UInt16, code: UInt16) { self.operation = operation; self.code = code }
    public var errorDescription: String? {
        String(localized: "PTP 操作 \(String(format: "0x%04X", operation)) 失败：\(PTPResponse.name(code))", bundle: .miniDiT)
    }
}
