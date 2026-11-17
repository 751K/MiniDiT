import Foundation
@preconcurrency import ImageCaptureCore
import SonyRemoteKit

/// 一台通过 USB 接着的 PTP 相机（ImageCaptureCore 发现的）。
struct USBCamera: Identifiable, Hashable {
    let id: String
    let name: String
    let device: DeviceRef

    /// ICCameraDevice 不是 Sendable，只在主线程上用。
    final class DeviceRef: Hashable, @unchecked Sendable {
        let camera: ICCameraDevice
        init(_ camera: ICCameraDevice) { self.camera = camera }
        static func == (a: DeviceRef, b: DeviceRef) -> Bool { a.camera === b.camera }
        func hash(into h: inout Hasher) { h.combine(ObjectIdentifier(camera)) }
    }

    var isSony: Bool { USBCameraOpener.isSony(name: name, manufacturer: nil) }
}

/// 监听 USB 相机的插拔。只列能透传 PTP 命令的 USB 相机；大容量存储模式的相机会作为磁盘挂载，走读卡器那条路。
@MainActor
final class USBCameraBrowser: NSObject, ICDeviceBrowserDelegate {
    private let browser = ICDeviceBrowser()
    private var cameras: [ICCameraDevice] = []
    var onChange: ([USBCamera]) -> Void = { _ in }
    var onRemove: (ICCameraDevice) -> Void = { _ in }

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
    }

    private func publish() {
        onChange(cameras.map { USBCamera(id: $0.uuidString ?? $0.name ?? "usb", name: $0.name ?? String(localized: "USB 相机"), device: .init($0)) })
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        MainActor.assumeIsolated {
            guard let camera = device as? ICCameraDevice,
                  camera.transportType == ICDeviceTransport.transportTypeUSB.rawValue,
                  camera.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue),
                  !cameras.contains(where: { $0 === camera }) else { return }
            cameras.append(camera)
            if !moreComing { publish() }
        }
    }

    nonisolated func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        MainActor.assumeIsolated {
            guard let camera = device as? ICCameraDevice, cameras.contains(where: { $0 === camera }) else { return }
            cameras.removeAll { $0 === camera }
            onRemove(camera)
            publish()
        }
    }

    nonisolated func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        MainActor.assumeIsolated { publish() }
    }
}
