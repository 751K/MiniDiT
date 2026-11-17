import Foundation
import Network

public enum PTPIPTransportError: Error, LocalizedError, Sendable {
    case connectTimeout
    case connectionFailed(String)
    case closed
    case initFailed(reason: UInt32)
    case unexpectedPacket(String)
    case packetTooLarge(UInt32)
    case responseTimeout

    public var errorDescription: String? {
        switch self {
        case .connectTimeout: String(localized: "连接相机超时，请确认手机和相机在同一 Wi-Fi，且相机已开启「PC 遥控」。", bundle: .miniDiT)
        case .connectionFailed(let s): String(localized: "连接失败：\(s)", bundle: .miniDiT)
        case .closed: String(localized: "与相机的连接已断开。", bundle: .miniDiT)
        case .initFailed(let r):
            String(localized: "相机拒绝了连接（代码 \(r)）。请确认：①相机「访问认证」已关闭；②通过路由器连接时已在相机上完成配对；③手机上的 Creators' App 没有连着相机。", bundle: .miniDiT)
        case .unexpectedPacket(let s): String(localized: "收到意外的数据包：\(s)", bundle: .miniDiT)
        case .packetTooLarge(let n): String(localized: "数据包长度异常：\(n)", bundle: .miniDiT)
        case .responseTimeout: String(localized: "相机长时间没有响应，连接已断开。请检查 Wi-Fi 信号后重新连接。", bundle: .miniDiT)
        }
    }
}

/// 一条 PTP/IP 连接，按包收发。底层可以是普通 TCP，也可以是 SSH 隧道里的通道。
package final class PTPIPSocket: @unchecked Sendable {
    private let stream: any ByteStream
    private let timerQueue = DispatchQueue(label: "ptpip.timer")

    /// 普通 TCP（需要再调用 open）。
    package init(host: String, port: UInt16) {
        stream = NWByteStream(host: host, port: port)
    }

    /// 包装一条已被 NWListener 接受的连接（测试用的模拟相机会用到）。
    package init(accepted connection: NWConnection) {
        stream = NWByteStream(accepted: connection)
    }

    /// 已经建立好的字节流（例如 SSH 通道），不需要再 open。
    package init(stream: any ByteStream) {
        self.stream = stream
    }

    package func open(timeout: TimeInterval) async throws {
        if let nw = stream as? NWByteStream { try await nw.open(timeout: timeout) }
    }

    package func close() {
        stream.close()
    }

    package func send(_ packet: PTPIPPacket) async throws {
        try await sendRaw(packet.encoded())
    }

    package func sendRaw(_ data: Data) async throws {
        do {
            try await stream.send(data)
        } catch let e as PTPIPTransportError {
            throw e
        } catch {
            throw PTPIPTransportError.connectionFailed(String(describing: error))
        }
    }

    /// 带超时的读取（握手用）：超时后关闭连接，让挂起的 receive 以错误返回。
    package func receive(timeout: TimeInterval) async throws -> PTPIPPacket {
        do {
            return try await receive(inactivityTimeout: timeout)
        } catch PTPIPTransportError.responseTimeout {
            throw PTPIPTransportError.connectTimeout
        }
    }

    /// 读取一个完整的包。
    /// - inactivityTimeout: 连续这么久收不到任何字节就关闭连接并抛 responseTimeout（按字节活动计时，大文件不会误判）。
    /// - dataSink: 不为空时，Data / EndData 包的负载分块交给它（直接写文件），返回的包负载为空，避免整包进内存。
    package func receive(inactivityTimeout: TimeInterval? = nil,
                         dataSink: (@Sendable (Data) throws -> Void)? = nil) async throws -> PTPIPPacket {
        let header = try await receiveExactly(PTPIPPacket.headerSize, timeout: inactivityTimeout)
        var r = PTPReader(header)
        let length = try r.u32()
        let type = try r.u32()
        guard length >= UInt32(PTPIPPacket.headerSize) else { throw PTPIPTransportError.packetTooLarge(length) }
        let payloadLength = Int(length) - PTPIPPacket.headerSize

        let isData = type == PTPIPPacketType.data.rawValue || type == PTPIPPacketType.endData.rawValue
        if isData, let dataSink, payloadLength >= 4 {
            var tr = PTPReader(try await receiveExactly(4, timeout: inactivityTimeout))
            let tid = try tr.u32()
            var remaining = payloadLength - 4
            while remaining > 0 {
                let n = min(remaining, 1 << 20)
                try dataSink(Data(try await receiveExactly(n, timeout: inactivityTimeout)))
                remaining -= n
            }
            return type == PTPIPPacketType.data.rawValue ? .data(transactionID: tid, payload: Data())
                                                         : .endData(transactionID: tid, payload: Data())
        }
        // 非数据包不该很大；数据包不走 sink 时限制在 256MB 以内，防止内存爆掉。
        guard payloadLength <= (isData ? 256 : 16) * 1024 * 1024 else { throw PTPIPTransportError.packetTooLarge(length) }
        let payload = try await receiveExactly(payloadLength, timeout: inactivityTimeout)
        return try PTPIPPacket.decode(type: type, payload: payload)
    }

    /// 按字节读（富士的 USB 式容器用它自己分帧）。
    package func receiveBytes(_ count: Int, timeout: TimeInterval?) async throws -> [UInt8] {
        try await receiveExactly(count, timeout: timeout)
    }

    /// 读到多少算多少（丢弃不需要的数据流用）。
    package func receiveSome(max: Int, timeout: TimeInterval?) async throws -> Data {
        try await receiveChunk(max: max, timeout: timeout)
    }

    private func receiveExactly(_ count: Int, timeout: TimeInterval?) async throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count)
        while out.count < count {
            let chunk = try await receiveChunk(max: count - out.count, timeout: timeout)
            out.append(contentsOf: chunk)
        }
        return out
    }

    private func receiveChunk(max: Int, timeout: TimeInterval?) async throws -> Data {
        // 底层 receive 无法取消；超时就关闭连接，挂起的 receive 会以错误返回。
        let timedOut = OnceFlag()
        var timer: DispatchWorkItem?
        if let timeout {
            let t = DispatchWorkItem { [weak self] in if timedOut.claim() { self?.close() } }
            timerQueue.asyncAfter(deadline: .now() + timeout, execute: t)
            timer = t
        }
        do {
            let data: Data
            do {
                data = try await stream.receive(maximumLength: max)
            } catch let e as PTPIPTransportError {
                throw e
            } catch {
                throw PTPIPTransportError.closed
            }
            timer?.cancel()
            if timer != nil && !timedOut.claim() { throw PTPIPTransportError.responseTimeout }
            return data
        } catch {
            timer?.cancel()
            if timer != nil && !timedOut.claim() { throw PTPIPTransportError.responseTimeout }
            throw error
        }
    }
}

/// 保证续体只被恢复一次。
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
