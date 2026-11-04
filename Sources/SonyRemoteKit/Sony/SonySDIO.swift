import Foundation

extension SonyOperation {
    /// SDIO_OpenSession：p1 会话 ID，p2 功能模式。
    public static let sdioOpenSession: UInt16 = 0x9210
    /// 64 位偏移的分块读取：p1 句柄，p2/p3 偏移低/高 32 位，p4 最大字节数（不能是 0xFFFFFFFF）。
    public static let getPartialLargeObject: UInt16 = 0x9211
    /// 内容传输模式开关：p1 选择方（2 = 由手机选），p2 0 关 / 1 开，p3 附加信息。无数据阶段。
    public static let setContentsTransferMode: UInt16 = 0x9212
    /// 读取设备描述文件：p1 1 = dd.xml，2 = DigitalImagingDesc.xml。可在打开会话前执行。
    public static let getDeviceDescriptionFile: UInt16 = 0x923A
}

extension SonyProperty {
    /// 内容传输是否已就绪：0 未就绪，1 就绪。
    public static let contentsTransferEnabled: UInt16 = 0xD295
}

extension SonyEvent {
    /// 内容传输被中断：p1 1 = 相机忙，2 = 状态错误。
    public static let contentsTransferEvent: UInt16 = 0xC20D
}

extension PTPEventCode {
    public static let storeAdded: UInt16 = 0x4004
    public static let storeRemoved: UInt16 = 0x4005
}

extension PTPResponse {
    public static let storeNotAvailable: UInt16 = 0x2013
}

/// SDIO_OpenSession 的功能模式。
public enum SonyFunctionMode: UInt32, Sendable {
    case remoteControl = 0
    case contentsTransfer = 1
    case remoteControlWithTransfer = 2
}

/// 索尼 SDIO 握手，遥控模式和传输模式共用。
enum SonySDIO {
    /// 打开会话。传了 mode 时用 SDIO_OpenSession(0x9210)，相机不认识就退回标准 OpenSession。
    static func openSession(_ client: PTPIPClient, mode: SonyFunctionMode?) async throws {
        var sessionID: UInt32 = 1
        var useSDIO = mode != nil
        for _ in 0..<10 {
            let r: PTPTransactionResult
            if useSDIO, let mode {
                r = try await client.transaction(SonyOperation.sdioOpenSession, [sessionID, mode.rawValue],
                                                 requireOK: false, transactionID: 0)
            } else {
                r = try await client.transaction(PTPOperation.openSession, [sessionID], requireOK: false, transactionID: 0)
            }
            switch r.code {
            case PTPResponse.ok, PTPResponse.sessionAlreadyOpen, SonyResponse.sessionAlreadyOpenAlt:
                return
            case PTPResponse.operationNotSupported where useSDIO:
                useSDIO = false
            case SonyResponse.invalidTransactionID:
                sessionID += 1
            case PTPResponse.accessDenied, PTPResponse.deviceBusy:
                try await Task.sleep(for: .milliseconds(300))
            case SonyResponse.authenticationFailed:
                throw PTPIPTransportError.initFailed(reason: UInt32(r.code))
            default:
                throw PTPError(operation: useSDIO ? SonyOperation.sdioOpenSession : PTPOperation.openSession, code: r.code)
            }
        }
        throw PTPError(operation: PTPOperation.openSession, code: PTPResponse.deviceBusy)
    }

    /// SDIO_Connect 1、2 → GetExtDeviceInfo → SDIO_Connect 3。
    static func handshake(_ client: PTPIPClient) async throws -> SonyDatasets.ExtDeviceInfo {
        _ = try? await client.transaction(PTPOperation.getDeviceInfo)
        try await client.transaction(SonyOperation.sdioConnect, [1, 0, 0])
        try await client.transaction(SonyOperation.sdioConnect, [2, 0, 0])

        var info: SonyDatasets.ExtDeviceInfo?
        for _ in 0..<20 {
            let r = try await client.transaction(SonyOperation.getExtDeviceInfo, [UInt32(SonyProtocolVersion.v300), 1])
            if let parsed = try? SonyDatasets.parseExtDeviceInfo(r.data), !parsed.codes.isEmpty {
                info = parsed
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let info else { throw SonyCameraError.notSonyRemoteCapable }
        try await client.transaction(SonyOperation.sdioConnect, [3, 0, 0])
        return info
    }

    /// 读取 DigitalImagingDesc.xml 里与传输相关的能力标记（诊断用，失败返回空）。
    static func capabilities(_ client: PTPIPClient) async -> [String: String] {
        guard let r = try? await client.transaction(SonyOperation.getDeviceDescriptionFile, [2], requireOK: false),
              r.code == PTPResponse.ok, let xml = String(data: r.data, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for tag in ["X_PTP_MediaServerSupport", "X_PTP_ContentsTransferSupport", "X_PTP_RemoteControlSupport",
                    "X_SSH_Support", "X_PTP_PairingNecessity"] {
            if let open = xml.range(of: "<\(tag)>"), let close = xml.range(of: "</\(tag)>", range: open.upperBound..<xml.endIndex) {
                out[tag] = String(xml[open.upperBound..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }
}
