import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 大疆相机 Wi-Fi 热点上的 UDP 数据通道（192.168.2.1:9004）：注册、进入回放模式、列文件、状态推送。
/// 资料来自 osmosis 的 MEDIA_PROTOCOL.md「Datalink session」和 OsmoOffload 的 datalink / session（MIT），
/// 见 THIRD_PARTY_NOTICES.md。
///
/// 每个 UDP 包 = [8 字节传输头][12 字节路由头][DUML 帧]。
///   传输头：[长度|0x8000 u16][会话 ID u16][序号 u16][包类型 u8][前 7 字节异或]
///   路由头：[ackSeq u16][ownSeq u16] 00 00 00 00 [计数 u8] 01 00 00
/// 关键：ownSeq 从相机通道号 + 8 开始、每条命令 +8，ackSeq = ownSeq − 8（不是相机遥测的序号），
/// 错了的话读命令还能回、写命令被悄悄丢掉。
///
/// 所有方法都是阻塞的，只能在一个线程上依次调用（DJICameraLibrary 用自己的串行队列）。
public final class DJIDatalink: @unchecked Sendable {
    public struct Status: Sendable {
        public var playback: Bool?
        public var recording: Bool?
        public var batteryPercent: Int?
        public var cardTotalMiB: UInt32?
        public var cardFreeMiB: UInt32?
    }

    public enum Failure: LocalizedError {
        case socket(String), handshake(UInt16), listUnanswered
        public var errorDescription: String? {
            switch self {
            case .socket(let s): String(localized: "无法打开数据连接：\(s)", bundle: .miniDiT)
            case .handshake(let port): String(localized: "相机没有响应数据连接（UDP \(port)）。请确认电脑已连上相机的 Wi-Fi。", bundle: .miniDiT)
            case .listUnanswered: String(localized: "相机没有返回文件列表。可能还保持着上一次的连接，请将相机关机再开机后重试。", bundle: .miniDiT)
            }
        }
    }

    public let host: String
    public let port: UInt16
    public private(set) var status = Status()
    private var fd: Int32 = -1
    private var sessionID: UInt16 = 0
    private var baseSeq: UInt16 = 0
    private var channel: UInt16 = 0
    private var udpSeq: UInt16 = 0
    private var peerCursor: UInt16 = 0
    private var peerDownloadCursor: UInt16 = 0
    private var dumlSeq: UInt16 = 0xA000
    private var counter: UInt8 = 0
    private let log: @Sendable (String) -> Void

    private let bindLocal: Bool

    /// - bindLocal: 本地也绑定同一个端口（和官方 App 一样）；测试时和模拟相机在同一台机器上，要关掉。
    public init(host: String = "192.168.2.1", port: UInt16 = 9004, bindLocal: Bool = true, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.host = host; self.port = port; self.bindLocal = bindLocal; self.log = log
    }

    deinit { if fd >= 0 { Darwin.close(fd) } }

    // MARK: 建立

