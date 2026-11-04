import Foundation
import Network

/// 自动发现找到的一台候选相机。
public struct DiscoveredCamera: Sendable, Hashable, Identifiable {
    public enum Source: Sendable, Hashable {
        /// 来自 Wi-Fi 直连推测：默认网关、子网 .1 或索尼旧机型的 192.168.122.1。
        case gateway
        /// 来自局域网扫描。
        case scan
    }

    public var host: String
    /// 相机型号名（如 "ILCE-7M4"），只有开启确认握手时才有。
    public var name: String?
    public var source: Source
    public var id: String { host }

    public init(host: String, name: String? = nil, source: Source) {
        self.host = host
        self.name = name
        self.source = source
    }
}

/// 在手机所在的 Wi-Fi 上找相机：
/// 1. Wi-Fi 直连时相机就是路由器，直接给出网关地址（`gatewayCandidates`）；
/// 2. 同一路由器时，对本机所在子网的每个地址尝试 TCP 连接 15740 端口（`scan` / `discover`）。
///
/// 不使用 SSDP/组播（需要苹果的受限权限 com.apple.developer.networking.multicast）。
/// iOS 上需要在 Info.plist 中声明 `NSLocalNetworkUsageDescription`，首次扫描会弹出「本地网络」授权，
/// 用户拒绝时所有连接都会失败，扫描结果为空。
public enum CameraDiscovery {
    /// iPhone / iPad 的 Wi-Fi 接口名。
    public static let wifiInterface = "en0"
    /// 索尼旧机型 Wi-Fi 直连时相机的地址（A7 IV 未确认）。
    public static let legacyDirectHost = "192.168.122.1"
    /// 子网超过这个主机数时只扫本机所在的 /24。
    public static let maxScanHosts = 1024

    // MARK: 本机网络信息

    /// Wi-Fi 接口的 IPv4 地址和掩码。没连 Wi-Fi 时为 nil。
    public static func wifiSubnet(interface: String = wifiInterface) -> IPv4Subnet? {
        NetworkInterfaces.ipv4Subnet(interface: interface)
    }

    /// 从系统路由表读出的 Wi-Fi 默认网关（即 iPhone Wi-Fi 详情里的「路由器」）。读不到时为 nil。
    public static func defaultGateway(interface: String = wifiInterface) -> String? {
        NetworkInterfaces.defaultGateway(interface: interface).map(IPv4Subnet.format)
    }

    // MARK: 策略一：Wi-Fi 直连

    /// Wi-Fi 直连时相机可能的地址，按可能性排序：路由表里的网关 → 子网 .1 → 192.168.122.1。
    /// 只是猜测，不做网络访问；需要确认可用 `probe` 或 `discover`。
    public static func gatewayCandidates(interface: String = wifiInterface) -> [String] {
        gatewayCandidates(subnet: wifiSubnet(interface: interface),
                          gateway: NetworkInterfaces.defaultGateway(interface: interface))
    }

    /// 纯计算版本，便于测试。
    static func gatewayCandidates(subnet: IPv4Subnet?, gateway: UInt32?) -> [String] {
        var out: [UInt32] = []
        if let gateway, gateway != 0 { out.append(gateway) }
        if let subnet, subnet.hostCount > 2, subnet.firstHost != subnet.address { out.append(subnet.firstHost) }
        if let legacy = IPv4Subnet.parse(legacyDirectHost) { out.append(legacy) }
        var seen = Set<UInt32>()
        return out.filter { seen.insert($0).inserted }.map(IPv4Subnet.format)
    }

    // MARK: 策略二：局域网扫描

    /// 要扫描的地址：Wi-Fi 子网内除本机外的所有主机；子网大于 `maxHosts` 时只取本机所在的 /24。
    public static func scanHosts(interface: String = wifiInterface, maxHosts: Int = maxScanHosts) -> [String] {
        wifiSubnet(interface: interface)?.scanHosts(maxHosts: maxHosts).map(IPv4Subnet.format) ?? []
    }

    /// 对 `hosts`（默认是 Wi-Fi 子网）并发尝试 TCP 连接 `port`，接受连接的就是候选相机。
    ///
    /// - Parameters:
    ///   - timeout: 每个地址的连接超时。局域网内 300 ms 足够。
    ///   - concurrency: 同时进行的连接数。
    ///   - confirmWith: 不为 nil 时，对接受连接的地址再做一次 PTP/IP InitCommandRequest，读出相机型号后断开。
    ///     **默认关闭**：相机同一时间只接受一个遥控端，未配对的手机还可能触发相机上的配对提示。
    ///     请传入 APP 平时连接用的同一个身份（GUID），避免相机把它当成新设备。
    ///   - progress: 每完成一个地址回调一次 `(已完成, 总数)`，在任意线程调用。
    /// - Returns: 按 IP 排序的候选相机。任务被取消时尽快返回已找到的结果。
    public static func scan(hosts: [String]? = nil,
                            port: UInt16 = PTPIPClient.defaultPort,
                            timeout: TimeInterval = 0.3,
                            concurrency: Int = 32,
                            confirmWith identity: PTPIPHostIdentity? = nil,
                            progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil) async -> [DiscoveredCamera] {
        await run(hosts: hosts ?? scanHosts(), gatewayHosts: [], port: port, timeout: timeout,
                  concurrency: concurrency, identity: identity, progress: progress)
    }

