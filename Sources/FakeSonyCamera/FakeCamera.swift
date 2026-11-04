import Foundation
import Network
import SonyRemoteKit

/// 模拟的 PTP/IP 相机：在本机随机端口监听，按 handler 返回结果。
public final class FakeCamera: @unchecked Sendable {
    public struct Reply: Sendable {
        public var code: UInt16 = PTPResponse.ok
        public var params: [UInt32] = []
        public var data: Data? = nil
        public init(code: UInt16 = PTPResponse.ok, params: [UInt32] = [], data: Data? = nil) {
            self.code = code; self.params = params; self.data = data
        }
    }

    public typealias Handler = @Sendable (_ code: UInt16, _ params: [UInt32], _ dataOut: Data?) -> Reply

    private let listener: NWListener
    private let queue = DispatchQueue(label: "fakecamera")
    private let handler: Handler
    private let lock = NSLock()
    private var eventSocket: PTPIPSocket?
    private var sockets: [PTPIPSocket] = []
    public private(set) var receivedGUID: [UInt8] = []
    public var rejectWithInitFail: UInt32? = nil
    /// 收到这些操作码时不回复，用来模拟相机卡死。
    public var silentOperations: Set<UInt16> = []

    private(set) var log: [(code: UInt16, params: [UInt32], data: Data?)] = []

    public init(port: UInt16? = nil, handler: @escaping Handler) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: port.flatMap { NWEndpoint.Port(rawValue: $0) } ?? .any)
    }

    public func start() async throws -> UInt16 {
        let once = Once()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.claim() { cont.resume(returning: listener.port!.rawValue) }
                case .failed(let e): if once.claim() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                let sock = PTPIPSocket(accepted: conn)
                self.lock.withLock { self.sockets.append(sock) }
                Task { await self.serve(sock) }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
        lock.withLock { sockets.forEach { $0.close() } }
    }

    public func sendEvent(_ code: UInt16, _ params: [UInt32] = []) async throws {
        guard let s = lock.withLock({ eventSocket }) else { return }
        try await s.send(.event(code: code, transactionID: 0, params: params))
    }

    public var operations: [UInt16] { lock.withLock { log.map(\.code) } }

    private func serve(_ sock: PTPIPSocket) async {
        do {
            switch try await sock.receive() {
            case let .initCommandRequest(guid, _, _):
                lock.withLock { receivedGUID = guid }
                if let reason = rejectWithInitFail {
                    try await sock.send(.initFail(reason: reason))
                    return
                }
                try await sock.send(.initCommandAck(connectionNumber: 1, guid: [UInt8](repeating: 0xAB, count: 16),
                                                    name: "ILCE-7M4", version: PTPIPPacket.protocolVersion))
                try await commandLoop(sock)
            case .initEventRequest:
                lock.withLock { eventSocket = sock }
                try await sock.send(.initEventAck)
            default:
                sock.close()
            }
        } catch {}
    }

    private func commandLoop(_ sock: PTPIPSocket) async throws {
        while true {
            guard case let .operationRequest(phase, code, tid, params) = try await sock.receive() else { continue }
            var dataOut: Data? = nil
            if phase == .dataOut {
                var buf = Data()
                loop: while true {
                    switch try await sock.receive() {
                    case .startData: continue
                    case let .data(_, p): buf.append(p)
                    case let .endData(_, p): buf.append(p); break loop
                    default: break loop
                    }
                }
                dataOut = buf
            }
            lock.withLock { log.append((code, params, dataOut)) }
            if lock.withLock({ silentOperations.contains(code) }) { continue }
            let reply = handler(code, params, dataOut)
            if let data = reply.data {
                try await sock.send(.startData(transactionID: tid, totalLength: UInt64(data.count)))
                // 故意拆成多个 Data 包，验证客户端的拼接逻辑。
                let mid = data.count / 2
                try await sock.send(.data(transactionID: tid, payload: data.prefix(mid)))
                try await sock.send(.endData(transactionID: tid, payload: data.suffix(from: data.startIndex + mid)))
            }
            try await sock.send(.operationResponse(code: reply.code, transactionID: tid, params: reply.params))
        }
    }
}

final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
