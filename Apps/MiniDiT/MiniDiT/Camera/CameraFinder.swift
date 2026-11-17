import Foundation
import SonyRemoteKit

/// 搜索结果里的一台相机。
struct FoundCamera: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// 开了访问身份验证（SSH）。
        case ssh(fingerprint: String)
        /// 没开访问身份验证，15740 端口可以直连。
        case direct
    }

    var host: String
    var kind: Kind
    /// 连过的相机的名字。
    var knownName: String?
    var id: String { host }

    var fingerprint: String {
        switch kind {
        case .ssh(let f): f
        case .direct: "direct:\(host)"
        }
    }
}

/// 在 Mac 所在的网络里找相机：
/// - 连过的相机先按上次的地址找；
/// - 再扫描子网的 22 和 15740 端口。22 端口要再做一次 SSH 握手，只认「只提供键盘交互登录」的主机
///   （索尼相机的特征；Mac、NAS 等普通 SSH 服务器还会提供公钥登录）。
enum CameraFinder {
    /// 有 IPv4 地址的网络接口（Wi-Fi 一般是 en0，有线网卡在别的 en*）。
    static func interfaces() -> [String] {
        (0..<10).map { "en\($0)" }.filter { CameraDiscovery.wifiSubnet(interface: $0) != nil }
    }

    static func networkSummary() -> String {
        let parts = interfaces().compactMap { i -> String? in
            guard let s = CameraDiscovery.wifiSubnet(interface: i) else { return nil }
            let gw = CameraDiscovery.defaultGateway(interface: i).map { "，网关 \($0)" } ?? ""
            return "\(i)：\(s)\(gw)"
        }
        return parts.isEmpty ? "未连接网络" : parts.joined(separator: "；")
    }

    /// 有没有被 macOS 的「本地网络」隐私设置拦住：没有权限时，连局域网地址会立刻返回「没有到主机的路由」。
    static func localNetworkBlocked() async -> Bool {
        guard let gw = interfaces().lazy.compactMap({ CameraDiscovery.defaultGateway(interface: $0) }).first else { return false }
        return await Task.detached { connectErrno(host: gw, port: 53) == EHOSTUNREACH }.value
    }

    /// 非阻塞 connect，返回 errno（成功或超时返回 0）。
    private static func connectErrno(host: String, port: UInt16) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return 0 }
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r == 0 { return 0 }
        if errno != EINPROGRESS { return errno }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 800) > 0 else { return 0 }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err
    }

    static func search(known: [KnownCamera],
                       progress: @escaping @Sendable (String) -> Void) async -> [FoundCamera] {
        let knownByFingerprint = Dictionary(known.map { ($0.fingerprint, $0.name) }, uniquingKeysWith: { a, _ in a })
        var hosts: [String] = known.map(\.host)
        for i in interfaces() {
            hosts += CameraDiscovery.gatewayCandidates(interface: i)
            hosts += CameraDiscovery.scanHosts(interface: i)
        }
        var seen = Set<String>()
        hosts = hosts.filter { seen.insert($0).inserted }
        progress(String(localized: "正在扫描 \(hosts.count) 个地址…"))

        async let sshHosts = CameraDiscovery.scan(hosts: hosts, port: CameraSSHTunnel.sshPort, timeout: 0.4, concurrency: 48)
        async let directHosts = CameraDiscovery.scan(hosts: hosts, port: PTPIPClient.defaultPort, timeout: 0.4, concurrency: 48)
        let ssh = await sshHosts.map(\.host)
        let direct = await directHosts.map(\.host)

        var found: [FoundCamera] = direct.map {
            FoundCamera(host: $0, kind: .direct, knownName: knownByFingerprint["direct:\($0)"])
        }
        if !ssh.isEmpty { progress(String(localized: "正在确认 \(ssh.count) 台 SSH 设备是否为相机…")) }
        let checked = await withTaskGroup(of: FoundCamera?.self) { group in
            for host in ssh where !direct.contains(host) {
                group.addTask {
                    guard let (key, neg) = try? await CameraSSHTunnel.probe(host: host, timeout: 4) else { return nil }
                    let fp = key.sha256Base64
                    let methods = Set(neg.authMethodsOffered.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
                    let known = knownByFingerprint[fp]
                    guard known != nil || methods == ["keyboard-interactive"] else { return nil }
                    return FoundCamera(host: host, kind: .ssh(fingerprint: fp), knownName: known)
                }
            }
            var out: [FoundCamera] = []
            for await c in group { if let c { out.append(c) } }
            return out
        }
        found += checked
        // 连过的排前面，其余按 IP。
        return found.sorted {
            if ($0.knownName != nil) != ($1.knownName != nil) { return $0.knownName != nil }
            return $0.host.compare($1.host, options: .numeric) == .orderedAscending
        }
    }
}