    /// 两种策略一起用：网关候选和子网扫描放在同一个连接池里。网关候选排在结果最前面。
    public static func discover(interface: String = wifiInterface,
                                port: UInt16 = PTPIPClient.defaultPort,
                                timeout: TimeInterval = 0.3,
                                concurrency: Int = 32,
                                confirmWith identity: PTPIPHostIdentity? = nil,
                                progress: (@Sendable (_ completed: Int, _ total: Int) -> Void)? = nil) async -> [DiscoveredCamera] {
        let gateways = gatewayCandidates(interface: interface)
        let hosts = gateways + scanHosts(interface: interface).filter { !gateways.contains($0) }
        return await run(hosts: hosts, gatewayHosts: Set(gateways), port: port, timeout: timeout,
                         concurrency: concurrency, identity: identity, progress: progress)
    }

    /// 单个地址能否建立 TCP 连接（连上立即断开，不发送任何数据）。
    public static func probe(host: String, port: UInt16 = PTPIPClient.defaultPort, timeout: TimeInterval = 0.3) async -> Bool {
        await TCPProbe.run(host: host, port: port, timeout: timeout)
    }

    // MARK: 实现

    private static func run(hosts: [String], gatewayHosts: Set<String>, port: UInt16, timeout: TimeInterval,
                            concurrency: Int, identity: PTPIPHostIdentity?,
                            progress: (@Sendable (Int, Int) -> Void)?) async -> [DiscoveredCamera] {
        var seen = Set<String>()
        let hosts = hosts.filter { seen.insert($0).inserted }
        let total = hosts.count
        guard total > 0 else { return [] }

        @Sendable func check(_ host: String) async -> DiscoveredCamera? {
            guard await TCPProbe.run(host: host, port: port, timeout: timeout) else { return nil }
            let source: DiscoveredCamera.Source = gatewayHosts.contains(host) ? .gateway : .scan
            var name: String? = nil
            if let identity, !Task.isCancelled {
                name = await confirmName(host: host, port: port, identity: identity)
            }
            return DiscoveredCamera(host: host, name: name, source: source)
        }

        var found: [DiscoveredCamera] = []
        await withTaskGroup(of: DiscoveredCamera?.self) { group in
            var pending = hosts.makeIterator()
            for _ in 0..<max(1, concurrency) {
                guard let h = pending.next() else { break }
                group.addTask { await check(h) }
            }
            var completed = 0
            for await result in group {
                completed += 1
                progress?(completed, total)
                if let result { found.append(result) }
                if Task.isCancelled { group.cancelAll(); continue }
                if let h = pending.next() { group.addTask { await check(h) } }
            }
        }
        return found.sorted { a, b in
            if a.source != b.source { return a.source == .gateway }
            return (IPv4Subnet.parse(a.host) ?? .max, a.host) < (IPv4Subnet.parse(b.host) ?? .max, b.host)
        }
    }

    /// 发一次 InitCommandRequest，读 InitCommandAck 里的相机名，然后直接断开（不建立事件通道）。
    /// 相机回 InitFail（比如未配对）或超时时返回 nil，地址仍算候选。
    static func confirmName(host: String, port: UInt16, identity: PTPIPHostIdentity, timeout: TimeInterval = 2) async -> String? {
        let socket = PTPIPSocket(host: host, port: port)
        defer { socket.close() }
        do {
            try await socket.open(timeout: timeout)
            try await socket.send(.initCommandRequest(guid: identity.guid, name: identity.friendlyName,
                                                      version: PTPIPPacket.protocolVersion))
            if case let .initCommandAck(_, _, name, _) = try await socket.receive(timeout: timeout) {
                return name.isEmpty ? nil : name
            }
        } catch {}
        return nil
    }
}

/// 一次带超时的 TCP 连接尝试。
private final class TCPProbe: @unchecked Sendable {
    private static let queue = DispatchQueue(label: "camera.discovery.probe")

    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    private init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let params = NWParameters(tls: nil, tcp: tcp)
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: params)
    }

    static func run(host: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard !Task.isCancelled, port != 0 else { return false }
        let probe = TCPProbe(host: host, port: port)
        return await withTaskCancellationHandler {
            await probe.start(timeout: timeout)
        } onCancel: {
            probe.finish(false)
        }
    }

    private func start(timeout: TimeInterval) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // 取消可能发生在这里之前：那时 finish 已经记下结果，直接返回。
            let early: Bool? = lock.withLock {
                if let result { return result }
                continuation = cont
                return nil
            }
            if let early { cont.resume(returning: early); return }

            connection.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: self?.finish(true)
                // 连接被拒绝或网络不可达时 NWConnection 会进入 waiting 并不断重试，这里视为失败。
                case .failed, .waiting, .cancelled: self?.finish(false)
                default: break
                }
            }
            connection.start(queue: Self.queue)
            Self.queue.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(false) }
        }
    }

    private func finish(_ ok: Bool) {
        let cont: CheckedContinuation<Bool, Never>?? = lock.withLock {
            guard result == nil else { return .none }
            result = ok
            defer { continuation = nil }
            return .some(continuation)
        }
        guard case let .some(c) = cont else { return }
        connection.cancel()
        c?.resume(returning: ok)
    }
}
