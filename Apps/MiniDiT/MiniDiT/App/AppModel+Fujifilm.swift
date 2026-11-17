import Foundation
import SonyRemoteKit

/// 无线连接富士 X / GFX 相机（试验性）：相机上打开「无线通信」做热点，Mac 加入它的 Wi-Fi 后，
/// 连 192.168.0.1:55740 列文件、下载。第一次连接时要在相机上按 OK。
extension AppModel {
    func connectFujifilm() {
        guard phase == .idle else { return }
        connectTask = Task { await connectFujifilmAsync() }
    }

    private func connectFujifilmAsync() async {
        phase = .connecting
        connectingHost = "富士相机"
        defer { connectingHost = nil }
        errorMessage = nil
        notice = nil
        // 相机热点的地址固定是 192.168.0.1；调试时可以用 fujiHost 改。
        let host = UserDefaults.standard.string(forKey: "fujiHost").flatMap { $0.isEmpty ? nil : $0 } ?? FujiWiFi.defaultHost
        let note: @Sendable (String) -> Void = { s in Task { @MainActor in self.log.add(s) } }
        let step: @Sendable (String) -> Void = { s in Task { @MainActor in self.status = s; self.log.add(s) } }
        do {
            let lib = try await FujiCameraLibrary.open(host: host, identity: HostIdentityStore.identity, progress: step, log: note)
            if Task.isCancelled { await lib.close(); throw CancellationError() }
            for n in await lib.listingNotes { log.add(n) }
            let name = await lib.deviceInfo?.model ?? "富士相机"
            primaryConnectionID = UUID()
            sessionCameraProfiles[Self.primarySource] = nil
            usesRemoteTransfer = false
            sourceKind = .camera
            deviceInfo = await lib.deviceInfo
            cameraID = deviceInfo?.cameraID
            lastCamera = nil
            attach(lib, name: name.isEmpty ? "富士相机" : name, host: nil)   // 和大疆一样不记地址：掉线后不走索尼的自动重连
            await loadAll()
            refreshCaptureOne()
        } catch is CancellationError {
            log.add("已取消连接富士相机")
            endCancelled()
            return
        } catch {
            log.add("连接富士相机失败：\(error.localizedDescription) ｜ \(String(reflecting: error))")
            errorMessage = "连接富士相机失败：\(error.localizedDescription)"
                + (error is FujiWiFi.Failure ? "" : "请确认相机已打开“无线通信”，并且 Mac 已加入相机的 Wi-Fi。")
            phase = .idle
        }
        status = ""
    }
}
