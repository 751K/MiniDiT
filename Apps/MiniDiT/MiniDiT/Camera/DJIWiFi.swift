import CoreWLAN
import Darwin
import Foundation

/// 让 Mac 加入大疆相机自己开的 Wi-Fi 热点（相机地址固定是 192.168.2.1），用完再离开。
/// 用系统自带的 networksetup 加入：它不需要定位权限（CoreWLAN 扫描网络名需要）。
/// 加入期间这块 Wi-Fi 网卡不能上网；离开后 macOS 自动回到原来的网络。
enum DJIWiFi {
    struct Joined: Sendable {
        let interface: String
        let ssid: String
        /// 这个网络是我们加进「首选网络」列表的：离开时删掉，免得以后自动连上相机。
        let addedPreferred: Bool
        /// 本来就连着相机热点，什么都没做。
        let alreadyThere: Bool
    }

    enum Failure: LocalizedError {
        case noInterface, joinFailed(ssid: String, password: String)
        var errorDescription: String? {
            switch self {
            case .noInterface: "这台 Mac 没有可用的 Wi-Fi。"
            case .joinFailed(let ssid, let password):
                "无法自动加入相机的 Wi-Fi“\(ssid)”。请在菜单栏的 Wi-Fi 中手动加入（密码：\(password)），保持相机开机，然后再次连接。"
            }
        }
    }

    /// 本机是否已经拿到相机热点分配的地址（192.168.2.x）。
    static var onCameraNetwork: Bool {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return false }
        defer { freeifaddrs(list) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = addr
            inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            if String(cString: buf).hasPrefix("192.168.2.") { return true }
        }
        return false
    }

    /// 加入热点。相机刚被唤醒时热点要过几秒到十几秒才出现：反复尝试，6 秒后还没有就用 `nudge` 催一下相机。
    static func join(ssid: String, password: String, timeout: TimeInterval = 45,
                     nudge: @escaping @Sendable () async -> Void, log: @escaping @Sendable (String) -> Void) async throws -> Joined {
        guard let iface = CWWiFiClient.shared().interface()?.interfaceName else { throw Failure.noInterface }
        if onCameraNetwork { return Joined(interface: iface, ssid: ssid, addedPreferred: false, alreadyThere: true) }
        let before = await run(["-listpreferredwirelessnetworks", iface]).output
        let wasPreferred = before.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == ssid }
        let start = Date()
        var nudged = false
        while Date().timeIntervalSince(start) < timeout {
            try Task.checkCancellation()
            let r = await run(["-setairportnetwork", iface, ssid, password])
            // 失败时 networksetup 也返回 0，只在输出里写原因。
            if r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                for _ in 0..<30 {
                    if onCameraNetwork {
                        log("已加入相机 Wi-Fi \(ssid)")
                        return Joined(interface: iface, ssid: ssid, addedPreferred: !wasPreferred, alreadyThere: false)
                    }
                    try await Task.sleep(for: .milliseconds(500))
                }
            } else {
                log("加入相机 Wi-Fi：\(r.output.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            if !nudged, Date().timeIntervalSince(start) > 6 { nudged = true; await nudge() }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure.joinFailed(ssid: ssid, password: password)
    }

    /// 离开相机热点：删掉我们加的首选网络，断开后 macOS 自动回到原来的网络。
    static func leave(_ j: Joined) async {
        guard !j.alreadyThere else { return }
        if j.addedPreferred { _ = await run(["-removepreferredwirelessnetwork", j.interface, j.ssid]) }
        CWWiFiClient.shared().interface(withName: j.interface)?.disassociate()
    }

    private static func run(_ args: [String]) async -> (status: Int32, output: String) {
        await withCheckedContinuation { c in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe; p.standardError = pipe
                do { try p.run() } catch { c.resume(returning: (-1, error.localizedDescription)); return }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                c.resume(returning: (p.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
        }
    }
}
