import Foundation

/// 富士 X / GFX 的 Wi-Fi（相机播放菜单里的「无线通信」，相机做热点，地址 192.168.0.1）。
/// 协议依据 libfuji（MIT，Fudge 的协议部分）、libgphoto2 的 `fujiptpip.c` 和真机日志，MiniDiT 独立实现，没有复制代码。
///
/// 和索尼 / 佳能的 PTP/IP 不同：
/// - 命令端口 55740；握手包固定 82 字节，版本字段是魔数 0x8F53E4F2，电脑名占 54 字节（UTF-16LE，补零）。
/// - 握手之后不再用 PTP/IP 的包，而是 USB 式容器直接走 TCP：`u32 长度, u16 类型, u16 代码, u32 事务号, 参数…`，
///   类型 1 命令、2 数据、3 响应、4 事件；数据阶段就是一个类型 2 容器。
/// - 相机状态在属性 0xD212（事件列表）里轮询；0xDF00 = 0 表示等用户在相机上按 OK。
/// - 不用 GetObjectHandles：句柄就是 1…N，N 来自 0xD222。
/// - 0xD227 = 1 之前 ObjectInfo 里的大小是假的（约 100 KB）；下载用 GetPartialObject，每块 1 MB。
/// - 断开：CloseSession 后发 `08 00 00 00 FF FF FF FF`。
public enum FujiWiFi {
    public static let commandPort: UInt16 = 55740
    public static let eventPort: UInt16 = 55741
    public static let liveViewPort: UInt16 = 55742
    public static let defaultHost = "192.168.0.1"
    static let initVersion: UInt32 = 0x8F53_E4F2
    static let nameField = 54
    /// 断开时双方都发的 8 字节包。
    static let goodbye = Data([0x08, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])
    public static let downloadChunk: UInt32 = 1024 * 1024
    /// 日志里看到的存储 ID。
    public static let storageID: UInt32 = 0x1000_0001

    public enum Prop {
        public static let events: UInt16 = 0xD212
        public static let objectCount: UInt16 = 0xD222
        public static let correctFileSize: UInt16 = 0xD227
        public static let storage: UInt16 = 0xD244
        public static let state: UInt16 = 0xDF00
        public static let mode: UInt16 = 0xDF01
        public static let imageViewVersion: UInt16 = 0xDF21
        public static let imageGetVersion: UInt16 = 0xDF22
        public static let autoSaveVersion: UInt16 = 0xDF23
        public static let remoteVersion: UInt16 = 0xDF24
        public static let remoteGetObjectVersion: UInt16 = 0xDF25
    }

    public enum Op {
        public static let getPropertyDescriptors: UInt16 = 0x902B
        public static let initiateOpenCapture: UInt16 = 0x101C
        public static let terminateOpenCapture: UInt16 = 0x1018
    }

    /// 0xDF00 的取值。
    public enum State {
        public static let waiting: UInt32 = 0
        public static let multipleTransfer: UInt32 = 1
        public static let fullAccess: UInt32 = 2
        public static let autoSave: UInt32 = 3
        public static let remote: UInt32 = 6
    }

    public enum Failure: LocalizedError, Equatable {
        case refused, notConfirmed, protocolError(String)
        public var errorDescription: String? {
            switch self {
            case .refused: String(localized: "富士相机拒绝了连接。请确认没有别的设备（如手机上的 FUJIFILM XApp）连着相机，然后在相机上重新打开「无线通信」。", bundle: .miniDiT)
            case .notConfirmed: String(localized: "相机上没有确认连接。请在相机上按 OK 允许这台 Mac 连接后重试。", bundle: .miniDiT)
            case .protocolError(let s): String(localized: "与富士相机通信出错：\(s)", bundle: .miniDiT)
            }
        }
    }

