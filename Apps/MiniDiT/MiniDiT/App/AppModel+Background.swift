import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
import ServiceManagement
import UserNotifications

/// 插入相机存储卡时怎么办。
enum CardInsertAction: String, CaseIterable, Identifiable {
    case open, auto, notify, ignore
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: "打开导入窗口"
        case .auto: "自动导入新照片"
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
        if open {
            NSApp.setActivationPolicy(.regular)
            // 用得到通知时，窗口出来以后问一次权限（程序启动完之前问，系统会直接拒绝且不再询问）。
            if notifyCameraOnline || cardInsertAction == .notify { Notifier.shared.requestPermission() }
        }
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
        case .auto:
            // 自动导入：什么都没开着时在后台打开，倒计时后导入。已经开着别的来源、正在导入时，按「打开导入窗口」处理。
            if phase == .searching || phase == .connecting { cancelConnect() }
            if library == nil, progress == nil, phase == .idle {
                openCard(url)
                autoImportWhenReady(name: name, isCard: true)
            } else {
                openInsertedCard(url)
            }
        }
    }

    // MARK: 自动导入

    struct AutoCountdown: Equatable {
        var name: String
        var count: Int
        var deadline: Date
    }

    /// 等来源读完，有新照片就倒计时 10 秒（可取消），然后按当前设置导入。
    /// 需要输入账号、核对指纹时不自动处理，改为打开窗口。
    func autoImportWhenReady(name: String, isCard: Bool) {
        autoTask?.cancel()
        autoTask = Task {
            let start = Date()
            while phase != .ready, Date().timeIntervalSince(start) < 90 {
                if credentialRequest != nil || fingerprintRequest != nil {
                    log.add("自动导入：“\(name)”需要确认身份，改为打开窗口")
                    showMainWindow()
                    return
                }
                if phase == .idle && Date().timeIntervalSince(start) > 2 { log.add("自动导入：“\(name)”没有连上"); return }
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            guard phase == .ready, progress == nil else { return }
            // 读完以后用来源的名字（存储卡读出的机型、改过的名字），和导入完成的通知一致。
            let name = sources.first?.name ?? name
            let fresh = allShots.map(\.id).filter { !isImported(shot: $0) && !importFiles(of: shots[$0]!).isEmpty }
            guard !fresh.isEmpty else {
                log.add("自动导入：“\(name)”没有新照片")
                if isCard {
                    Notifier.shared.post(id: "auto", title: "“\(name)”上没有新照片", body: "照片均已导入过。", info: [:])
                }
                return
            }
            autoCountdown = AutoCountdown(name: name, count: fresh.count, deadline: Date().addingTimeInterval(10))
            log.add("自动导入：“\(name)”有 \(fresh.count) 张新照片，10 秒后开始")
            Notifier.shared.post(id: "auto", title: "即将从“\(name)”导入 \(fresh.count) 张新照片",
                                 body: "10 秒后开始。点按以取消。", info: ["autoCancel": "1"])
            try? await Task.sleep(for: .seconds(10))
            let cancelled = Task.isCancelled || autoCountdown == nil
            autoCountdown = nil
            guard !cancelled else { log.add("自动导入：已取消"); return }
            runAutoImport(name: name, shots: fresh)
        }
    }

    /// 取消倒计时（点通知、菜单栏面板上的「取消」）。
    func cancelAutoImport() {
        guard autoCountdown != nil else { return }
        autoCountdown = nil
        autoTask?.cancel()
        Notifier.shared.post(id: "auto", title: "已取消自动导入", body: "可在 MiniDiT 中手动选择并导入。", info: [:])
    }

    /// 选中新照片，跳过所有需要回答的提示：缺备份盘、空间不够、LrC 插件有问题时不导，发通知说明。
    private func runAutoImport(name: String, shots fresh: [UInt32]) {
        guard progress == nil, phase == .ready else { return }
        func stop(_ why: String) {
            log.add("自动导入：未开始，\(why)")
            Notifier.shared.post(id: "auto", title: "未能自动导入“\(name)”", body: why + "。点按以打开 MiniDiT。", info: [:])
        }
        grid.clear()
        grid.set(fresh, selected: true)
        if backupEnabled, !backupAvailable { stop(backupFolder == nil ? "尚未设置备份位置" : "备份磁盘未连接"); return }
        if let p = spaceShortage() { stop(p.isBackup ? "备份磁盘空间不足" : "存储空间不足"); return }
        autoRunning = true
        switch captureOneMode {
        case .lightroom:
            guard LightroomBridge.status().canImport else { autoRunning = false; stop("Lightroom Classic 插件需要安装或更新"); return }
            startImport(jobs: autoJobs(), grouping: sessionGrouping)
        case .newSession:
            startImport(jobs: autoJobs(), grouping: sessionGrouping)
        default:
            startImport(session: nil)
        }
        if progress == nil { autoRunning = false; stop("没有可导入的文件") }
        else { log.add("自动导入：开始导入“\(name)”的 \(fresh.count) 张") }
    }

    /// 自动导入的会话 / 收藏夹：按当前的分组方式和命名模板起名，不填事件名。
    /// 同名的 C1 会话已经存在（比如当天第二次自动导入）就加进那个会话。
    private func autoJobs() -> [ImportJob] {
        let existing = captureOneMode == .newSession ? CaptureOneBridge.sessions(in: sessionsFolder) : []
        return importGroups(sessionGrouping).map { g in
            let n = Self.sessionName(for: g, event: nil)
            if let s = existing.first(where: { $0.deletingLastPathComponent().lastPathComponent == n }) {
                return ImportJob(key: g.id, files: g.files, session: .existing(s), event: nil, scene: g.scene)
            }
            return ImportJob(key: g.id, files: g.files, session: .new(n), event: nil, scene: g.scene)
        }
    }

    /// 自动导入结束：发通知说结果。
    func autoImportFinished() {
        autoRunning = false
        let name = sources.first?.name ?? "相机"
        if let i = interrupted {
            Notifier.shared.post(id: "auto", title: "“\(name)”的自动导入已中断",
                                 body: "已完成 \(i.done) / \(i.total) 个文件。重新连接后可继续导入。", info: [:])
        } else if let r = lastResult {
            var body = "已导入 \(r.files) 个文件"
            if let b = r.backedUp { body += b == r.files ? "，均已备份" : "，备份 \(b) 个" }
            if r.failed > 0 { body += "，\(r.failed) 个失败" }
            if let s = r.session { body += "。会话：\(s)" }
            Notifier.shared.post(id: "auto", title: r.failed > 0 ? "“\(name)”的自动导入有文件失败" : "“\(name)”自动导入完成",
                                 body: body + "。", info: [:])
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
        // 自动导入：什么都没开着时，在后台连上、读完，倒计时后导入。已经开着别的来源就只发通知。
        if autoImportCamera, library == nil, progress == nil, phase == .idle {
            connect(known: k)
            autoImportWhenReady(name: k.name, isCard: false)
            return
        }
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
        if let a = autoCountdown { return "即将自动导入 \(a.count) 张新照片" }
        if let p = progress { return (autoRunning ? "正在自动导入 " : "正在导入 ") + "\(p.done + p.skipped) / \(p.total) 个文件" }
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { ok, error in
            self.log("通知权限：\(ok ? "已允许" : "未允许")\(error.map { "，\($0.localizedDescription)" } ?? "")")
            self.refreshPermission()
        }
    }

    /// 查一下系统设置里现在允不允许（用户可能在系统设置里改过）。
    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { st in
            let ok = st.authorizationStatus == .authorized || st.authorizationStatus == .provisional
            Task { @MainActor in self.model?.notificationsAllowed = ok }
        }
    }

    /// 打开「系统设置 › 通知」。
    static func openSystemSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(u) }
    }

    private func log(_ s: String) {
        Task { @MainActor in self.model?.log.add(s) }
    }

    func post(id: String, title: String, body: String, info: [String: String]) {
        requestPermission()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = info
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil)) { error in
            self.log("发送通知「\(title)」" + (error.map { "失败：\($0.localizedDescription)" } ?? ""))
        }
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
        let autoCancel = info["autoCancel"] != nil
        Task { @MainActor in
            if autoCancel, self.model?.autoCountdown != nil { self.model?.cancelAutoImport() }
            else if let card { self.model?.openInsertedCard(URL(filePath: card, directoryHint: .isDirectory)) }
            else if let camera { self.model?.connectNotified(camera) }
            else { self.model?.showMainWindow() }
        }
        completionHandler()
    }
}
