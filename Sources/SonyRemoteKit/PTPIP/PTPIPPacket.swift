import Foundation

/// PTP/IP（CIPA DC-005）包类型。
public enum PTPIPPacketType: UInt32, Sendable {
    case initCommandRequest = 1
    case initCommandAck = 2
    case initEventRequest = 3
    case initEventAck = 4
    case initFail = 5
    case operationRequest = 6
    case operationResponse = 7
    case event = 8
    case startData = 9
    case data = 10
    case cancel = 11
    case endData = 12
    case probeRequest = 13
    case probeResponse = 14
}

/// 操作请求里的数据阶段标记。
public enum PTPIPDataPhase: UInt32, Sendable {
    case noDataOrDataIn = 1   // 没有数据，或数据由相机发给手机
    case dataOut = 2          // 数据由手机发给相机
}

/// 一个 PTP/IP 包。线路格式：uint32 总长度（含 8 字节包头）+ uint32 类型 + 负载。
public enum PTPIPPacket: Sendable, Equatable {
    case initCommandRequest(guid: [UInt8], name: String, version: UInt32)
    case initCommandAck(connectionNumber: UInt32, guid: [UInt8], name: String, version: UInt32)
    case initEventRequest(connectionNumber: UInt32)
    case initEventAck
    case initFail(reason: UInt32)
    case operationRequest(phase: PTPIPDataPhase, code: UInt16, transactionID: UInt32, params: [UInt32])
    case operationResponse(code: UInt16, transactionID: UInt32, params: [UInt32])
    case event(code: UInt16, transactionID: UInt32, params: [UInt32])
    case startData(transactionID: UInt32, totalLength: UInt64)
    case data(transactionID: UInt32, payload: Data)
    case endData(transactionID: UInt32, payload: Data)
    case cancel(transactionID: UInt32)
    case probeRequest
    case probeResponse

    public static let protocolVersion: UInt32 = 0x0001_0000
    public static let headerSize = 8

    public var type: PTPIPPacketType {
        switch self {
        case .initCommandRequest: .initCommandRequest
        case .initCommandAck: .initCommandAck
        case .initEventRequest: .initEventRequest
        case .initEventAck: .initEventAck
        case .initFail: .initFail
        case .operationRequest: .operationRequest
        case .operationResponse: .operationResponse
        case .event: .event
        case .startData: .startData
        case .data: .data
        case .endData: .endData
        case .cancel: .cancel
        case .probeRequest: .probeRequest
        case .probeResponse: .probeResponse
        }
    }

    public func encoded() -> Data {
        var p = PTPWriter()
        switch self {
        case let .initCommandRequest(guid, name, version):
            p.raw(Self.pad(guid))
            p.utf16CString(name)
            p.u32(version)
        case let .initCommandAck(conn, guid, name, version):
            p.u32(conn)
            p.raw(Self.pad(guid))
            p.utf16CString(name)
            p.u32(version)
        case let .initEventRequest(conn):
            p.u32(conn)
        case .initEventAck, .probeRequest, .probeResponse:
            break
        case let .initFail(reason):
            p.u32(reason)
        case let .operationRequest(phase, code, tid, params):
            p.u32(phase.rawValue)
            p.u16(code)
            p.u32(tid)
            for v in params.prefix(5) { p.u32(v) }
        case let .operationResponse(code, tid, params), let .event(code, tid, params):
            p.u16(code)
            p.u32(tid)
            for v in params.prefix(5) { p.u32(v) }
        case let .startData(tid, total):
            p.u32(tid)
            p.u64(total)
        case let .data(tid, payload), let .endData(tid, payload):
            p.u32(tid)
            p.raw(payload)
        case let .cancel(tid):
            p.u32(tid)
        }
        var w = PTPWriter()
        w.u32(UInt32(Self.headerSize + p.bytes.count))
        w.u32(type.rawValue)
        w.raw(p.bytes)
        return w.data
    }

    /// 解析包头之后的负载。
    public static func decode(type rawType: UInt32, payload: [UInt8]) throws -> PTPIPPacket {
        guard let type = PTPIPPacketType(rawValue: rawType) else {
            throw PTPDecodeError.invalid("unknown PTP/IP packet type \(rawType)")
        }
        var r = PTPReader(payload)
        func params() throws -> [UInt32] {
            var out: [UInt32] = []
            while r.remaining >= 4 && out.count < 5 { out.append(try r.u32()) }
            return out
        }
        switch type {
        case .initCommandRequest:
            let guid = try r.raw(16)
            let name = try r.utf16CString()
            let version = r.remaining >= 4 ? try r.u32() : protocolVersion
            return .initCommandRequest(guid: guid, name: name, version: version)
        case .initCommandAck:
            let conn = try r.u32()
            let guid = try r.raw(16)
            let name = try r.utf16CString()
            let version = r.remaining >= 4 ? try r.u32() : protocolVersion
            return .initCommandAck(connectionNumber: conn, guid: guid, name: name, version: version)
        case .initEventRequest:
            return .initEventRequest(connectionNumber: try r.u32())
        case .initEventAck:
            return .initEventAck
        case .initFail:
            return .initFail(reason: r.remaining >= 4 ? try r.u32() : 0)
        case .operationRequest:
            let phase = PTPIPDataPhase(rawValue: try r.u32()) ?? .noDataOrDataIn
            let code = try r.u16()
            let tid = try r.u32()
            return .operationRequest(phase: phase, code: code, transactionID: tid, params: try params())
        case .operationResponse:
            let code = try r.u16()
            let tid = try r.u32()
            return .operationResponse(code: code, transactionID: tid, params: try params())
        case .event:
            let code = try r.u16()
            let tid = try r.u32()
            return .event(code: code, transactionID: tid, params: try params())
        case .startData:
            let tid = try r.u32()
            return .startData(transactionID: tid, totalLength: try r.u64())
        case .data:
            let tid = try r.u32()
            return .data(transactionID: tid, payload: Data(try r.raw(r.remaining)))
        case .endData:
            let tid = try r.u32()
            return .endData(transactionID: tid, payload: Data(try r.raw(r.remaining)))
        case .cancel:
            return .cancel(transactionID: try r.u32())
        case .probeRequest:
            return .probeRequest
        case .probeResponse:
            return .probeResponse
        }
    }

    private static func pad(_ guid: [UInt8]) -> [UInt8] {
        Array((guid + [UInt8](repeating: 0, count: 16)).prefix(16))
    }
}
