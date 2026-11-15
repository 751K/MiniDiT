import Foundation

/// 尼康 Z 系列的 Wi-Fi（PTP/IP，端口 15740）：配对，然后用标准 PTP 列文件、下载。
/// 配对流程来自 libgphoto2 issue #1314（在 Nikon ZR 固件 1.11 上抓包验证），MiniDiT 独立实现，没有复制代码。
///
/// - 每个相机网络配置只记一台电脑，按 Init_Command_Request 里的 GUID 认；所以 GUID 必须一直不变。
/// - 配置已配对别的电脑时，相机在握手时回 Init_Fail，原因 1。
/// - 配对：OpenSession 后紧接着发 0x952B 取配对码（相机屏幕同时显示），用户核对后发 0x935A(0x2001)，
///   再在相机上确认；相机发事件 0x4008，然后重启 Wi-Fi。两条连接直接关掉（不发 CloseSession），
///   用同一个 GUID 重连，前几次可能连不上。
/// - mDNS `_ptp._tcp` 的 TXT `apps=PAIR` 表示当前配置还没配对，`$DSC` 表示已配对。
public enum NikonWiFi {
    public static let getPairingCode: UInt16 = 0x952B
    public static let confirmPairing: UInt16 = 0x935A
    public static let deviceInfoChanged: UInt16 = 0x4008

    public enum Failure: LocalizedError {
        case pairedToAnotherComputer, notConfirmed, reconnectFailed, noStorage
        public var errorDescription: String? {
            switch self {
            case .pairedToAnotherComputer:
                "相机当前的网络配置已与另一台电脑配对。请在相机的“连接到电脑”中切换到为这台 Mac 建立的配置，或新建一个配置后重试。"
            case .notConfirmed: "相机上没有确认配对。请重新连接，核对配对码后在相机上确认。"
            case .reconnectFailed: "配对完成后相机重启了 Wi-Fi，未能重新连上。请确认 Mac 仍连着相机的网络后重试。"
            case .noStorage: "未能读取相机的存储卡。请确认已插卡，且相机的连接类型允许电脑访问。"
            }
        }
    }

    /// 相机 GUID 是否是尼康（以 USB 厂商号 04b0 开头；也接受按 UUID 小端排列的写法）。
    public static func isNikon(guid: [UInt8]) -> Bool {
        guard guid.count >= 4 else { return false }
        return (guid[0] == 0x04 && guid[1] == 0xB0) || (guid[2] == 0xB0 && guid[3] == 0x04)
    }

    /// 0x952B 的数据：u32 位数，然后每位一个字节，存的是数值 0–9（不是 ASCII）。`04 00 00 00 01 06 05 02` = "1652"。
    public static func pairingCode(_ data: Data) -> String? {
        let b = [UInt8](data)
        guard b.count >= 4 else { return nil }
        let n = Int(UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
        guard n > 0, n <= 16, b.count >= 4 + n, b[4..<(4 + n)].allSatisfy({ $0 <= 9 }) else { return nil }
        return b[4..<(4 + n)].map { String($0) }.joined()
    }

    /// 只握手、不开会话：读相机的 GUID 和名字，用来判断是不是尼康。配置已配对别的电脑时抛 pairedToAnotherComputer。
    public static func probe(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity) async throws -> (nikon: Bool, name: String) {
        let client = PTPIPClient(host: host, port: port, identity: identity)
        defer { Task { await client.disconnect() } }
        do {
            try await client.connect(timeout: 5)
        } catch PTPIPTransportError.initFailed(reason: 1) {
            // 只有尼康这样回：当前配置配对的是别的电脑。
            throw Failure.pairedToAnotherComputer
        }
        return (isNikon(guid: await client.cameraGUID), await client.cameraName)
    }

    /// 连接并打开存储卡接口。`needsPairing`：mDNS 说要配对（true）、说已配对（false）、不知道（nil，
    /// 这时先试着取配对码，相机不给就当已经配对过）。`showCode` 在拿到配对码时调用，界面显示给用户核对。
    public static func openLibrary(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity,
                                   needsPairing: Bool?, pairingTimeout: TimeInterval = 120,
                                   showCode: @escaping @Sendable (String) -> Void,
                                   progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PTPCameraLibrary {
        progress("正在建立 PTP/IP 连接…")
        var client = try await connect(host: host, port: port, identity: identity)
        if needsPairing != false {
            // 配对码必须是 OpenSession 之后的第一条命令。
            let r = try? await client.transaction(getPairingCode, requireOK: false)
            if let r, r.code == PTPResponse.ok, let code = pairingCode(r.data) {
                showCode(code)
                try await client.transaction(confirmPairing, [0x2001])
                progress("配对码 \(code)：请确认与相机屏幕上显示的一致，然后在相机上确认配对。")
                let events = client.events
                let confirmed = await withTaskGroup(of: Bool.self) { group in
                    group.addTask {
                        for await e in events where e.code == deviceInfoChanged { return true }
                        return false
                    }
                    group.addTask { try? await Task.sleep(for: .seconds(pairingTimeout)); return false }
                    let first = await group.next() ?? false
                    group.cancelAll()
                    return first
                }
                await client.disconnect()   // 不发 CloseSession：相机会自己重置连接
                guard confirmed else { throw Failure.notConfirmed }
                progress("配对完成，等待相机重新打开 Wi-Fi…")
                client = try await reconnect(host: host, port: port, identity: identity)
            } else if needsPairing == true {
                progress("相机没有给出配对码，按已配对继续")
            }
        }
        do {
            let info = await deviceInfo(client)
            guard let storages = try? await client.storageIDs(), !storages.isEmpty else { throw Failure.noStorage }
            progress("正在读取存储卡…")
            let opened = client
            return PTPCameraLibrary(client: opened, deviceInfo: info, onClose: { await opened.shutdown() })
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private static func connect(host: String, port: UInt16, identity: PTPIPHostIdentity) async throws -> PTPIPClient {
        let client = PTPIPClient(host: host, port: port, identity: identity)
        do {
            try await client.connect()
            try await client.openSession()
            return client
        } catch PTPIPTransportError.initFailed(reason: 1) {
            throw Failure.pairedToAnotherComputer
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// 相机配对后重启 Wi-Fi：每 2 秒重试一次，最多 40 秒。
    private static func reconnect(host: String, port: UInt16, identity: PTPIPHostIdentity) async throws -> PTPIPClient {
        let deadline = Date().addingTimeInterval(40)
        try await Task.sleep(for: .seconds(2))
        while Date() < deadline {
            try Task.checkCancellation()
            if let c = try? await connect(host: host, port: port, identity: identity) { return c }
            try await Task.sleep(for: .seconds(2))
        }
        throw Failure.reconnectFailed
    }

    private static func deviceInfo(_ client: PTPIPClient) async -> CameraDeviceInfo? {
        guard let r = try? await client.transaction(PTPOperation.getDeviceInfo, requireOK: false),
              r.code == PTPResponse.ok else { return nil }
        return CameraDeviceInfo.parse(r.data)
    }
}