    /// 握手包：u32 长度 0x52、u32 类型 1、u32 版本魔数、16 字节 GUID、54 字节 UTF-16LE 名字（补零）。
    static func initRequest(guid: [UInt8], name: String) -> Data {
        var w = PTPWriter()
        w.u32(82); w.u32(1); w.u32(initVersion); w.raw(Array(guid.prefix(16)) + [UInt8](repeating: 0, count: max(0, 16 - guid.count)))
        var nameBytes: [UInt8] = []
        for unit in name.utf16 {
            guard nameBytes.count + 2 <= nameField - 2 else { break }   // 留出结尾的 0
            nameBytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)]
        }
        w.raw(nameBytes + [UInt8](repeating: 0, count: nameField - nameBytes.count))
        return w.data
    }

    /// 0xD212 的数据：u16 个数，然后每项 u16 属性码 + u32 值。
    static func parseEvents(_ data: Data) -> [UInt16: UInt32] {
        var r = PTPReader(data)
        guard let n = try? r.u16() else { return [:] }
        var out: [UInt16: UInt32] = [:]
        for _ in 0..<n {
            guard let code = try? r.u16(), let value = try? r.u32() else { break }
            out[code] = value
        }
        return out
    }

    /// 小端整数（属性值可能是 u16 或 u32）。
    static func integer(_ data: Data) -> UInt32? {
        let b = [UInt8](data)
        switch b.count {
        case 1: return UInt32(b[0])
        case 2, 3: return UInt32(b[0]) | UInt32(b[1]) << 8
        case 4...: return UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        default: return nil
        }
    }

    static func encode(_ value: UInt32, width: Int) -> Data {
        var w = PTPWriter()
        if width == 4 { w.u32(value) } else { w.u16(UInt16(truncatingIfNeeded: value)) }
        return w.data
    }
}

