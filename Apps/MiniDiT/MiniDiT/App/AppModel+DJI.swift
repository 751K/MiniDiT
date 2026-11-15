import Foundation
import SonyRemoteKit

/// 无线连接大疆 Osmo 相机（Pocket 3 等）：蓝牙找到相机并配对 → 拿到相机热点的名称和密码 →
/// Mac 加入热点 → 通过 Wi-Fi 列文件、下载。第一次连接时要在相机屏幕上点“允许”。
extension AppModel {
    /// 相机记住这台 Mac 用的标识：每次安装生成一次并保存；变了的话相机会再要求确认一次。
    static var djiIdentifier: String {
        if let s = UserDefaults.standard.string(forKey: "djiPairingIdentifier"), s.count == 32 { return s }
        let s = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(s, forKey: "djiPairingIdentifier")
        return s
    }

    func connectDJI() {
        guard phase == .idle else { return }
        connectTask = Task { await connectDJIAsync() }
    }

    private func connectDJIAsync() async {
        phase = .connecting
        connectingHost = "大疆相机"
        defer { connectingHost = nil }
        errorMessage = nil
        notice = nil
        let note: @Sendable (String) -> Void = { s in Task { @MainActor in self.log.add(s) } }
        let ble = DJIBluetooth(log: note)
        var joined: DJIWiFi.Joined?
        do {
            status = "正在通过蓝牙查找大疆相机…"
            let found = try await ble.scan()
            log.add("大疆蓝牙：找到 \(found.map { "\($0.name)（\($0.model)，\($0.rssi) dBm）" })")
            guard let cam = found.first(where: { $0.model.contains("Pocket") }) ?? found.first else { throw DJIBluetooth.Failure.notFound }
            try Task.checkCancellation()
            status = "正在连接 \(cam.model)…"
            try await ble.connect(cam)
            status = "正在配对 \(cam.model)…"
            let creds = try await ble.pair(identifier: Self.djiIdentifier) {
                Task { @MainActor in self.status = "请在相机屏幕上点“允许”，以连接这台 Mac。" }
            }
            try Task.checkCancellation()
            status = "正在加入相机的 Wi-Fi“\(creds.ssid)”…"
            joined = try await DJIWiFi.join(ssid: creds.ssid, password: creds.password,
                                            nudge: { await ble.nudgeWiFi(creds) }, log: note)
            status = "正在读取 \(cam.model) 的内容…"
            let leave = joined!
            let lib = try await DJICameraLibrary.open(model: cam.model, ssid: creds.ssid, identifier: Self.djiIdentifier,
                                                      bluetooth: ble, log: note, onClose: { await DJIWiFi.leave(leave) })
            if Task.isCancelled { await lib.close(); throw CancellationError() }
            primaryConnectionID = UUID()
            sessionCameraProfiles[Self.primarySource] = nil
            usesRemoteTransfer = false
            sourceKind = .camera
            deviceInfo = await lib.deviceInfo
            cameraID = deviceInfo?.cameraID
            lastCamera = nil
            attach(lib, name: cam.model, host: nil)
            log.add("大疆相机：\(cam.model)，热点 \(creds.ssid)")
            await loadAll()
            refreshCaptureOne()
        } catch is CancellationError {
            ble.disconnect()
            if let joined { await DJIWiFi.leave(joined) }
            log.add("已取消连接大疆相机")
            endCancelled()
            return
        } catch {
            ble.disconnect()
            if let joined { await DJIWiFi.leave(joined) }
            log.add("连接大疆相机失败：\(error.localizedDescription) ｜ \(String(reflecting: error))")
            errorMessage = "连接大疆相机失败：\(error.localizedDescription)"
            phase = .idle
        }
        status = ""
    }
}
