import Foundation
import Darwin

/// 读取本机网络接口和路由表（getifaddrs + sysctl 路由转储）。
enum NetworkInterfaces {
    /// 指定接口（iPhone 的 Wi-Fi 是 en0）上的第一个 IPv4 地址和掩码。接口不存在或没有 IPv4 时返回 nil。
    static func ipv4Subnet(interface: String) -> IPv4Subnet? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard String(cString: ifa.pointee.ifa_name) == interface,
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = ifa.pointee.ifa_netmask else { continue }
            let a = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            return IPv4Subnet(address: a, mask: m)
        }
        return nil
    }

    /// 指定接口上的 IPv4 默认网关（Wi-Fi 直连时就是相机）。
    ///
    /// iOS SDK 没有公开 `<net/route.h>`，但 `sysctl(NET_RT_FLAGS)` 路由转储在 iOS 上可用（不少 APP 用它读网关），
    /// 所以这里手写常量和 `rt_msghdr` 的偏移。读取失败时返回 nil，调用方会退回到猜测的 .1 地址。
    static func defaultGateway(interface: String) -> UInt32? {
        let index = if_nametoindex(interface)
        guard index != 0, let buf = routeDump() else { return nil }
        return parseDefaultGateways(buf).first { $0.interfaceIndex == UInt16(truncatingIfNeeded: index) }?.gateway
    }

    // MARK: 路由表解析

    // 以下常量来自 xnu 的 <sys/socket.h> 和 <net/route.h>（iOS SDK 未公开）。
    static let netRTFlags: Int32 = 2          // NET_RT_FLAGS
    static let rtfUp: Int32 = 0x1             // RTF_UP
    static let rtfGateway: Int32 = 0x2        // RTF_GATEWAY
    static let rtmVersion: UInt8 = 5          // RTM_VERSION
    static let rtaDst: Int32 = 0x1            // RTA_DST
    static let rtaGateway: Int32 = 0x2        // RTA_GATEWAY
    static let rtaxMax = 8                    // RTAX_MAX
    /// sizeof(struct rt_msghdr)：12 个 4 字节字段（含 2 字节对齐填充）+ 56 字节 rt_metrics。
    static let rtMsghdrSize = 92

    struct GatewayRoute: Equatable {
        var interfaceIndex: UInt16
        var gateway: UInt32
    }

    private static func routeDump() -> [UInt8]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, netRTFlags, rtfGateway]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return nil }
        // 两次调用之间路由表可能变大，多留一些余量。
        size += size / 2
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &buf, &size, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(size))
    }

    /// 从路由转储中找出所有目的地址为 0.0.0.0 的 IPv4 网关路由（包括 iOS 的按接口限定默认路由）。
    static func parseDefaultGateways(_ buf: [UInt8]) -> [GatewayRoute] {
        func u16(_ o: Int) -> UInt16 { UInt16(buf[o]) | UInt16(buf[o + 1]) << 8 }
        func i32(_ o: Int) -> Int32 {
            Int32(bitPattern: UInt32(buf[o]) | UInt32(buf[o + 1]) << 8 | UInt32(buf[o + 2]) << 16 | UInt32(buf[o + 3]) << 24)
        }
        // sockaddr_in 的 sin_addr 在偏移 4，网络字节序。
        func inAddr(_ o: Int, len: Int) -> UInt32 {
            guard len >= 8, o + 8 <= buf.count else { return 0 }
            return UInt32(buf[o + 4]) << 24 | UInt32(buf[o + 5]) << 16 | UInt32(buf[o + 6]) << 8 | UInt32(buf[o + 7])
        }

        var routes: [GatewayRoute] = []
        var offset = 0
        while offset + rtMsghdrSize <= buf.count {
            let msgLen = Int(u16(offset))
            guard msgLen >= rtMsghdrSize, offset + msgLen <= buf.count else { break }
            defer { offset += msgLen }
            guard buf[offset + 2] == rtmVersion else { continue }
            let index = u16(offset + 4)
            let flags = i32(offset + 8)
            let addrs = i32(offset + 12)
            guard flags & rtfUp != 0, flags & rtfGateway != 0 else { continue }

            var dst: UInt32? = nil
            var gateway: UInt32? = nil
            var sa = offset + rtMsghdrSize
            let end = offset + msgLen
            for bit in 0..<rtaxMax where addrs & (1 << bit) != 0 {
                guard sa < end else { break }
                let len = Int(buf[sa])
                let family = sa + 1 < end ? Int32(buf[sa + 1]) : 0
                if bit == 0 { dst = (len == 0 || family == AF_INET) ? inAddr(sa, len: min(len, end - sa)) : nil }
                if bit == 1, family == AF_INET { gateway = inAddr(sa, len: min(len, end - sa)) }
                // Darwin 的 sockaddr 按 4 字节对齐，长度为 0 时也占 4 字节。
                sa += len > 0 ? (len + 3) & ~3 : 4
            }
            if dst == 0, let gateway, gateway != 0 {
                routes.append(GatewayRoute(interfaceIndex: index, gateway: gateway))
            }
        }
        return routes
    }
}
