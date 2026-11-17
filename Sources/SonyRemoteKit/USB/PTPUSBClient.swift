import Foundation

/// USB 上的一台 PTP 相机：能透传一条 PTP 命令、收事件。App 里是 ImageCaptureCore 的 `ICCameraDevice`，
/// 测试里是模拟相机。命令和事件都是 USB 容器（`u32 长度, u16 类型, u16 代码, u32 事务号, 参数…`）。
public protocol PTPPassthroughDevice: AnyObject, Sendable {
    var name: String { get }
    /// 发一条命令容器（可带「电脑 → 相机」数据），返回数据阶段的内容和响应容器。
    func send(command: Data, outData: Data?) async throws -> (data: Data, response: Data)
    /// 相机事件（事件容器）交给 handler。
    func setEventHandler(_ handler: @escaping @Sendable (Data) -> Void)
    /// 设备被拔掉或会话结束时调用一次。
    func setRemovalHandler(_ handler: @escaping @Sendable () -> Void)
    func close() async
}

/// USB 容器的编解码。
public enum PTPUSBContainer {
    public static let command: UInt16 = 1
    public static let data: UInt16 = 2
    public static let response: UInt16 = 3
    public static let event: UInt16 = 4

    public static func encode(type: UInt16, code: UInt16, transactionID: UInt32, params: [UInt32] = []) -> Data {
        var w = PTPWriter()
        w.u32(UInt32(12 + 4 * params.count)); w.u16(type); w.u16(code); w.u32(transactionID)
        params.forEach { w.u32($0) }
        return w.data
    }

    /// 解出容器头和参数（参数最多 5 个）。
    public static func decode(_ d: Data) -> (type: UInt16, code: UInt16, transactionID: UInt32, params: [UInt32])? {
        var r = PTPReader(d)
        guard let len = try? r.u32(), let type = try? r.u16(), let code = try? r.u16(), let tid = try? r.u32(),
              len >= 12, Int(len) <= d.count else { return nil }
        var params: [UInt32] = []
        for _ in 0..<min(5, (Int(len) - 12) / 4) { if let p = try? r.u32() { params.append(p) } }
        return (type, code, tid, params)
    }

    /// 透传返回的数据有时带着数据容器的 12 字节头，有时没有：带头（类型 2、长度正好等于整段）时去掉。
    public static func payload(_ d: Data) -> Data {
        guard d.count >= 12, let h = decode(d), h.type == data else { return d }
        var r = PTPReader(d)
        guard let len = try? r.u32(), Int(len) == d.count else { return d }
        return Data(d.dropFirst(12))
    }
}

public enum PTPUSBError: LocalizedError {
    case noResponse, disconnected
    public var errorDescription: String? {
        switch self {
        case .noResponse: String(localized: "相机没有返回有效的响应。", bundle: .miniDiT)
        case .disconnected: String(localized: "USB 连接已断开。", bundle: .miniDiT)
        }
    }
}

/// 通过 USB（ImageCaptureCore 的 PTP 透传）执行 PTP 事务。会话由系统打开，事务按顺序一条条发。
public actor PTPUSBClient: PTPTransport {
    private let device: any PTPPassthroughDevice
    public nonisolated let events: AsyncStream<PTPEvent>
    private let eventContinuation: AsyncStream<PTPEvent>.Continuation
    public let cameraName: String
    private var nextTransactionID: UInt32 = 1
    private var responseTimeout: TimeInterval = 30
    private let gate = AsyncGate()
    private var closed = false

    public init(device: any PTPPassthroughDevice) {
        self.device = device
        cameraName = device.name
        let (stream, cont) = AsyncStream.makeStream(of: PTPEvent.self, bufferingPolicy: .bufferingNewest(64))
        events = stream
        eventContinuation = cont
        device.setEventHandler { data in
            guard let c = PTPUSBContainer.decode(data), c.type == PTPUSBContainer.event else { return }
            cont.yield(PTPEvent(code: c.code, params: c.params))
        }
        device.setRemovalHandler { cont.finish() }
    }

    public func setResponseTimeout(_ t: TimeInterval) { responseTimeout = t }

    public func transaction(_ code: UInt16, _ params: [UInt32], dataOut: Data?, requireOK: Bool,
                            transactionID: UInt32?) async throws -> PTPTransactionResult {
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard !closed else { throw PTPUSBError.disconnected }
        let tid: UInt32
        if let transactionID { tid = transactionID } else { tid = nextTransactionID; nextTransactionID &+= 1 }
        let command = PTPUSBContainer.encode(type: PTPUSBContainer.command, code: code, transactionID: tid, params: params)
        let device = self.device, timeout = responseTimeout
        let (data, response) = try await withThrowingTaskGroup(of: (data: Data, response: Data)?.self) { group in
            group.addTask { try await device.send(command: command, outData: dataOut) }
            group.addTask { try await Task.sleep(for: .seconds(timeout)); return nil }
            let first = try await group.next() ?? nil
            group.cancelAll()
            guard let first else { throw PTPIPTransportError.responseTimeout }
            return first
        }
        guard let r = PTPUSBContainer.decode(response), r.type == PTPUSBContainer.response else { throw PTPUSBError.noResponse }
        if requireOK && r.code != PTPResponse.ok { throw PTPError(operation: code, code: r.code) }
        return PTPTransactionResult(code: r.code, params: r.params, data: PTPUSBContainer.payload(data))
    }

    /// 透传一次拿到整段数据：按块交给 sink，效果和 PTP/IP 的边收边写一致（只是先在内存里）。
    public func streamingTransaction(_ code: UInt16, _ params: [UInt32], onStart: @escaping @Sendable (UInt64) -> Void,
                                     sink: @escaping @Sendable (Data) throws -> Void) async throws -> PTPTransactionResult {
        let r = try await transaction(code, params, dataOut: nil, requireOK: true, transactionID: nil)
        onStart(UInt64(r.data.count))
        var offset = r.data.startIndex
        while offset < r.data.endIndex {
            let end = min(offset + (1 << 20), r.data.endIndex)
            try sink(r.data[offset..<end])
            offset = end
        }
        return PTPTransactionResult(code: r.code, params: r.params, data: Data())
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        await device.close()
        eventContinuation.finish()
    }

    public func disconnect() {
        guard !closed else { return }
        closed = true
        let device = self.device
        Task { await device.close() }
        eventContinuation.finish()
    }
}
