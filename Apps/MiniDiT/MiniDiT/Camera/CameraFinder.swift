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
        return parts.isEmpty ? "没有连接网络" : parts.joined(separator: "；")
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
        progress("正在扫描 \(hosts.count) 个地址…")

        async let sshHosts = CameraDiscovery.scan(hosts: hosts, port: CameraSSHTunnel.sshPort, timeout: 0.4, concurrency: 48)
        async let directHosts = CameraDiscovery.scan(hosts: hosts, port: PTPIPClient.defaultPort, timeout: 0.4, concurrency: 48)
        let ssh = await sshHosts.map(\.host)
        let direct = await directHosts.map(\.host)

        var found: [FoundCamera] = direct.map {
            FoundCamera(host: $0, kind: .direct, knownName: knownByFingerprint["direct:\($0)"])
        }
        if !ssh.isEmpty { progress("正在确认 \(ssh.count) 台 SSH 设备是不是相机…") }
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
