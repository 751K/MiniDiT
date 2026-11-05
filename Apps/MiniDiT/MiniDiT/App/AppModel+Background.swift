import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
import ServiceManagement
import UserNotifications

/// 插入相机存储卡时怎么办。
enum CardInsertAction: String, CaseIterable, Identifiable {
    case open, notify, ignore
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: "打开导入窗口"
        case .notify: "仅发送通知"
        case .ignore: "不处理"
        }
    }
}

/// v0.6 后台：菜单栏常驻、登录时打开、插卡自动打开、相机上线通知。
extension AppModel {
    /// 把主窗口打开并放到最前。
    func showMainWindow() {
        windowRequest += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 主窗口开 / 关：菜单栏模式下，窗口关了就不占程序坞。
    func mainWindowChanged(open: Bool) {
        mainWindowOpen = open
        if open { NSApp.setActivationPolicy(.regular) }
        else if keepInMenuBar { NSApp.setActivationPolicy(.accessory) }
    }

    func applyLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log.add(launchAtLogin ? "已设为登录时打开" : "已取消登录时打开")
        } catch {
            log.add("设置登录项失败：\(error.localizedDescription)")
            errorMessage = "无法\(launchAtLogin ? "设置" : "取消")登录时打开：\(error.localizedDescription)"
        }
    }

    // MARK: 插卡

    /// 新挂载的卷：是相机存储卡（有 DCIM 等）才处理。
    func volumeMounted(_ url: URL) {
        guard LocalCardLibrary.looksLikeCard(url) else { return }
        let name = url.lastPathComponent
        log.add("插入存储卡 \(url.path)，设置为「\(cardInsertAction.title)」")
        switch cardInsertAction {
        case .ignore:
            return
        case .notify:
            Notifier.shared.post(id: "card:" + url.path, title: "已插入存储卡“\(name)”", body: "点按以打开并导入。",
                                 info: ["card": url.path])
        case .open:
            openInsertedCard(url)
        }
    }

    /// 打开刚插入的卡：什么都没开就当主来源；已经在看别的来源，就同时打开；正在导入时不打扰，只发通知。
    func openInsertedCard(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if progress != nil {
            Notifier.shared.post(id: "card:" + url.path, title: "已插入存储卡“\(url.lastPathComponent)”",
                                 body: "当前导入完成后，可在来源列表中打开。", info: [:])
            return
        }
        if phase == .searching || phase == .connecting { cancelConnect() }
        if library == nil {
            if phase == .idle { openCard(url) }
        } else {
            addCard(url)
        }
        showMainWindow()
    }

    // MARK: 相机上线

    /// 每隔一会儿试一下连过的相机的地址（只是敲一下端口，不建立会话），从不在线变成在线就发通知。
    /// 已经打开的、正在连的相机不试。
    func startCameraWatch() {
        cameraWatchTask?.cancel()
        watchOnline = [:]
        watchMisses = [:]
        guard notifyCameraOnline else { return }
        cameraWatchTask = Task {
            while !Task.isCancelled {
                await watchCamerasOnce()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func watchCamerasOnce() async {
        // 同一个地址可能有两条记录（开 / 不开访问身份验证各连过一次），按地址只试一次。
        var hosts: [String] = []
        for k in knownCameras where !hosts.contains(k.host) { hosts.append(k.host) }
        for host in hosts.prefix(8) {
            if Task.isCancelled { return }
            if openHosts.contains(host) || connectingHost == host || phase == .searching { continue }
            let cam = await probe(host: host)
            let k = cam.flatMap { c in knownCameras.first { $0.host == host && $0.fingerprint == c.fingerprint } }
            if let k {
                watchMisses[host] = 0
                if watchOnline[host] == nil {
                    watchOnline[host] = k.fingerprint
                    // 刚好在这时自己连上了（启动时的自动连接等），就不打扰。
                    if !openHosts.contains(host), connectingHost != host { cameraCameOnline(k) }
                }
            } else if watchOnline[host] != nil {
                // Wi-Fi 偶尔丢一下：连续两次不在才算离线，下次上线再通知。
                watchMisses[host, default: 0] += 1
                if watchMisses[host, default: 0] >= 2 {
                    watchOnline[host] = nil
                    log.add("后台：\(host) 已离线")
                }
            }
        }
    }

    private func cameraCameOnline(_ k: KnownCamera) {
        log.add("后台：\(k.name)（\(k.host)）已上线")
        Notifier.shared.post(id: "camera:" + k.fingerprint, title: "“\(k.name)”已上线",
                             body: library == nil ? "点按以连接并导入。" : "点按以同时连接。",
                             info: ["camera": k.fingerprint])
    }

    /// 点了「相机已上线」的通知：什么都没开就连它；已经开着别的来源就同时连。
    func connectNotified(_ fingerprint: String) {
        showMainWindow()
        guard let k = knownCameras.first(where: { $0.fingerprint == fingerprint }) else { return }
        if openHosts.contains(k.host) { return }
        if progress != nil { errorMessage = "正在导入，完成后再连接“\(k.name)”。"; return }
        if phase == .searching || phase == .connecting { cancelConnect() }
        if library == nil {
            if phase == .idle { connect(known: k) }
        } else {
            addCamera(known: k)
        }
    }

    // MARK: 菜单栏面板

    /// 菜单栏面板上一行的状态。
    var menuStatus: String {
        if let p = progress { return "正在导入 \(p.done + p.skipped) / \(p.total) 个文件" }
        if interrupted != nil { return "导入已中断" }
        switch phase {
        case .searching: return "正在查找相机…"
        case .connecting: return "正在连接…"
        case .loading: return "正在读取…"
        case .ready: return newShotCount > 0 ? "\(newShotCount.formatted()) 张新照片" : "无新照片"
        case .idle: return library == nil ? "未连接" : ""
        }
    }

    /// 插着但还没打开的卡。
    var unopenedCards: [URL] {
        let open = Set(([cardRoot] + extraSources.map(\.root)).compactMap { $0?.standardizedFileURL })
        return cards.filter { !open.contains($0.standardizedFileURL) }
    }
}

/// 系统通知：发通知、点通知后打开对应的卡。
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()
    @MainActor weak var model: AppModel?
    private var asked = false

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestPermission() {
        guard !asked else { return }
        asked = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: String, title: String, body: String, info: [String: String]) {
        requestPermission()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // 程序在前台时也显示横幅。
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let card = info["card"] as? String, camera = info["camera"] as? String
        Task { @MainActor in
            if let card { self.model?.openInsertedCard(URL(filePath: card, directoryHint: .isDirectory)) }
            else if let camera { self.model?.connectNotified(camera) }
            else { self.model?.showMainWindow() }
        }
        completionHandler()
    }
}
