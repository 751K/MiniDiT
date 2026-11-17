import Foundation
@preconcurrency import ImageCaptureCore
import SonyRemoteKit

/// USB 有线连接：ImageCaptureCore 发现相机，PTP 命令透传。
/// 导入：相机报标准存储卡（MTP / PTP 模式）时按标准 PTP 浏览，索尼「电脑遥控」模式走远程传输或内容传输。
/// 联机拍摄（索尼）：和 Wi-Fi 同一套 SonyCamera，只是换成 USB 传输。
extension AppModel {
    func startUSBWatch() {
        let browser = USBCameraBrowser()
        browser.onChange = { [weak self] cams in self?.usbCameras = cams }
        browser.onRemove = { [weak self] camera in
            guard let self, let active = self.activeUSBDevice, active.camera === camera else { return }
            self.log.add("USB 相机已断开：\(camera.name ?? "")")
            active.deviceRemoved()
            self.activeUSBDevice = nil
        }
        browser.start()
        usbBrowser = browser
    }

    /// 打开一个新的 USB 传输（每次重开系统会话）。
    private func openUSBTransport(_ cam: USBCamera) async throws -> PTPUSBClient {
        let device = try await ICPassthroughDevice.open(cam.device.camera)
        activeUSBDevice = device
        return PTPUSBClient(device: device)
    }

    func connectUSB(_ cam: USBCamera) {
        guard phase == .idle || phase == .ready else { return }
        if library != nil || !extraSources.isEmpty { disconnect() }
        connectTask?.cancel()
        connectTask = Task { await connectUSBAsync(cam) }
    }

    private func connectUSBAsync(_ cam: USBCamera) async {
        phase = .connecting
        connectingHost = cam.name
        defer { connectingHost = nil }
        errorMessage = nil
        notice = nil
        let note: @Sendable (String) -> Void = { s in Task { @MainActor in self.log.add(s) } }
        let step: @Sendable (String) -> Void = { s in Task { @MainActor in self.status = s; self.log.add(s) } }
        do {
            let ref = cam.device
            let lib = try await USBCameraOpener.openLibrary(name: cam.name, makeTransport: { @MainActor in
                try await self.openUSBTransport(USBCamera(id: cam.id, name: cam.name, device: ref))
            }, progress: step, log: note)
            if Task.isCancelled { await lib.close(); throw CancellationError() }
            primaryConnectionID = UUID()
            sessionCameraProfiles[Self.primarySource] = nil
            usesRemoteTransfer = lib is SonyRemoteTransferLibrary
            sourceKind = .camera
            deviceInfo = await lib.deviceInfo
            cameraID = deviceInfo?.cameraID
            lastCamera = nil
            lastUSBCamera = cam
            attach(lib, name: (deviceInfo?.model).flatMap { $0.isEmpty ? nil : $0 } ?? cam.name, host: nil)
            log.add("USB 相机：\(cam.name)")
            await loadAll()
            refreshCaptureOne()
        } catch is CancellationError {
            log.add("已取消连接 USB 相机")
            endCancelled()
            return
        } catch {
            log.add("连接 USB 相机失败：\(error.localizedDescription) ｜ \(String(reflecting: error))")
            errorMessage = "连接 USB 相机失败：\(error.localizedDescription)"
            phase = .idle
        }
        status = ""
    }

    /// 通过 USB 联机拍摄（索尼，相机的 USB 连接方式设为「PC 遥控」）。
    func startTether(usb cam: USBCamera) {
        guard progress == nil else {
            errorMessage = "请等待当前导入完成后再开始联机拍摄。"
            return
        }
        let wasOpen = library != nil || !extraSources.isEmpty
        if wasOpen || phase != .idle { disconnect() }
        connectTask?.cancel()
        lastTetherCamera = nil
        connectTask = Task {
            await beginTether(label: cam.name, knownName: nil, settle: wasOpen) { step in
                let transport = try await self.openUSBTransport(cam)
                return try await SonyCamera.connect(transport: transport, progress: step)
            }
        }
    }
}
