import Foundation
import Network

/// PTP/IP 需要的最小传输能力：一条有序、可靠的字节流。
/// 两种实现：普通 TCP（NWByteStream）和 SSH 隧道里的 direct-tcpip 通道（SSHChannelStream）。
package protocol ByteStream: AnyObject, Sendable {
    /// 写完全部字节后返回。
    func send(_ data: Data) async throws
    /// 返回 1…maximumLength 个字节；对端关闭时抛错。
    func receive(maximumLength: Int) async throws -> Data
    /// 可重复调用；挂起的 send / receive 会以错误返回。
    func close()
}

/// 普通 TCP 连接。
package final class NWByteStream: ByteStream, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue

    package init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
        queue = DispatchQueue(label: "ptpip.\(host).\(port)")
    }

    /// 包装一条已被 NWListener 接受的连接（模拟相机用）。
    package init(accepted connection: NWConnection) {
        self.connection = connection
        queue = DispatchQueue(label: "ptpip.accepted.\(UUID().uuidString)")
    }

    package func open(timeout: TimeInterval) async throws {
        let once = OnceFlag()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { cont.resume() }
                case .failed(let err):
                    if once.claim() { cont.resume(throwing: PTPIPTransportError.connectionFailed(err.localizedDescription)) }
                case .waiting(let err):
                    // 局域网不可达、本地网络权限被拒时会进入 waiting 并持续重试，这里直接报错。
                    if once.claim() { cont.resume(throwing: PTPIPTransportError.connectionFailed(err.localizedDescription)) }
                case .cancelled:
                    if once.claim() { cont.resume(throwing: PTPIPTransportError.closed) }
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(throwing: PTPIPTransportError.connectTimeout) }
            }
        }
    }

    package func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { err in
                if let err { cont.resume(throwing: PTPIPTransportError.connectionFailed(err.localizedDescription)) }
                else { cont.resume() }
            })
        }
    }

    package func receive(maximumLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maximumLength) { data, _, isComplete, err in
                if let err { cont.resume(throwing: PTPIPTransportError.connectionFailed(err.localizedDescription)); return }
                if let data, !data.isEmpty { cont.resume(returning: data); return }
                if isComplete { cont.resume(throwing: PTPIPTransportError.closed); return }
                cont.resume(returning: Data())
            }
        }
    }

    package func close() { connection.cancel() }
}
