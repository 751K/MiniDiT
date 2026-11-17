import Foundation

/// USB 相机打开存储卡浏览：
/// - 相机报标准存储卡（MTP / PTP 模式，各品牌通用）：直接用标准 PTP 浏览、下载。
/// - 索尼「电脑遥控」模式（标准操作看不到卡）：先试远程传输（不锁相机，两个卡槽），不行再切内容传输模式。
public enum USBCameraOpener {
    public enum Failure: LocalizedError {
        case noStorage
        public var errorDescription: String? {
            String(localized: "相机没有通过 USB 提供存储卡。请确认已插卡，并把相机的 USB 连接方式设为“MTP”或“PC 遥控”（索尼）。", bundle: .miniDiT)
        }
    }

    public static let sonyModelPrefixes = ["ILCE", "ILME", "ILCA", "ZV-", "DSC-"]

    public static func isSony(name: String, manufacturer: String?) -> Bool {
        (manufacturer ?? "").localizedCaseInsensitiveContains("sony") || sonyModelPrefixes.contains { name.hasPrefix($0) }
    }

    /// - makeTransport: 每次返回一个新打开的 USB 传输（某种方式失败时传输会被关掉，换下一种要重新打开）。
    public static func openLibrary(name: String, makeTransport: @Sendable () async throws -> any PTPTransport,
                                   progress: @escaping @Sendable (String) -> Void = { _ in },
                                   log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> any CameraLibrary {
        progress(String(localized: "正在读取相机信息…", bundle: .miniDiT))
        let transport = try await makeTransport()
        let info = await SonyRemoteTransferLibrary.fetchDeviceInfo(transport)
        let sony = isSony(name: info?.model ?? name, manufacturer: info?.manufacturer)
        log("USB 相机：\(info.map { "\($0.manufacturer) \($0.model)" } ?? name)")
        let storages = (try? await transport.storageIDs()) ?? []
        if !storages.isEmpty {
            log("USB：标准 PTP 浏览（\(storages.count) 张卡）")
            progress(String(localized: "正在读取存储卡…", bundle: .miniDiT))
            return PTPCameraLibrary(client: transport, deviceInfo: info, onClose: { await transport.shutdown() })
        }
        guard sony else {
            await transport.shutdown()
            throw Failure.noStorage
        }
        do {
            let lib = try await SonyRemoteTransferLibrary.open(transport: transport, progress: progress)
            log("USB：索尼远程传输")
            return lib
        } catch {
            log("USB：远程传输不可用（\(error.localizedDescription)），改用内容传输模式")
            let again = try await makeTransport()
            return try await SonyContentsTransfer.openLibrary(transport: again, progress: progress)
        }
    }
}
