import Foundation

/// 一条能执行 PTP 事务的连接。Wi-Fi 是 `PTPIPClient`（PTP/IP），USB 是 `PTPUSBClient`（ImageCaptureCore 透传）。
/// 上层（索尼遥控、存储卡浏览、下载）只依赖这个接口，不关心走的是哪种线。
public protocol PTPTransport: Actor {
    /// 相机发来的事件；连接断开时结束。
    nonisolated var events: AsyncStream<PTPEvent> { get }
    /// 相机名字（握手或设备信息里读到的）。
    var cameraName: String { get }
    /// 执行一次 PTP 事务。`dataOut` 不为空时有「电脑 → 相机」数据阶段。`transactionID` 给 nil 时自动编号。
    func transaction(_ code: UInt16, _ params: [UInt32], dataOut: Data?, requireOK: Bool,
                     transactionID: UInt32?) async throws -> PTPTransactionResult
    /// 数据阶段不进内存，分块交给 sink（大文件直接写盘）。onStart 收到相机报告的总字节数。
    func streamingTransaction(_ code: UInt16, _ params: [UInt32], onStart: @escaping @Sendable (UInt64) -> Void,
                              sink: @escaping @Sendable (Data) throws -> Void) async throws -> PTPTransactionResult
    func setResponseTimeout(_ t: TimeInterval)
    /// 尽量体面地关闭（能发 CloseSession 就发），然后断开。
    func shutdown() async
    /// 立即断开，不等任何事务。
    func disconnect()
}

public extension PTPTransport {
    /// 带默认参数的写法（协议要求里不能写默认值）。
    @discardableResult
    func transaction(_ code: UInt16, _ params: [UInt32] = [], dataOut: Data? = nil,
                     requireOK: Bool = true) async throws -> PTPTransactionResult {
        try await transaction(code, params, dataOut: dataOut, requireOK: requireOK, transactionID: nil)
    }

    @discardableResult
    func transaction(_ code: UInt16, _ params: [UInt32] = [], requireOK: Bool = true,
                     transactionID: UInt32?) async throws -> PTPTransactionResult {
        try await transaction(code, params, dataOut: nil, requireOK: requireOK, transactionID: transactionID)
    }

    @discardableResult
    func streamingTransaction(_ code: UInt16, _ params: [UInt32] = [],
                              sink: @escaping @Sendable (Data) throws -> Void) async throws -> PTPTransactionResult {
        try await streamingTransaction(code, params, onStart: { _ in }, sink: sink)
    }
}

extension PTPIPClient: PTPTransport {}