    /// 打开会话：先在 TCP 7001 上「敲一下门」（大多数 Osmo 要这一步），再做 UDP 握手。
    public func open(identifier: String, tcpPoke: Bool = true) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.socket(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        // 和官方 App 一样本地也用同一个端口；被占用时用随机端口。
        var local = sockaddr_in(); local.sin_family = sa_family_t(AF_INET); local.sin_port = port.bigEndian
        local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        if bindLocal {
            _ = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        var tv = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        sessionID = UInt16.random(in: 0x1000...0xFFFE)
        baseSeq = UInt16.random(in: 0x1000...0xF000) & 0xFFF8
        channel = baseSeq
        if tcpPoke { poke(identifier: identifier) }
        guard handshake() else { throw Failure.handshake(port) }
        for _ in 0..<5 { parse(receive(for: 0.4)); sendAck() }
        udpSeq = channel &+ 8
        log("大疆数据连接：会话 \(String(format: "%04x", sessionID))，通道 \(String(format: "%04x", channel))")
    }

    private func poke(identifier: String) {
        let s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard s >= 0 else { return }
        defer { Darwin.close(s) }
        var tv = timeval(tv_sec: 1, tv_usec: 200_000)
        setsockopt(s, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = UInt16(7001).bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { log("大疆数据连接：TCP 7001 无法连接（继续）"); return }
        let frame = DJIBLECommand.pair(0x8092, identifier: identifier).encoded()
        _ = frame.withUnsafeBytes { send(s, $0.baseAddress, $0.count, 0) }
        Thread.sleep(forTimeInterval: 0.4)
    }

    // 官方 App 发的握手负载：前 2 字节是我们提议的起始序号，后面原样照抄。
    private static let handshakeTail: [UInt8] = [0x64, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x00,
        0x01, 0x90, 0x01, 0xC0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x14, 0x00, 0x64, 0x00, 0xC0, 0x05, 0x14, 0x00,
        0x00, 0x64, 0x00, 0x01, 0x01, 0x04, 0x01, 0x02]

    private func handshake() -> Bool {
        let payload = [UInt8(baseSeq & 0xFF), UInt8(baseSeq >> 8)] + Self.handshakeTail
        for _ in 0..<20 {
            sendRaw(type: 0x00, payload)
            for d in receive(for: 0.35) where d.count >= 8 && d[6] == 0x00 { return true }
        }
        return false
    }

    /// 注册成 App：设备信息、在线声明、云台初始化、订阅状态参数。
    public func register() {
        var info = [UInt8](repeating: 0, count: 62)
        info[1] = 0x41; info[2] = 0x50; info[3] = 0x50   // "APP"
        info[41] = 0x02; info[50] = 0x02; info[51] = 0x08
        sendDuml(0x00, 0x81, info, receiverType: 0x08, receiverID: 2, cmdType: 4); drain(0.2)
        presence(); drain(0.2)
        sendDuml(0x03, 0xDA, [0x05, 0xFF, 0xFF, 0xFF, 0xFF], receiverType: 0x03, receiverID: 0); drain(0.2)
        for (i, name) in ["cam_storage", "cam_status"].enumerated() {
            let n = Array(name.utf8)
            var p: [UInt8] = [0x02, 0x02, 0x00, 0x00] + le32(UInt32(i + 1)) + [0, 0, 0]
            p += le16(UInt16(n.count + 6)) + le16(UInt16(n.count)) + n + [0, 0, 0, 0]
            sendDuml(0x00, 0x99, p, receiverType: 0x08, receiverID: 1); drain(0.08)
        }
    }

    /// 在线声明，整个会话期间约 1 秒一次；也是回放模式的保活。
    public func presence() {
        sendDuml(0x00, 0x88, [0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0, 0, 0, 0, 0, 0x02], receiverType: 0x08, receiverID: 1)
    }

    /// 保活一拍：在线声明 + 收状态 + 确认。下载期间每秒调用一次。
    public func beat() {
        presence()
        parse(receive(for: 0.15))
        sendAck()
    }

    /// 进入回放模式：翻页和完整列表都要求在回放模式下。先发 0x02/0x0c；
    /// Pocket 3、Action 4 回 e0 不动，改发 0x01/0x01 控制帧。以状态推送里 0x02/0x80 的第 30 位为准。
    @discardableResult
    public func enterPlayback() -> Bool {
        if status.playback == true { return true }
        for _ in 0..<3 {
            sendDuml(0x02, 0x0C, [0x01, 0x01, 0x00, 0x01], receiverType: 0x01, receiverID: 0)
            let deadline = Date().addingTimeInterval(0.9)
            while Date() < deadline { drain(0.15); if status.playback == true { return settle() } }
        }
        let prelude: [UInt8] = [0x03, 0, 0, 0, 0, 0x04, 0, 0, 0, 0x07, 0x01]
        let enter: [UInt8] = [0x00, 0, 0, 0, 0, 0x04, 0, 0, 0, 0x04, 0x01]
        let deadline = Date().addingTimeInterval(2.5)
        var sent = 0
        while Date() < deadline {
            sendDuml(0x01, 0x01, sent < 6 ? prelude : enter, receiverType: 0x01, receiverID: 0, cmdType: 0)
            sent += 1
            drain(0.05)
            if status.playback == true { return settle() }
        }
        log("大疆数据连接：未能进入回放模式，列表可能不完整")
        return false
    }

    /// 回放模式确认后存储不是马上能查：等约 1.7 秒再列文件。
    private func settle() -> Bool {
        let until = Date().addingTimeInterval(1.7)
        while Date() < until { beat() }
        return true
    }

    // MARK: 文件列表

    /// 列出所有文件，新的在前。每页 45 条，SD 卡和内置存储各有一个游标，一直往前翻到最后一页。
    public func listAll(maxPages: Int = 400, progress: (Int) -> Void = { _ in }) throws -> [DJIManifest.Record] {
        var sdCursor: UInt32 = 0x0000_0001, internalCursor: UInt32 = 0x4000_0001
        var seen = Set<String>(), out: [DJIManifest.Record] = []
        var answeredOnce = false
        for page in 0..<maxPages {
            let frames = collectPage(sd: sdCursor, builtIn: internalCursor)
            let sdBytes = DJIManifest.reassemble(frames, counter: 1)
            let inBytes = DJIManifest.reassemble(frames, counter: 2)
            if DJIManifest.ended(frames, counter: 1).answered || DJIManifest.ended(frames, counter: 2).answered { answeredOnce = true }
            var sd = DJIManifest.decode(sdBytes, store: 0)
            var builtIn = DJIManifest.decode(inBytes, store: 1)
            // 相机没带回计数、或者两份一模一样时，按句柄第 30 位分：置位的是内置存储。
            if (sd.isEmpty && builtIn.isEmpty) || (!sd.isEmpty && sd.map(\.mediaPath) == builtIn.map(\.mediaPath)) {
                let all = DJIManifest.decode(DJIManifest.reassemble(frames))
                sd = all.filter { $0.handle & 0x4000_0000 == 0 }.map { var r = $0; r.store = 0; return r }
                builtIn = all.filter { $0.handle & 0x4000_0000 != 0 }.map { var r = $0; r.store = 1; return r }
            }
            var fresh = 0
            for r in builtIn + sd where seen.insert("\(r.store):\(r.mediaPath)").inserted { out.append(r); fresh += 1 }
            progress(out.count)
            if page == 0, !answeredOnce { throw Failure.listUnanswered }
            func older(_ slice: [DJIManifest.Record], _ bytes: [UInt8], below: UInt32) -> UInt32? {
                // 最后一页（带结束标记）或者不满一页：这个存储没有更早的了。
                guard !slice.isEmpty, !DJIManifest.hasEndMarker(bytes), slice.count >= 45 else { return nil }
                return slice.map(\.handle).filter { $0 != 0 && $0 < below }.min()
            }
            let nextSD = older(sd, sdBytes, below: sdCursor)
            let nextIn = older(builtIn, inBytes, below: internalCursor)
            guard fresh > 0, nextSD != nil || nextIn != nil else { break }
            if let nextSD { sdCursor = nextSD }
            if let nextIn { internalCursor = nextIn }
        }
        log("大疆数据连接：列出 \(out.count) 个文件")
        return out
    }

    /// 一页 = 查询(SD 游标) → 触发 → 查询(内置游标)，然后收到两个查询都结束（或安静下来）为止。
    private func collectPage(sd: UInt32, builtIn: UInt32) -> [DUMLFrame] {
        var frames: [DUMLFrame] = []
        sendDuml(0x00, 0x26, DJIManifest.listQuery(counter: 1, cursor: sd), receiverType: 0x01, receiverID: 0)
        var lastCount = -1, stable = 0
        for batch in 0..<15 {
            let got = receive(for: 0.8)
            parse(got)
            for d in got { frames += DUMLFrame.all(in: d) }
            sendAck(); presence()
            if batch == 1 { sendDuml(0x00, 0x26, DJIManifest.listTrigger, receiverType: 0x01, receiverID: 0) }
            if batch == 2 { sendDuml(0x00, 0x26, DJIManifest.listQuery(counter: 2, cursor: builtIn), receiverType: 0x01, receiverID: 0) }
            if batch == 4, !frames.contains(where: { $0.matches(0x00, 0x27) }) { break }
            // 一个查询算收完：收到了结束块，或者没回 / 只回了开始块没有数据（空的或不存在的存储就这样，永远不发结束块）。
            let a = DJIManifest.ended(frames, counter: 1), b = DJIManifest.ended(frames, counter: 2)
            func closed(_ e: (answered: Bool, ended: Bool), _ ctr: UInt8) -> Bool { e.ended || DJIManifest.reassemble(frames, counter: ctr).isEmpty }
            if batch >= 3, closed(a, 1), closed(b, 2), a.answered || b.answered { break }
            let count = DJIManifest.decode(DJIManifest.reassemble(frames)).count
            if batch >= 4, count > 0, count == lastCount { stable += 1; if stable >= 2 { break } } else { stable = 0 }
            lastCount = count
        }
        return frames
    }

    // MARK: 关闭

    public func close() {
        guard fd >= 0 else { return }
        sendDuml(0x02, 0x0C, [0x01, 0x01, 0x00, 0x00], receiverType: 0x01, receiverID: 0)
        Thread.sleep(forTimeInterval: 0.1)
        Darwin.close(fd)
        fd = -1
    }

    // MARK: 收发

    private func drain(_ seconds: TimeInterval) { parse(receive(for: seconds)) }

    private func receive(for seconds: TimeInterval) -> [[UInt8]] {
        var out: [[UInt8]] = []
        let deadline = Date().addingTimeInterval(seconds)
        var buf = [UInt8](repeating: 0, count: 65536)
        while Date() < deadline, fd >= 0 {
            let n = buf.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { continue } else { break } }
            let d = Array(buf[0..<n])
            out.append(d)
            if d.count >= 10 {
                let ch = UInt16(d[8]) | UInt16(d[9]) << 8
                if ch != 0 { channel = ch }
            }
            // 相机的 34 字节状态包里带着它的窗口游标，确认包要原样带回。
            if d.count == 34, d[6] == 0x01 {
                peerCursor = UInt16(d[10]) | UInt16(d[11]) << 8
                peerDownloadCursor = UInt16(d[18]) | UInt16(d[19]) << 8
            }
        }
        return out
    }

    private func parse(_ datagrams: [[UInt8]]) {
        for d in datagrams {
            for f in DUMLFrame.all(in: d) {
                let p = f.payload
                if f.matches(0x02, 0x80), p.count >= 13 {
                    let flags = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
                    status.playback = flags & 0x4000_0000 != 0
                    status.recording = p[0] & 0x80 != 0
                } else if f.matches(0x02, 0xDC), p.count >= 14 {
                    let total = UInt32(p[6]) | UInt32(p[7]) << 8 | UInt32(p[8]) << 16 | UInt32(p[9]) << 24
                    let free = UInt32(p[10]) | UInt32(p[11]) << 8 | UInt32(p[12]) << 16 | UInt32(p[13]) << 24
                    if total > 0 { status.cardTotalMiB = total; status.cardFreeMiB = free }
                } else if f.matches(0x0D, 0x02), p.count >= 21 {
                    status.batteryPercent = Int(p[20])
                }
            }
        }
    }

    private func sendTo(_ packet: [UInt8]) -> Bool {
        guard fd >= 0 else { return false }
        var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = port.bigEndian
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let n = packet.withUnsafeBytes { buf in
            withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        return n == packet.count
    }

    static func udpHeader(type: UInt8, payloadLength: Int, session: UInt16, seq: UInt16) -> [UInt8] {
        let w0 = UInt16(0x8000) | UInt16((8 + payloadLength) & 0x3FFF)
        var b: [UInt8] = [UInt8(w0 & 0xFF), UInt8(w0 >> 8), UInt8(session & 0xFF), UInt8(session >> 8),
                          UInt8(seq & 0xFF), UInt8(seq >> 8), type]
        b.append(b.reduce(0, ^))
        return b
    }

    private func sendRaw(type: UInt8, _ payload: [UInt8]) {
        if sendTo(Self.udpHeader(type: type, payloadLength: payload.count, session: sessionID, seq: udpSeq) + payload) { udpSeq &+= 8 }
    }

    private func sendAck() {
        func group(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8), UInt8(v & 0xFF), UInt8(v >> 8), 0, 0, 0, 0] }
        let payload = group(peerCursor) + group(peerDownloadCursor) + group(baseSeq) + [0, 0]
        _ = sendTo(Self.udpHeader(type: 0x04, payloadLength: payload.count, session: sessionID, seq: 0) + payload)
    }

    private func sendDuml(_ set: UInt8, _ id: UInt8, _ payload: [UInt8], receiverType: UInt8, receiverID: UInt8, cmdType: UInt8 = 2) {
        counter &+= 1
        let ack = udpSeq &- 8
        let routing: [UInt8] = [UInt8(ack & 0xFF), UInt8(ack >> 8), UInt8(udpSeq & 0xFF), UInt8(udpSeq >> 8), 0, 0, 0, 0, counter, 0x01, 0x00, 0x00]
        let frame = DUMLFrame(receiver: (receiverID << 5) | receiverType, messageID: dumlSeq, flags: cmdType << 5,
                              commandSet: set, commandID: id, payload: payload).encoded()
        dumlSeq &+= 1
        sendRaw(type: 0x05, routing + frame)
    }

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
}
