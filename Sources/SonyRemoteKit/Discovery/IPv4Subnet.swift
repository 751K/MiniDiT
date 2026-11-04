import Foundation

/// 一个 IPv4 地址 + 子网掩码（主机字节序），只做纯计算，方便单元测试。
public struct IPv4Subnet: Sendable, Hashable, CustomStringConvertible {
    /// 本机在该子网中的地址。
    public var address: UInt32
    public var mask: UInt32

    public init(address: UInt32, mask: UInt32) {
        self.address = address
        self.mask = mask
    }

    /// 由点分十进制地址和前缀长度构造，例如 `("192.168.1.23", 24)`。
    public init?(_ address: String, prefixLength: Int) {
        guard let a = Self.parse(address), (0...32).contains(prefixLength) else { return nil }
        self.init(address: a, mask: Self.mask(prefixLength: prefixLength))
    }

    /// 由点分十进制地址和点分十进制掩码构造，例如 `("192.168.1.23", "255.255.255.0")`。
    public init?(_ address: String, mask: String) {
        guard let a = Self.parse(address), let m = Self.parse(mask) else { return nil }
        self.init(address: a, mask: m)
    }

    public var network: UInt32 { address & mask }
    public var broadcast: UInt32 { network | ~mask }
    /// 掩码中 1 的个数（非连续掩码按 1 的个数计）。
    public var prefixLength: Int { mask.nonzeroBitCount }

    /// 可分配的主机地址个数（去掉网络地址和广播地址；/31、/32 按 RFC 3021 处理）。
    public var hostCount: Int { size <= 2 ? size : size - 2 }

    /// 子网的地址总数（含网络地址和广播地址）。
    private var size: Int { Int(~mask) + 1 }

    /// 子网里第一个可用地址（通常是 Wi-Fi 直连时相机/路由器自己的地址，即 .1）。
    public var firstHost: UInt32 { size <= 2 ? network : network + 1 }

    /// 子网内的全部主机地址（不含本机、网络地址和广播地址）。
    /// 子网比 `maxHosts` 大时，退回到本机所在的 /24，避免在 /16 之类的大网段里扫上几万个地址。
    public func scanHosts(maxHosts: Int = 1024) -> [UInt32] {
        let range = hostCount <= maxHosts ? self : IPv4Subnet(address: address, mask: Self.mask(prefixLength: 24))
        guard range.size > 2 else { return [] }
        return (range.network + 1 ..< range.broadcast).filter { $0 != address }
    }

    public var description: String { "\(Self.format(address))/\(prefixLength)" }

    // MARK: 工具函数

    public static func mask(prefixLength: Int) -> UInt32 {
        prefixLength <= 0 ? 0 : (prefixLength >= 32 ? .max : ~UInt32(0) << UInt32(32 - prefixLength))
    }

    /// 点分十进制 → UInt32（主机字节序）。格式不对时返回 nil。
    public static func parse(_ s: String) -> UInt32? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var v: UInt32 = 0
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), let b = UInt8(p) else { return nil }
            v = v << 8 | UInt32(b)
        }
        return v
    }

    /// UInt32（主机字节序）→ 点分十进制。
    public static func format(_ v: UInt32) -> String {
        "\(v >> 24 & 0xFF).\(v >> 16 & 0xFF).\(v >> 8 & 0xFF).\(v & 0xFF)"
    }
}