/// 富士的命令通道：握手是 PTP/IP，之后是 USB 式容器。所有事务串行执行。
public actor FujiPTPClient {
    public struct Result: Sendable {
        public let code: UInt16
        public let params: [UInt32]
        public let data: Data
    }

    let host: String
    let port: UInt16
    let identity: PTPIPHostIdentity
    private var command: PTPIPSocket?
    private var auxiliary: [PTPIPSocket] = []
    private var drains: [Task<Void, Never>] = []
    private var nextTransactionID: UInt32 = 1
    /// 最近一次事务的事务号（TerminateOpenCapture 要带上 InitiateOpenCapture 的事务号）。
    public var lastTransactionID: UInt32 { nextTransactionID &- 1 }
    private let gate = AsyncGate()
    public private(set) var cameraName = ""
    public private(set) var cameraGUID: [UInt8] = []
    var responseTimeout: TimeInterval = 15
    public nonisolated let closed: AsyncStream<Void>
    private let closedContinuation: AsyncStream<Void>.Continuation

    public init(host: String, port: UInt16 = FujiWiFi.commandPort, identity: PTPIPHostIdentity) {
        self.host = host
        self.port = port
        self.identity = identity
        (closed, closedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    public func connect(timeout: TimeInterval = 8) async throws {
        let socket = PTPIPSocket(host: host, port: port)
        do {
            try await socket.open(timeout: timeout)
            try await socket.sendRaw(FujiWiFi.initRequest(guid: identity.guid, name: identity.friendlyName))
            var r = PTPReader(try await socket.receiveBytes(8, timeout: timeout))
            let length = Int(try r.u32()), type = try r.u32()
            guard length >= 8, length <= 4096 else { throw PTPIPTransportError.packetTooLarge(UInt32(length)) }
            let body = try await socket.receiveBytes(length - 8, timeout: timeout)
            switch type {
            case 2:
                var b = PTPReader(body)
                _ = try b.u32()
                cameraGUID = try b.raw(16)
                cameraName = Self.utf16(Array(body.dropFirst(20)))
            case 5:
                throw FujiWiFi.Failure.refused
            default:
                throw PTPIPTransportError.unexpectedPacket("init type \(type)")
            }
            command = socket
        } catch {
            socket.close()
            throw error
        }
    }

    static func utf16(_ bytes: [UInt8]) -> String {
        var units: [UInt16] = []
        var i = 0
        while i + 1 < bytes.count {
            let u = UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8
            if u == 0 { break }
            units.append(u); i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// 只连上辅助端口（事件 / 取景），读到的数据直接丢掉，免得相机那边写满缓冲区卡住。
    func openAuxiliary(port: UInt16) async {
        let s = PTPIPSocket(host: host, port: port)
        do { try await s.open(timeout: 5) } catch { return }
        auxiliary.append(s)
        drains.append(Task.detached {
            while !Task.isCancelled {
                guard (try? await s.receiveSome(max: 1 << 16, timeout: nil)) != nil else { break }
            }
        })
    }

    public func transaction(_ code: UInt16, _ params: [UInt32] = [], dataOut: Data? = nil, requireOK: Bool = true,
                            timeout: TimeInterval? = nil,
                            sink: (@Sendable (Data) throws -> Void)? = nil) async throws -> Result {
        await gate.acquire()
        defer { Task { await gate.release() } }
        guard let cmd = command else { throw PTPIPTransportError.closed }
        let tid = nextTransactionID
        nextTransactionID &+= 1
        let wait = timeout ?? responseTimeout
        do {
            var w = PTPWriter()
            w.u32(UInt32(12 + 4 * params.count)); w.u16(1); w.u16(code); w.u32(tid)
            params.forEach { w.u32($0) }
            if let dataOut {
                w.u32(UInt32(12 + dataOut.count)); w.u16(2); w.u16(code); w.u32(tid); w.raw(dataOut)
            }
            try await cmd.sendRaw(w.data)
            var incoming = Data()
            while true {
                var h = PTPReader(try await cmd.receiveBytes(8, timeout: wait))
                let length = Int(try h.u32())
                let type = try h.u16(), rcode = try h.u16()
                if length == 8 && type == 0xFFFF && rcode == 0xFFFF {   // 相机说再见
                    throw PTPIPTransportError.closed
                }
                guard length >= 12 else { throw PTPIPTransportError.packetTooLarge(UInt32(length)) }
                var t = PTPReader(try await cmd.receiveBytes(4, timeout: wait))
                let ptid = try t.u32()
                var remaining = length - 12
                switch type {
                case 2:
                    while remaining > 0 {
                        let n = min(remaining, 1 << 20)
                        let chunk = Data(try await cmd.receiveBytes(n, timeout: wait))
                        remaining -= n
                        guard ptid == tid else { continue }
                        if let sink { try sink(chunk) } else { incoming.append(chunk) }
                    }
                case 3:
                    guard remaining <= 64 else { throw PTPIPTransportError.packetTooLarge(UInt32(length)) }
                    var p = PTPReader(try await cmd.receiveBytes(remaining, timeout: wait))
                    guard ptid == tid else { continue }
                    var rparams: [UInt32] = []
                    for _ in 0..<(remaining / 4) { rparams.append(try p.u32()) }
                    if requireOK && rcode != PTPResponse.ok { throw PTPError(operation: code, code: rcode) }
                    return Result(code: rcode, params: rparams, data: incoming)
                default:
                    // 命令通道上的事件或别的容器：读掉丢弃。
                    if remaining > 0 { _ = try await cmd.receiveBytes(remaining, timeout: wait) }
                }
            }
        } catch let e as PTPError {
            throw e
        } catch {
            drop()
            throw error
        }
    }

    public func getProperty(_ code: UInt16) async throws -> Data {
        try await transaction(PTPOperation.getDevicePropValue, [UInt32(code)]).data
    }

    public func setProperty(_ code: UInt16, _ data: Data, timeout: TimeInterval? = nil) async throws {
        _ = try await transaction(PTPOperation.setDevicePropValue, [UInt32(code)], dataOut: data, timeout: timeout)
    }

    /// 读一次事件列表（0xD212），相机靠它推进状态。
    public func poll() async throws -> [UInt16: UInt32] {
        FujiWiFi.parseEvents(try await getProperty(FujiWiFi.Prop.events))
    }

    public func openSession() async throws {
        let r = try await transaction(PTPOperation.openSession, [1], requireOK: false)
        guard r.code == PTPResponse.ok || r.code == PTPResponse.sessionAlreadyOpen else {
            throw PTPError(operation: PTPOperation.openSession, code: r.code)
        }
    }

    private func drop() {
        command?.close(); command = nil
        auxiliary.forEach { $0.close() }; auxiliary = []
        drains.forEach { $0.cancel() }; drains = []
        closedContinuation.yield()
        closedContinuation.finish()
    }

    /// CloseSession，再发告别包，然后关掉所有连接。
    public func shutdown() async {
        if command != nil, await !gate.isBusy {
            _ = try? await transaction(PTPOperation.closeSession, requireOK: false, timeout: 2)
            try? await command?.sendRaw(FujiWiFi.goodbye)
        }
        drop()
    }
}
