import Foundation

/// 一次 PTP 事务的结果。
public struct PTPTransactionResult: Sendable {
    public let code: UInt16
    public let params: [UInt32]
    public let data: Data
}

public struct PTPEvent: Sendable, Equatable {
    public let code: UInt16
    public let params: [UInt32]
}

/// 发给相机的连接信息。GUID 需要在每台手机上保持不变，相机靠它记住已配对的设备。
public struct PTPIPHostIdentity: Sendable {
    public var guid: [UInt8]
    public var friendlyName: String

    public init(guid: [UInt8], friendlyName: String) {
        self.guid = guid
        self.friendlyName = friendlyName
    }

    public static func random(name: String) -> PTPIPHostIdentity {
        PTPIPHostIdentity(guid: (0..<16).map { _ in UInt8.random(in: 0...255) }, friendlyName: name)
    }
}

/// PTP/IP 发起方：命令通道 + 事件通道，事务严格串行。
public actor PTPIPClient {
    public static let defaultPort: UInt16 = 15740

    private let host: String
    private let port: UInt16
    private let identity: PTPIPHostIdentity
    /// 相机开启访问身份验证时，两条连接都走这条 SSH 隧道；客户端断开时一起关闭。
    private let tunnel: CameraSSHTunnel?
    private var command: PTPIPSocket?
    private var eventSocket: PTPIPSocket?
    private var eventTask: Task<Void, Never>?
    private var nextTransactionID: UInt32 = 1
    private let gate = AsyncGate()

    public private(set) var cameraName: String = ""
    /// 相机在 Init_Command_Ack 里报的 GUID（尼康以 USB 厂商号 04b0 开头）。
    public private(set) var cameraGUID: [UInt8] = []
    public nonisolated let events: AsyncStream<PTPEvent>
    private let eventContinuation: AsyncStream<PTPEvent>.Continuation

    public init(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity,
                tunnel: CameraSSHTunnel? = nil) {
        self.host = host
        self.port = port
        self.identity = identity
        self.tunnel = tunnel
        (events, eventContinuation) = AsyncStream.makeStream(of: PTPEvent.self, bufferingPolicy: .bufferingNewest(256))
    }

    /// 建立命令通道和事件通道（PTP/IP 握手）。
    public func connect(timeout: TimeInterval = 8) async throws {
        var openedCommand: PTPIPSocket?
        var openedEvent: PTPIPSocket?
        do {
            let cmd = try await openSocket(timeout: timeout)
            openedCommand = cmd
            try await cmd.send(.initCommandRequest(guid: identity.guid, name: identity.friendlyName, version: PTPIPPacket.protocolVersion))

            let connectionNumber: UInt32
            switch try await cmd.receive(timeout: timeout) {
            case let .initCommandAck(conn, guid, name, _):
                connectionNumber = conn
                cameraName = name
                cameraGUID = guid
            case let .initFail(reason):
                throw PTPIPTransportError.initFailed(reason: reason)
            case let other:
                throw PTPIPTransportError.unexpectedPacket("\(other.type)")
            }

            let evt = try await openSocket(timeout: timeout)
            openedEvent = evt
            try await evt.send(.initEventRequest(connectionNumber: connectionNumber))
            switch try await evt.receive(timeout: timeout) {
            case .initEventAck: break
            case let .initFail(reason):
                throw PTPIPTransportError.initFailed(reason: reason)
            case let other:
                throw PTPIPTransportError.unexpectedPacket("\(other.type)")
            }

            command = cmd
            eventSocket = evt
            openedCommand = nil
            openedEvent = nil
            startEventLoop(evt)
        } catch {
            // 握手失败的每一条路径都要关掉已经打开的 socket；走 SSH 时还要关掉隧道，
            // 否则它的 io 线程会一直活着，自动重连几次就耗尽 fd。
            openedCommand?.close()
            openedEvent?.close()
            tunnel?.close()
            cameraName = ""
            throw error
        }
    }

    private func openSocket(timeout: TimeInterval) async throws -> PTPIPSocket {
        if let tunnel { return try await tunnel.openPTPIPChannel() }
        let s = PTPIPSocket(host: host, port: port)
        try await s.open(timeout: timeout)
        return s
    }

    public var usesSSH: Bool { tunnel != nil }

    public func disconnect() {
        tunnel?.close()
        eventTask?.cancel()
        command?.close()
        eventSocket?.close()
        command = nil
        eventSocket = nil
        eventContinuation.finish()
    }

    public var isConnected: Bool { command != nil }

    private func startEventLoop(_ socket: PTPIPSocket) {
        let cont = eventContinuation
        eventTask = Task.detached {
            while !Task.isCancelled {
                do {
                    switch try await socket.receive() {
                    case let .event(code, _, params):
                        cont.yield(PTPEvent(code: code, params: params))
                    case .probeRequest:
                        try? await socket.send(.probeResponse)
                    default:
                        break
                    }
                } catch {
                    cont.finish()
                    return
                }
            }
        }
    }

    // MARK: 事务

    /// 每个包之间最长等待时间；超过就认为连接已死，拆掉连接（避免界面永远卡住）。
    public var responseTimeout: TimeInterval = 30

    public func setResponseTimeout(_ t: TimeInterval) { responseTimeout = t }

    /// 执行一次 PTP 事务。`dataOut` 不为空时走「手机 → 相机」数据阶段。
    @discardableResult
    public func transaction(_ code: UInt16, _ params: [UInt32] = [], dataOut: Data? = nil,
                            requireOK: Bool = true, transactionID: UInt32? = nil) async throws -> PTPTransactionResult {
        try await gated {
            try await self.performTransaction(code, params, dataOut: dataOut, requireOK: requireOK,
                                              transactionID: transactionID, sink: nil)
        }
    }

    /// 数据阶段不进内存，分块交给 sink（用于大文件直接写盘）。onStart 收到相机报告的总字节数。
    @discardableResult
    public func streamingTransaction(_ code: UInt16, _ params: [UInt32] = [],
                                     onStart: @escaping @Sendable (UInt64) -> Void = { _ in },
                                     sink: @escaping @Sendable (Data) throws -> Void) async throws -> PTPTransactionResult {
        try await gated {
            try await self.performTransaction(code, params, dataOut: nil, requireOK: true, transactionID: nil,
                                              sink: (onStart, sink))
        }
    }

    private func gated<T>(_ body: () async throws -> T) async throws -> T {
        await gate.acquire()
        do {
            let r = try await body()
            await gate.release()
            return r
        } catch {
            await gate.release()
            throw error
        }
    }

    private func performTransaction(_ code: UInt16, _ params: [UInt32], dataOut: Data?, requireOK: Bool,
                                    transactionID: UInt32?,
                                    sink: (onStart: @Sendable (UInt64) -> Void, write: @Sendable (Data) throws -> Void)?) async throws -> PTPTransactionResult {
        guard let cmd = command else { throw PTPIPTransportError.closed }
        let tid: UInt32
        if let transactionID { tid = transactionID } else { tid = nextTransactionID; nextTransactionID &+= 1 }

        do {
            try await cmd.send(.operationRequest(phase: dataOut == nil ? .noDataOrDataIn : .dataOut,
                                                 code: code, transactionID: tid, params: params))
            if let dataOut {
                var buf = PTPIPPacket.startData(transactionID: tid, totalLength: UInt64(dataOut.count)).encoded()
                buf.append(PTPIPPacket.endData(transactionID: tid, payload: dataOut).encoded())
                try await cmd.sendRaw(buf)
            }

            var incoming = Data()
            while true {
                let packet = try await cmd.receive(inactivityTimeout: responseTimeout, dataSink: sink?.write)
                switch packet {
                case let .startData(ptid, total):
                    guard ptid == tid else { continue }  // 上一个事务残留的包，丢弃
                    sink?.onStart(total)
                    if sink == nil { incoming.reserveCapacity(Int(min(total, 64 * 1024 * 1024))) }
                case let .data(ptid, payload), let .endData(ptid, payload):
                    guard ptid == tid else { continue }
                    incoming.append(payload)
                case let .operationResponse(rc, rtid, rparams):
                    // OpenSession（tid 0）有的机型回的 tid 不匹配，宽松处理。
                    guard rtid == tid || tid == 0 else { continue }
                    if requireOK && rc != PTPResponse.ok { throw PTPError(operation: code, code: rc) }
                    return PTPTransactionResult(code: rc, params: rparams, data: incoming)
                case .probeRequest:
                    try await cmd.send(.probeResponse)
                case let .event(ecode, _, eparams):
                    eventContinuation.yield(PTPEvent(code: ecode, params: eparams))
                default:
                    throw PTPIPTransportError.unexpectedPacket("\(packet.type)")
                }
            }
        } catch let e as PTPError {
            throw e  // 相机正常回复了错误码，连接本身没问题
        } catch {
            // 其余错误（超时、断线、协议错乱、sink 写盘失败或取消）都可能让数据流错位，直接拆掉连接。
            handleTransportFailure()
            throw error
        }
    }

    private func handleTransportFailure() {
        tunnel?.close()
        command?.close()
        eventSocket?.close()
        command = nil
        eventSocket = nil
        eventTask?.cancel()
        eventContinuation.finish()
    }

    /// 尽量体面地关闭：命令通道空闲时发 CloseSession（最多等 2 秒），否则直接断开，绝不等待卡住的事务。
    public func shutdown() async {
        if command != nil, await !gate.isBusy {
            let saved = responseTimeout
            responseTimeout = 2
            _ = try? await transaction(PTPOperation.closeSession, requireOK: false)
            responseTimeout = saved
        }
        disconnect()
    }

    // MARK: 标准操作

    public func openSession(id: UInt32 = 1) async throws {
        // OpenSession 的 TransactionID 按规范为 0。
        let r = try await transaction(PTPOperation.openSession, [id], requireOK: false, transactionID: 0)
        guard r.code == PTPResponse.ok || r.code == PTPResponse.sessionAlreadyOpen else {
            throw PTPError(operation: PTPOperation.openSession, code: r.code)
        }
        nextTransactionID = 1
    }

    public func closeSession() async throws {
        try await transaction(PTPOperation.closeSession, requireOK: false)
    }
}

/// 简单的异步互斥：保证同一时间只有一个事务在命令通道上。
actor AsyncGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    var isBusy: Bool { busy }
}

