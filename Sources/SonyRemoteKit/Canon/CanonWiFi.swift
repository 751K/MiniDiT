import Foundation
import Network

/// 佳能 EOS 的 Wi-Fi（相机菜单「Wi-Fi › 遥控（EOS Utility）」，PTP/IP 端口 15740）：用标准 PTP 列文件、下载。
/// 协议依据 libgphoto2（camlibs/ptp2）的源码和 Troopers 2013「Paparazzi over IP」的分析，MiniDiT 独立实现，没有复制代码。
///
/// - 配对：相机处于配对状态时，电脑发 Init_Command_Request，相机在屏幕上请用户确认，之后记住这台电脑的 GUID。
///   以后只认 GUID（不看电脑名），所以 GUID 必须一直不变；GUID 不对时相机回 Init_Fail。
/// - OpenSession 偶尔要重试；会话打开后，相机支持 0x9114 时先发 SetRemoteMode(1)，否则有的机身不让读卡。
/// - 下载用标准 GetPartialObject，每块 1 MB（EOS Utility 也是 1 MB，EOS R 不接受 5 MB 的块）。
/// - 约 10 秒发一次 0x911D KeepDeviceOn，防止相机自动关机或断开。
/// - 有的机身关会话后会出问题，断开时只关连接，不发 CloseSession。
/// - ≥4 GB 的文件：ObjectInfo 里的大小是 0xFFFFFFFF，退回用 GetObject 整体读取（未用真机验证）。
public enum CanonWiFi {
    public static let setRemoteMode: UInt16 = 0x9114
    public static let keepDeviceOn: UInt16 = 0x911D
    /// 佳能 RAW / 视频的对象格式码。
    public static let formatCR3: UInt16 = 0xB108
    public static let formatCR2: UInt16 = 0xB103
    public static let formatMOV: UInt16 = 0xB104
    public static let downloadChunk: UInt32 = 1024 * 1024
    static let keepAliveInterval: Duration = .seconds(10)

    public enum Failure: LocalizedError, Equatable {
        case notPaired, noStorage
        public var errorDescription: String? {
            switch self {
            case .notPaired:
                String(localized: "佳能相机拒绝了连接，这台 Mac 可能尚未与相机配对。请在相机上进入「Wi-Fi › 遥控（EOS Utility）」，选择与电脑配对，然后在 MiniDiT 中重新连接，并在相机上确认。", bundle: .miniDiT)
            case .noStorage: String(localized: "未能读取相机的存储卡。请确认已插卡，并且相机处于「遥控（EOS Utility）」连接。", bundle: .miniDiT)
            }
        }
    }

    /// Init_Command_Ack 里的相机名看起来是不是佳能（默认名形如「EOS R6」或「Canon EOS 5D Mark IV」）。
    public static func looksLikeCanon(name: String) -> Bool {
        let n = name.uppercased()
        return n.contains("CANON") || n.hasPrefix("EOS")
    }

    /// 连接并打开存储卡接口。相机还没配对时，这一步会让相机弹出确认，`pairingTimeout` 内等用户确认。
    public static func openLibrary(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity,
                                   progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> PTPCameraLibrary {
        progress(String(localized: "正在建立 PTP/IP 连接…", bundle: .miniDiT))
        let client = PTPIPClient(host: host, port: port, identity: identity)
        do {
            // 未配对时相机要等用户在机身上确认，握手可能要好一会儿。
            try await client.connect(timeout: 60)
        } catch PTPIPTransportError.initFailed {
            throw Failure.notPaired
        }
        do {
            try await openSession(client)
            let info = await deviceInfo(client)
            if info.map({ $0.operations.isEmpty || $0.operations.contains(setRemoteMode) }) ?? true {
                _ = try? await client.transaction(setRemoteMode, [1], requireOK: false)
            }
            guard let storages = try? await client.storageIDs(), !storages.isEmpty else { throw Failure.noStorage }
            progress(String(localized: "正在读取存储卡…", bundle: .miniDiT))
            let keepAlive = info.map { $0.operations.contains(keepDeviceOn) } ?? false
                ? Task { [client] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: keepAliveInterval)
                        if Task.isCancelled { break }
                        _ = try? await client.transaction(keepDeviceOn, requireOK: false)
                    }
                } : nil
            return PTPCameraLibrary(client: client, deviceInfo: info, chunkSize: downloadChunk, onClose: {
                keepAlive?.cancel()
                await client.disconnect()   // 不发 CloseSession
            })
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// 佳能的 OpenSession 偶尔第一次不成功：最多试三次。
    private static func openSession(_ client: PTPIPClient) async throws {
        var last: Error?
        for attempt in 0..<3 {
            do { try await client.openSession(); return } catch { last = error }
            if attempt < 2 { try await Task.sleep(for: .seconds(1)) }
        }
        throw last ?? Failure.noStorage
    }

    private static func deviceInfo(_ client: PTPIPClient) async -> CameraDeviceInfo? {
        guard let r = try? await client.transaction(PTPOperation.getDeviceInfo, requireOK: false),
              r.code == PTPResponse.ok else { return nil }
        return CameraDeviceInfo.parse(r.data)
    }
}

/// 佳能相机在 mDNS `_ptp._tcp` 里广播，TXT 带 `tid.canon.com`（已配对电脑的 GUID）。
/// 握手被拒时用它判断对方是不是佳能，好给出佳能的配对说明。
public enum CanonBonjour {
    public static func isAdvertising(timeout: TimeInterval = 1.5) async -> Bool {
        final class Box: @unchecked Sendable { let lock = NSLock(); var found = false }
        let box = Box()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_ptp._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                guard case let .bonjour(record) = r.metadata else { continue }
                if isCanon(record.dictionary, name: { if case let .service(n, _, _, _) = r.endpoint { n } else { "" } }()) {
                    box.lock.withLock { box.found = true }
                }
            }
        }
        browser.start(queue: DispatchQueue(label: "MiniDiT.CanonBonjour"))
        try? await Task.sleep(for: .seconds(timeout))
        browser.cancel()
        return box.lock.withLock { box.found }
    }

    static func isCanon(_ txt: [String: String], name: String) -> Bool {
        txt.keys.contains { $0.lowercased().hasSuffix("canon.com") } || CanonWiFi.looksLikeCanon(name: name)
    }
}
