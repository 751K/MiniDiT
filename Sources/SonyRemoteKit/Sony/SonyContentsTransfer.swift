import Foundation

public enum SonyContentsTransferError: Error, LocalizedError, Sendable {
    case storageUnavailable(capabilities: [String: String])

    public var errorDescription: String? {
        switch self {
        case .storageUnavailable(let caps):
            var s = String(localized: "相机没有开放存储卡访问。请确认：①相机固件已更新到最新；②相机里有存储卡；③相机处于「遥控拍摄」Wi-Fi 连接。", bundle: .miniDiT)
            if let media = caps["X_PTP_MediaServerSupport"] { s += String(localized: "\n（相机报告 MediaServerSupport = \(media)）", bundle: .miniDiT) }
            return s
        }
    }
}

/// 以「内容传输模式」连接相机，浏览并下载存储卡里的照片。
///
/// 流程（索尼 PTP 3 内容传输模式）：
/// PTP/IP 握手 → SDIO_OpenSession(会话, 1) → SDIO 握手 → SetContentsTransferMode(2, 1, 0)
/// → 等 0xD295 变成 1（或收到 StoreAdded）→ 标准 PTP 存储操作 + 0x9211 分块下载。
/// 这个模式下不能拍摄、取景或改参数；要拍照需要断开后用遥控模式重连。
public enum SonyContentsTransfer {
    public static func openLibrary(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity,
                                   tunnel: CameraSSHTunnel? = nil,
                                   readyTimeout: TimeInterval = 8,
                                   progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PTPCameraLibrary {
        let client = PTPIPClient(host: host, port: port, identity: identity, tunnel: tunnel)
        progress(tunnel == nil ? String(localized: "正在建立 PTP/IP 连接…", bundle: .miniDiT) : String(localized: "正在通过加密通道建立 PTP/IP 连接…", bundle: .miniDiT))
        try await client.connect()
        return try await openLibrary(transport: client, readyTimeout: readyTimeout, progress: progress)
    }

    /// 用已经连好的传输（Wi-Fi 或 USB）切到内容传输模式；失败时断开传输并抛错。
    public static func openLibrary(transport client: any PTPTransport, readyTimeout: TimeInterval = 8,
                                   progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PTPCameraLibrary {
        do {
            let caps = await SonySDIO.capabilities(client)

            progress(String(localized: "正在打开传输会话…", bundle: .miniDiT))
            try await SonySDIO.openSession(client, mode: .contentsTransfer)
            progress(String(localized: "正在进行索尼 SDIO 握手…", bundle: .miniDiT))
            _ = try await SonySDIO.handshake(client)

            progress(String(localized: "正在切换到内容传输模式…", bundle: .miniDiT))
            try await client.transaction(SonyOperation.setContentsTransferMode, [2, 1, 0])
            try await waitUntilReady(client, timeout: readyTimeout)

            // 确认真的能读到存储卡。
            let storages = try? await client.storageIDs()
            guard let storages, !storages.isEmpty else {
                throw SonyContentsTransferError.storageUnavailable(capabilities: caps)
            }

            progress(String(localized: "正在读取存储卡…", bundle: .miniDiT))
            return PTPCameraLibrary(client: client, largeObjectReads: true, onClose: {
                // 先退出传输模式（最多等 2 秒），再关闭会话。
                await client.setResponseTimeout(2)
                _ = try? await client.transaction(SonyOperation.setContentsTransferMode, [2, 0, 0], requireOK: false)
                await client.shutdown()
            })
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// 轮询 0xD295，直到相机报告内容传输就绪。
    private static func waitUntilReady(_ client: any PTPTransport, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let r = try await client.transaction(SonyOperation.getAllExtDevicePropInfo)
            let props = SonyDatasets.parseAllProperties(r.data)
            if props[SonyProperty.contentsTransferEnabled]?.intValue == 1 { return }
            // 有的固件不报 D295：属性表里根本没有它时，直接去试存储操作。
            if props[SonyProperty.contentsTransferEnabled] == nil && !props.isEmpty { return }
            try await Task.sleep(for: .milliseconds(150))
        }
    }
}
