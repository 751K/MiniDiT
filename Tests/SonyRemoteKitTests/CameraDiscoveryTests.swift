import Foundation
import Network
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct CameraDiscoveryTests {
    // MARK: 子网计算

    @Test func parseAndFormat() {
        #expect(IPv4Subnet.parse("192.168.122.1") == 0xC0A8_7A01)
        #expect(IPv4Subnet.format(0xC0A8_7A01) == "192.168.122.1")
        for bad in ["", "1.2.3", "1.2.3.4.5", "256.1.1.1", "1..2.3", "a.b.c.d", "1.2.3.-4", "1.2.3.0004"] {
            #expect(IPv4Subnet.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func subnetMath() throws {
        let s = try #require(IPv4Subnet("192.168.1.23", mask: "255.255.255.0"))
        #expect(s.prefixLength == 24)
        #expect(IPv4Subnet.format(s.network) == "192.168.1.0")
        #expect(IPv4Subnet.format(s.broadcast) == "192.168.1.255")
        #expect(s.hostCount == 254)
        #expect(IPv4Subnet.format(s.firstHost) == "192.168.1.1")
        #expect(s.description == "192.168.1.23/24")

        let s22 = try #require(IPv4Subnet("10.0.5.9", prefixLength: 22))
        #expect(IPv4Subnet.format(s22.network) == "10.0.4.0")
        #expect(IPv4Subnet.format(s22.broadcast) == "10.0.7.255")
        #expect(s22.hostCount == 1022)

        #expect(IPv4Subnet.mask(prefixLength: 0) == 0)
        #expect(IPv4Subnet.mask(prefixLength: 32) == .max)
        #expect(IPv4Subnet("1.2.3.4", prefixLength: 33) == nil)
    }

    @Test func scanHostsExcludesSelfNetworkAndBroadcast() throws {
        let s = try #require(IPv4Subnet("192.168.122.10", prefixLength: 24))
        let hosts = s.scanHosts().map(IPv4Subnet.format)
        #expect(hosts.count == 253)
        #expect(hosts.first == "192.168.122.1")
        #expect(hosts.last == "192.168.122.254")
        #expect(!hosts.contains("192.168.122.10"))
        #expect(!hosts.contains("192.168.122.0"))
        #expect(!hosts.contains("192.168.122.255"))
    }

    @Test func scanHostsLimits() throws {
        // /22 = 1022 台主机，未超过 1024，整段扫描。
        let s22 = try #require(IPv4Subnet("10.0.5.9", prefixLength: 22))
        #expect(s22.scanHosts().count == 1021)
        // /16 太大，退回到本机所在的 /24。
        let s16 = try #require(IPv4Subnet("172.16.40.7", prefixLength: 16))
        let hosts = s16.scanHosts().map(IPv4Subnet.format)
        #expect(hosts.count == 253)
        #expect(hosts.first == "172.16.40.1" && hosts.last == "172.16.40.254")
        // 自定义上限。
        #expect(s22.scanHosts(maxHosts: 300).count == 253)
        // /30、/31、/32 没有可扫的其他主机（/30 只有对端一台）。
        #expect(try #require(IPv4Subnet("10.0.0.1", prefixLength: 30)).scanHosts() == [IPv4Subnet.parse("10.0.0.2")!])
        #expect(try #require(IPv4Subnet("10.0.0.1", prefixLength: 31)).scanHosts().isEmpty)
        #expect(try #require(IPv4Subnet("10.0.0.1", prefixLength: 32)).scanHosts().isEmpty)
    }

    // MARK: 网关候选

    @Test func gatewayCandidatesOrderAndDedup() throws {
        let direct = try #require(IPv4Subnet("192.168.122.20", prefixLength: 24))
        // 路由表网关就是 .1，再加旧机型地址（同一个），去重后只剩一个。
        #expect(CameraDiscovery.gatewayCandidates(subnet: direct, gateway: IPv4Subnet.parse("192.168.122.1"))
                == ["192.168.122.1"])

        let other = try #require(IPv4Subnet("10.1.2.50", prefixLength: 24))
        #expect(CameraDiscovery.gatewayCandidates(subnet: other, gateway: IPv4Subnet.parse("10.1.2.254"))
                == ["10.1.2.254", "10.1.2.1", "192.168.122.1"])
        // 读不到路由表时退回 .1 + 192.168.122.1。
        #expect(CameraDiscovery.gatewayCandidates(subnet: other, gateway: nil) == ["10.1.2.1", "192.168.122.1"])
        // 本机自己就是 .1 时不把自己当候选。
        let selfIsFirst = try #require(IPv4Subnet("10.1.2.1", prefixLength: 24))
        #expect(CameraDiscovery.gatewayCandidates(subnet: selfIsFirst, gateway: nil) == ["192.168.122.1"])
        // 没有 Wi-Fi。
        #expect(CameraDiscovery.gatewayCandidates(subnet: nil, gateway: nil) == ["192.168.122.1"])
    }

    @Test func parseRouteDump() {
        // 两条消息：en(4) 上的默认路由 → 192.168.122.1；以及一条非默认路由（目的 10.0.0.0），应被忽略。
        func message(index: UInt16, dst: [UInt8], gateway: [UInt8]) -> [UInt8] {
            func sockaddrIn(_ a: [UInt8]) -> [UInt8] { [16, UInt8(AF_INET), 0, 0] + a + [UInt8](repeating: 0, count: 8) }
            let body = sockaddrIn(dst) + sockaddrIn(gateway) + [0, 0, 0, 0]  // 第三个是长度为 0 的掩码
            var h = [UInt8](repeating: 0, count: NetworkInterfaces.rtMsghdrSize)
            let len = UInt16(h.count + body.count)
            h[0] = UInt8(len & 0xFF); h[1] = UInt8(len >> 8)
            h[2] = NetworkInterfaces.rtmVersion
            h[4] = UInt8(index & 0xFF); h[5] = UInt8(index >> 8)
            h[8] = 0x3          // RTF_UP | RTF_GATEWAY
            h[12] = 0x7         // RTA_DST | RTA_GATEWAY | RTA_NETMASK
            return h + body
        }
        let buf = message(index: 9, dst: [10, 0, 0, 0], gateway: [10, 0, 0, 1])
            + message(index: 4, dst: [0, 0, 0, 0], gateway: [192, 168, 122, 1])
        #expect(NetworkInterfaces.parseDefaultGateways(buf)
                == [.init(interfaceIndex: 4, gateway: 0xC0A8_7A01)])
        // 截断的数据不能崩溃。
        #expect(NetworkInterfaces.parseDefaultGateways(Array(buf.prefix(100))).count <= 1)
        #expect(NetworkInterfaces.parseDefaultGateways([1, 2, 3]).isEmpty)
    }

    @Test func liveInterfaceLookupDoesNotCrash() {
        // 本机环境不确定，只检查结果自洽。
        if let s = CameraDiscovery.wifiSubnet() { #expect(s.prefixLength > 0) }
        if let gw = CameraDiscovery.defaultGateway() { #expect(IPv4Subnet.parse(gw) != nil) }
        #expect(CameraDiscovery.gatewayCandidates().last == CameraDiscovery.legacyDirectHost)
        #expect(CameraDiscovery.wifiSubnet(interface: "nonexistent0") == nil)
        #expect(CameraDiscovery.defaultGateway(interface: "nonexistent0") == nil)
    }

    // MARK: 扫描

    @Test func scanFindsLocalListener() async throws {
        let listener = try LocalListener()
        let port = try await listener.start()
        defer { listener.stop() }

        let counter = Counter()
        let started = Date()
        let found = await CameraDiscovery.scan(hosts: ["127.0.0.2", "127.0.0.1", "192.0.2.1", "127.0.0.1"],
                                               port: port, timeout: 0.3, concurrency: 2) { done, total in
            counter.record(done, total)
        }
        #expect(found == [DiscoveredCamera(host: "127.0.0.1", source: .scan)])
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(counter.last == (3, 3))
    }

    @Test func probeRefusedPortFails() async throws {
        let listener = try LocalListener()
        let port = try await listener.start()
        #expect(await CameraDiscovery.probe(host: "127.0.0.1", port: port))
        listener.stop()
        try await Task.sleep(for: .milliseconds(100))
        #expect(await !CameraDiscovery.probe(host: "127.0.0.1", port: port))
    }

    @Test func scanConfirmReadsCameraName() async throws {
        let cam = try FakeCamera { _, _, _ in .init() }
        let port = try await cam.start()
        defer { cam.stop() }
        let identity = PTPIPHostIdentity(guid: [UInt8](repeating: 3, count: 16), friendlyName: "Test")
        let found = await CameraDiscovery.scan(hosts: ["127.0.0.1"], port: port, confirmWith: identity)
        #expect(found == [DiscoveredCamera(host: "127.0.0.1", name: "ILCE-7M4", source: .scan)])
        #expect(cam.receivedGUID == identity.guid)
    }

    @Test func scanIsCancellable() async throws {
        // 全是不可达地址：取消后应很快返回，而不是跑完 256 个 × 2 秒。
        let hosts = (1...254).map { "192.0.2.\($0)" }
        let task = Task { await CameraDiscovery.scan(hosts: hosts, port: 15740, timeout: 2, concurrency: 4) }
        try await Task.sleep(for: .milliseconds(200))
        let started = Date()
        task.cancel()
        let found = await task.value
        #expect(found.isEmpty)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func emptyHostListReturnsImmediately() async {
        #expect(await CameraDiscovery.scan(hosts: []).isEmpty)
    }
}

/// 只接受 TCP 连接、什么都不做的监听器，绑定 127.0.0.1 的随机端口。
private final class LocalListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "test.listener")

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: if once.claim() { cont.resume(returning: listener.port!.rawValue) }
                case .failed(let e): if once.claim() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [queue] conn in
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 1) { conn.cancel() }
            }
            listener.start(queue: queue)
        }
    }

    func stop() { listener.cancel() }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int, Int) = (0, 0)
    func record(_ done: Int, _ total: Int) { lock.withLock { value = (max(value.0, done), total) } }
    var last: (Int, Int) { lock.withLock { value } }
}
