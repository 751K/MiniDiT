import Foundation

/// 相机「访问身份验证」用的账号。用户名和密码在相机 MENU → 网络 → 网络选项 → 访问身份验证设置 里查看。
public struct SSHCredentials: Sendable, Codable, Equatable {
    public var username: String
    public var password: String
    /// 用户确认过的相机指纹（SHA256 base64）。为 nil 表示还没确认过。
    public var trustedFingerprint: String?

    public init(username: String, password: String, trustedFingerprint: String? = nil) {
        self.username = username
        self.password = password
        self.trustedFingerprint = trustedFingerprint
    }
}

/// 到相机的 SSH 隧道。PTP/IP 的命令、事件两条连接都从这里开 direct-tcpip 通道到相机的 localhost:15740。
public final class CameraSSHTunnel: Sendable {
    public static let sshPort: UInt16 = 22
    public static let ptpipTarget = ("localhost", PTPIPClient.defaultPort)

    private let session: SSHSession
    public let hostKey: SSHHostKeyInfo
    public let negotiated: SSHNegotiated?

    private init(session: SSHSession, hostKey: SSHHostKeyInfo) {
        self.session = session
        self.hostKey = hostKey
        self.negotiated = session.negotiated
    }

    /// 建立 SSH 连接：握手 → 校验指纹（validate 返回 false 就中止，不发送密码）→ 登录。
    public static func open(host: String, port: UInt16 = sshPort, credentials: SSHCredentials, timeout: TimeInterval = 10,
                            validate: @escaping @Sendable (SSHHostKeyInfo) async -> Bool) async throws -> CameraSSHTunnel {
        let session = SSHSession(host: host, port: port)
        try await session.connect(username: credentials.username, password: credentials.password,
                                  timeout: timeout, validateHostKey: validate)
        guard let key = session.hostKey else { throw SSHTunnelError.handshake("没有拿到相机指纹") }
        return CameraSSHTunnel(session: session, hostKey: key)
    }

    /// 只握手、不登录，读出相机指纹和支持的登录方式（诊断用）。
    public static func probe(host: String, port: UInt16 = sshPort, timeout: TimeInterval = 5) async throws -> (SSHHostKeyInfo, SSHNegotiated) {
        try await SSHSession(host: host, port: port).probe(username: "probe", timeout: timeout)
    }

    package func openPTPIPChannel() async throws -> PTPIPSocket {
        let stream = try await session.openDirectTCPIP(host: Self.ptpipTarget.0, port: Self.ptpipTarget.1)
        return PTPIPSocket(stream: stream)
    }

    public func close() { session.close() }
    public func shutdown() async { await session.shutdown() }
}
