#if canImport(ImageCaptureCore)
import Foundation
@preconcurrency import ImageCaptureCore

/// ICCameraDevice 不是 Sendable；所有调用都在主线程上做，用这个盒子带过并发边界。
private struct CameraBox: @unchecked Sendable { let camera: ICCameraDevice }

/// ImageCaptureCore 里的一台 USB 相机：会话由系统打开，PTP 命令走 `requestSendPTPCommand` 透传，
/// 事件走 `ptpEventHandler`。不需要装驱动，也不需要额外权限（App 没有沙盒）。
public final class ICPassthroughDevice: PTPPassthroughDevice, @unchecked Sendable {
    public let camera: ICCameraDevice
    private let lock = NSLock()
    private var removalHandler: (@Sendable () -> Void)?
    private var removed = false

    private init(camera: ICCameraDevice) { self.camera = camera }

    public var name: String { camera.name ?? String(localized: "USB 相机", bundle: .miniDiT) }

    /// 打开会话（系统层面的；相机上的 PTP 会话由 ptpcamerad 管）。
    @MainActor
    public static func open(_ camera: ICCameraDevice, timeout: TimeInterval = 20) async throws -> ICPassthroughDevice {
        let device = ICPassthroughDevice(camera: camera)
        let box = CameraBox(camera: camera)
        if !camera.hasOpenSession {
            // 打开会话；相机没响应时按超时报错（超时后再到的回调被 OnceResume 吃掉）。
            let once = OnceResume()
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                box.camera.requestOpenSession(options: [:]) { error in
                    once.run { if let error { cont.resume(throwing: error) } else { cont.resume() } }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                    once.run { cont.resume(throwing: PTPIPTransportError.connectTimeout) }
                }
            }
        }
        return device
    }

    public func send(command: Data, outData: Data?) async throws -> (data: Data, response: Data) {
        if lock.withLock({ removed }) { throw PTPUSBError.disconnected }
        let box = CameraBox(camera: camera)
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.main.async {
                box.camera.requestSendPTPCommand(command, outData: outData) { data, response, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, response)) }
                }
            }
        }
    }

    public func setEventHandler(_ handler: @escaping @Sendable (Data) -> Void) {
        let box = CameraBox(camera: camera)
        DispatchQueue.main.async { box.camera.ptpEventHandler = { handler($0) } }
    }

    public func setRemovalHandler(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { removalHandler = handler }
    }

    /// 设备浏览器发现相机被拔掉时调用。
    public func deviceRemoved() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard !removed else { return nil }
            removed = true
            return removalHandler
        }
        handler?()
    }

    public func close() async {
        let box = CameraBox(camera: camera)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async {
                box.camera.ptpEventHandler = { _ in }
                guard box.camera.hasOpenSession else { cont.resume(); return }
                box.camera.requestCloseSession(options: [:]) { _ in cont.resume() }
            }
        }
        deviceRemoved()
    }
}
private final class OnceResume: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in if done { return false }; done = true; return true }
        if first { body() }
    }
}
#endif
