import AppKit
import Foundation
import MiniDiTCore
import Observation
import SonyRemoteKit

/// 一天的拍摄（按相机里的拍摄日期分组，不受 Mac 时区影响）。
struct ShootingDay: Identifiable, Hashable {
    let id: String          // yyyyMMdd，没有日期的是 "unknown"
    let title: String
    var shots: [UInt32]
    var importedCount: Int
    var newCount: Int { shots.count - importedCount }
}

enum CaptureOneMode: String, CaseIterable, Identifiable {
    case newSession, c1Settings, inPlace, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newSession: "新建 C1 会话（日期 + 内容），直接存进 Capture"
        case .off: "不导入，只下载到文件夹"
        case .c1Settings: "按 Capture One 的导入设置导入"
        case .inPlace: "就地添加（不再复制，仅目录）"
        }
    }
}

/// 侧栏日期前的勾选框状态。
enum CheckState { case off, mixed, on }

@MainActor @Observable
final class AppModel {
    // MARK: 连接

    enum Phase: Equatable { case idle, searching, connecting, loading, ready }
    enum SourceKind: Equatable { case camera, card }

    struct CredentialRequest: Identifiable {
        let id = UUID()
        let host: String
        let message: String?
        let prefillUser: String?
    }

    struct FingerprintRequest: Identifiable {
        let id = UUID()
        let host: String
        let key: SSHHostKeyInfo
    }

    private(set) var phase: Phase = .idle
    private(set) var status = ""
    private(set) var found: [FoundCamera] = []
    private(set) var searched = false
    private(set) var connectedName: String?
    private(set) var connectedHost: String?
    private(set) var sourceKind: SourceKind = .camera
    private(set) var usesRemoteTransfer = false
    /// 正在连接的相机地址（来源页的卡片上显示转圈）。
    private(set) var connectingHost: String?
    /// 搜索没结果，而且看起来是没有本地网络权限。
    private(set) var networkBlocked = false
    /// 首页上显示的一句话（比如「已推出 TESTCARD，可以拔卡了」）。
    private(set) var notice: String?
    /// 相机掉线了，正在自动重连；浏览页的内容和选择都保留。
    private(set) var offline = false
    private var lastCamera: FoundCamera?
    private var reconnectTask: Task<Void, Never>?
    private var lostDuringImport = false
    /// 机身 ID（型号#序列号），导入记录用来区分不同机身。读卡器没有。
    private(set) var cameraID: String?
    private(set) var deviceInfo: CameraDeviceInfo?
    var errorMessage: String?
    var credentialRequest: CredentialRequest?
    var fingerprintRequest: FingerprintRequest?
    private var credentialContinuation: CheckedContinuation<SSHCredentials?, Never>?
    private var fingerprintContinuation: CheckedContinuation<Bool, Never>?
    private var library: (any CameraLibrary)?
    private var cardRoot: URL?
    private var connectTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private let log = AppLog.shared

    var knownCameras: [KnownCamera] = KnownCamera.load()
    /// 插着的存储卡（读卡器 / 相机 USB 大容量存储）。
    private(set) var cards: [URL] = []

    var autoConnect: Bool = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }

    // MARK: 内容

    private(set) var items: [UInt32: CameraContentItem] = [:]
    private var allShots: [Shot] = []                 // 新的在前
    private(set) var shots: [UInt32: Shot] = [:]
    private var shotOfFile: [UInt32: UInt32] = [:]
    private(set) var slots: [UInt32] = []
    var slotFilter: UInt32? = nil { didSet { rebuild() } }        // nil = 全部卡槽
    var showPhotos = true { didSet { rebuild() } }
    var showRaw = true { didSet { rebuild() } }
    var showVideo = false { didSet { rebuild() } }
    var onlyNew = UserDefaults.standard.object(forKey: "onlyNew") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onlyNew, forKey: "onlyNew"); rebuild() }
    }
    private(set) var days: [ShootingDay] = []
    /// 侧栏里点中的日期（右边显示哪几天）。
    var shownDays: Set<String> = [] { didSet { updateGridOrder() } }
    /// 选中的拍摄（Shot.id）。
    var grid = GridSelection<UInt32>()
    private(set) var thumbnails: [UInt32: NSImage] = [:]
    private var thumbOrder: [UInt32] = []
    private var pendingThumbs: [UInt32] = []
    private var thumbLoaderRunning = false
    var thumbSize: Double = UserDefaults.standard.object(forKey: "thumbSize") as? Double ?? 170 {
        didSet { UserDefaults.standard.set(thumbSize, forKey: "thumbSize") }
    }

    // MARK: 预览

    var previewShot: UInt32?
    private(set) var previewImage: NSImage?
    private(set) var previewLoaded = false
    private var previewTask: Task<Void, Never>?

    // MARK: 导入

    struct ImportProgress {
        var total: Int
        var done = 0
        var skipped = 0
        var reused = 0
        var failed: [String] = []
        var bytesDone: UInt64 = 0
        var bytesTotal: UInt64
        var current = ""
        var fraction: Double { bytesTotal == 0 ? 0 : min(1, Double(bytesDone) / Double(bytesTotal)) }
    }

    struct ImportResult {
        var files: Int
        var reused: Int
        var failed: Int
        var session: String?
        var c1Failed: Bool
        var cancelled: Bool
    }
    /// 导入中断（相机掉线）：没导完的仍然选中，重连后可以继续。
    struct Interrupted {
        var done: Int
        var total: Int
        var session: SessionChoice?
    }

    private(set) var progress: ImportProgress?
    private(set) var lastResult: ImportResult?
    private(set) var interrupted: Interrupted?
    private(set) var lastSummary: String?
    private(set) var lastBatch: [URL] = []
    private var importTask: Task<Void, Never>?

    var destination: URL {
        get { UserDefaults.standard.url(forKey: "destination") ?? Self.defaultDestination }
        set { UserDefaults.standard.set(newValue, forKey: "destination"); destinationVersion += 1 }
    }
    private(set) var destinationVersion = 0
    static var defaultDestination: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "MiniDiT", directoryHint: .isDirectory)
    }

    var captureOneMode: CaptureOneMode = CaptureOneMode(rawValue: UserDefaults.standard.string(forKey: "c1Mode") ?? "") ?? .newSession {
        didSet { UserDefaults.standard.set(captureOneMode.rawValue, forKey: "c1Mode") }
    }
    var pairPolicy: PairPolicy = PairPolicy(rawValue: UserDefaults.standard.string(forKey: "pairPolicy") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(pairPolicy.rawValue, forKey: "pairPolicy") }
    }
    private(set) var captureOneDocument: CaptureOneBridge.DocumentInfo?

    /// 新建会话放在哪个文件夹。
    var sessionsFolder: URL {
        get {
            if let u = UserDefaults.standard.url(forKey: "sessionsFolder") { return u }
            // 没设置过：跟 C1 当前打开的会话放在一起（会话文件夹的上一级）。
            if let d = captureOneDocument, d.isSession, let f = d.folder { return f.deletingLastPathComponent() }
            return Self.defaultSessionsFolder
        }
        set { UserDefaults.standard.set(newValue, forKey: "sessionsFolder"); destinationVersion += 1 }
    }
    static var defaultSessionsFolder: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "Capture One 会话", directoryHint: .isDirectory)
    }

    /// 导入前要用户填会话名。
    enum SessionChoice { case new(String), existing(URL), resolved(captureDir: URL, name: String) }
    struct SessionRequest: Identifiable {
        let id = UUID()
        let suggestedName: String
        let existing: [URL]
    }
    var sessionRequest: SessionRequest?

    /// 最近用过的会话内容名（「3.15-公园」里的「公园」），新的在前。
    private(set) var recentContents: [String] = UserDefaults.standard.stringArray(forKey: "recentContents") ?? []

    init() {
        refreshCards()
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
                MainActor.assumeIsolated { self?.volumesChanged(unmounted: name == NSWorkspace.didUnmountNotification ? path : nil) }
            }
        }
        if autoConnect, !knownCameras.isEmpty {
            connectTask = Task { await autoConnectLast() }
        }
    }

    /// 会话名默认是选中内容里最早一天的日期，格式「月.日-」（如 3.15-公园），用户在后面补内容。
    func suggestedSessionName() -> String {
        let keys = selectedFiles().map(Self.dayKey).filter { $0 != "unknown" }.sorted()
        guard let first = keys.first, let m = Int(first.dropFirst(4).prefix(2)), let d = Int(first.suffix(2)) else { return "" }
        return "\(m).\(d)-"
    }

    private func rememberContent(of sessionName: String) {
        guard let dash = sessionName.firstIndex(of: "-") else { return }
        let content = sessionName[sessionName.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        recentContents = [content] + recentContents.filter { $0 != content }
        recentContents = Array(recentContents.prefix(12))
        UserDefaults.standard.set(recentContents, forKey: "recentContents")
    }

    // MARK: 搜索

    func search() {
        guard phase == .idle else { return }
        phase = .searching
        errorMessage = nil
        notice = nil
        log.add("搜索相机：\(CameraFinder.networkSummary())")
        let known = knownCameras
        connectTask = Task {
            let result = await CameraFinder.search(known: known) { s in
                Task { @MainActor in self.status = s }
            }
            found = result
            searched = true
            networkBlocked = result.isEmpty ? await CameraFinder.localNetworkBlocked() : false
            if networkBlocked { log.add("搜索：看起来没有本地网络权限") }
            log.add("搜索结果：\(result.map { "\($0.host)\($0.knownName.map { "（\($0)）" } ?? "")" })")
            if phase == .searching { phase = .idle }
            status = ""
        }
    }

    /// 启动时连上次的相机：先试上次的地址，不行再搜一遍子网找认识的相机。
    private func autoConnectLast() async {
        guard let last = knownCameras.first else { return }
        phase = .searching
        status = "正在找上次的相机「\(last.name)」…"
        log.add("自动连接：先试 \(last.host)")
        if let cam = await probe(host: last.host), cam.fingerprint == last.fingerprint {
            await connect(FoundCamera(host: cam.host, kind: cam.kind, knownName: last.name))
            return
        }
        if Task.isCancelled { phase = .idle; status = ""; return }
        status = "上次的地址连不上，正在搜索…"
        let result = await CameraFinder.search(known: knownCameras) { s in Task { @MainActor in self.status = s } }
        found = result
        searched = true
        if Task.isCancelled { phase = .idle; status = ""; return }
        if let cam = result.first(where: { $0.knownName != nil }) {
            await connect(cam)
        } else {
            log.add("自动连接：没找到连过的相机")
            phase = .idle
            status = ""
        }
    }

    /// 检查某个地址上有没有相机（先 PTP/IP 直连，再 SSH）。
    private func probe(host: String) async -> FoundCamera? {
        if await CameraDiscovery.probe(host: host, port: PTPIPClient.defaultPort, timeout: 1.5) {
            return FoundCamera(host: host, kind: .direct)
        }
        if let (key, _) = try? await CameraSSHTunnel.probe(host: host, timeout: 4) {
            return FoundCamera(host: host, kind: .ssh(fingerprint: key.sha256Base64))
        }
        return nil
    }

    func connect(host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        connectTask = Task {
            phase = .connecting
            status = "正在检查 \(h)…"
            if let cam = await probe(host: h) {
                let name = knownCameras.first { $0.fingerprint == cam.fingerprint }?.name
                await connect(FoundCamera(host: cam.host, kind: cam.kind, knownName: name))
                return
            }
            phase = .idle
            errorMessage = "\(h) 上没有找到相机（22 和 15740 端口都连不上）。请确认相机开着、打开了「遥控拍摄」，并且和这台 Mac 在同一个网络。"
        }
    }

    /// 当前连着的相机的指纹（读卡器为 nil）。
    var currentFingerprint: String? { sourceKind == .camera ? lastCamera?.fingerprint : nil }

    /// 从浏览页直接换到另一台连过的相机 / 另一张卡。
    /// 先确认目标相机在线（指纹一致）再断开当前来源，免得切换失败后选择也丢了。
    private(set) var switchingTo: String?

    func switchTo(known k: KnownCamera) {
        guard progress == nil, switchingTo == nil else { return }
        switchingTo = k.fingerprint
        Task {
            defer { switchingTo = nil }
            guard let cam = await probe(host: k.host), cam.fingerprint == k.fingerprint else {
                errorMessage = "「\(k.name)」不在线（上次的地址是 \(k.host)），没有切换。如果相机换了地址，可以用「文件 › 切换来源…」重新搜索。"
                return
            }
            let target = FoundCamera(host: cam.host, kind: cam.kind, knownName: k.name)
            disconnect()
            connectTask = Task { await self.connect(target) }
        }
    }

    func switchTo(card url: URL) {
        guard progress == nil else { return }
        disconnect()
        openCard(url)
    }

    /// 连过的相机：只认指纹相同的设备（同一个地址上可能换成了别的机器）。
    func connect(known k: KnownCamera) {
        connectTask = Task {
            phase = .connecting
            connectingHost = k.host
            status = "正在找「\(k.name)」…"
            if let cam = await probe(host: k.host), cam.fingerprint == k.fingerprint {
                await connect(FoundCamera(host: cam.host, kind: cam.kind, knownName: k.name))
                return
            }
            connectingHost = nil
            phase = .idle
            status = ""
            errorMessage = "「\(k.name)」不在线（上次的地址是 \(k.host)）。请确认相机开着并打开了遥控拍摄；如果相机换了地址，点「搜索相机」。"
        }
    }

    func connect(_ cam: FoundCamera) {
        connectTask = Task { await connect(cam) }
    }

    private func connect(_ cam: FoundCamera) async {
        phase = .connecting
        connectingHost = cam.host
        defer { connectingHost = nil }
        errorMessage = nil
        notice = nil
        log.add("连接 \(cam.host)")
        do {
            let lib = try await openLibrary(cam)
            sourceKind = .camera
            deviceInfo = await lib.deviceInfo
            cameraID = deviceInfo?.cameraID
            let modelName = deviceInfo.map(\.displayName) ?? ""
            // 用户起过的名字优先；名字还是 IP（以前没读到型号）就换成机型名。
            let known = knownCameras.first { $0.fingerprint == cam.fingerprint }
            let keepName = cam.knownName.flatMap { n in (known?.nameIsAddress ?? false) || n == cam.host ? nil : n }
            let name = keepName ?? (modelName.isEmpty ? (cam.knownName ?? cam.host) : modelName)
            attach(lib, name: name, host: cam.host)
            lastCamera = FoundCamera(host: cam.host, kind: cam.kind, knownName: name)
            KnownCamera.remember(KnownCamera(fingerprint: cam.fingerprint, host: cam.host, name: name, lastSeen: Date(),
                                             model: deviceInfo?.model ?? known?.model, firmware: deviceInfo?.version ?? known?.firmware))
            knownCameras = KnownCamera.load()
            if let deviceInfo { log.add("相机：\(deviceInfo.model) 固件 \(deviceInfo.version)，机身 ID \(cameraID ?? "无")") }
            await loadAll()
            refreshCaptureOne()
        } catch is CancellationError {
            log.add("已取消连接")
            phase = .idle
        } catch {
            log.add("连接失败：\(error.localizedDescription) ｜ \(String(reflecting: error))")
            errorMessage = "连接失败：\(error.localizedDescription)"
            phase = .idle
        }
        status = ""
    }

    private func attach(_ lib: any CameraLibrary, name: String, host: String?) {
        library = lib
        connectedHost = host
        connectedName = name
        let lost = lib.connectionLost
        watchTask = Task { [weak self] in
            for await _ in lost {
                self?.handleLost()
                return
            }
        }
    }

    private func openLibrary(_ cam: FoundCamera, interactive: Bool = true) async throws -> any CameraLibrary {
        let step: @Sendable (String) -> Void = { s in Task { @MainActor in self.status = s; self.log.add(s) } }
        do {
            let tunnel = try await prepareTunnel(cam, interactive: interactive)
            let lib = try await SonyRemoteTransferLibrary.open(host: cam.host, identity: HostIdentityStore.identity,
                                                               tunnel: tunnel, progress: step)
            usesRemoteTransfer = true
            log.add("使用远程传输（相机界面不锁，可读两个卡槽）")
            return lib
        } catch let e where e is SonyRemoteTransferError || e is PTPError {
            log.add("远程传输不可用（\(e.localizedDescription)），改用内容传输模式")
            try? await Task.sleep(for: .milliseconds(800))
            let tunnel = try await prepareTunnel(cam, interactive: interactive)
            usesRemoteTransfer = false
            return try await SonyContentsTransfer.openLibrary(host: cam.host, identity: HostIdentityStore.identity,
                                                              tunnel: tunnel, progress: step)
        }
    }

    private func prepareTunnel(_ cam: FoundCamera, interactive: Bool = true) async throws -> CameraSSHTunnel? {
        guard case .ssh(let fingerprint) = cam.kind else { return nil }
        var creds = CredentialStore.load(fingerprint)
        if creds == nil {
            guard interactive else { throw CancellationError() }
            creds = await askCredentials(host: cam.host, message: nil, prefillUser: nil)
        }
        while true {
            guard var current = creds else { throw CancellationError() }
            try Task.checkCancellation()
            status = "正在建立加密连接…"
            do {
                let trusted = current.trustedFingerprint
                let tunnel = try await CameraSSHTunnel.open(host: cam.host, credentials: current) { key in
                    if let trusted, trusted == key.sha256Base64 { return true }
                    guard interactive else { return false }
                    return await self.confirmFingerprint(host: cam.host, key: key)
                }
                current.trustedFingerprint = tunnel.hostKey.sha256Base64
                CredentialStore.save(current, tunnel.hostKey.sha256Base64)
                log.add("加密连接成功：\(tunnel.hostKey.keyType) \(tunnel.hostKey.sha256Base64)；\(tunnel.negotiated?.description ?? "")")
                return tunnel
            } catch SSHTunnelError.authenticationFailed(let detail) {
                guard interactive else { throw CancellationError() }
                log.add("访问身份验证失败：用户名「\(current.username)」，密码 \(current.password.count) 个字符；\(detail)")
                creds = await askCredentials(host: cam.host, message: "用户名或密码不对，请对照相机上的「访问身份验证信息」重新输入。",
                                             prefillUser: current.username)
            } catch SSHTunnelError.hostKeyRejected {
                throw CancellationError()
            }
        }
    }

    private func askCredentials(host: String, message: String?, prefillUser: String?) async -> SSHCredentials? {
        await withCheckedContinuation { cont in
            credentialContinuation = cont
            credentialRequest = CredentialRequest(host: host, message: message, prefillUser: prefillUser)
        }
    }

    func submitCredentials(_ creds: SSHCredentials?) {
        credentialRequest = nil
        credentialContinuation?.resume(returning: creds)
        credentialContinuation = nil
    }

    private func confirmFingerprint(host: String, key: SSHHostKeyInfo) async -> Bool {
        await withCheckedContinuation { cont in
            fingerprintContinuation = cont
            fingerprintRequest = FingerprintRequest(host: host, key: key)
        }
    }

    func answerFingerprint(_ ok: Bool) {
        fingerprintRequest = nil
        fingerprintContinuation?.resume(returning: ok)
        fingerprintContinuation = nil
    }

    func cancelConnect() {
        connectTask?.cancel()
        if credentialRequest != nil { submitCredentials(nil) }
        if fingerprintRequest != nil { answerFingerprint(false) }
        if phase == .searching { phase = .idle; status = "" }
    }

    func disconnect() {
        importTask?.cancel()
        connectTask?.cancel()
        watchTask?.cancel()
        reconnectTask?.cancel()
        offline = false
        lastCamera = nil
        interrupted = nil
        let lib = library
        library = nil
        Task { await lib?.close() }
        resetContent()
        phase = .idle
        log.add("已断开")
    }

    func forget(_ cam: KnownCamera) {
        KnownCamera.forget(cam.fingerprint)
        knownCameras = KnownCamera.load()
    }

    private func handleLost() {
        guard library != nil else { return }
        // 相机掉线：保留内容和选择，后台自动重连。
        if sourceKind == .camera, lastCamera != nil, !items.isEmpty {
            log.add("和相机的连接断开了，开始自动重连")
            lostDuringImport = progress != nil
            importTask?.cancel()
            library = nil
            offline = true
            startReconnect()
            return
        }
        let wasCard = sourceKind == .card
        log.add(wasCard ? "存储卡被移除了" : "和相机的连接断开了")
        importTask?.cancel()
        library = nil
        resetContent()
        phase = .idle
        errorMessage = wasCard ? "存储卡被移除了。" : "和相机的连接断开了（相机关机、离开 Wi-Fi，或者被别的设备连上了）。"
    }

    // MARK: 自动重连

    private func startReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            var attempt = 0
            while !Task.isCancelled, offline {
                attempt += 1
                if await reconnectOnce() { return }
                try? await Task.sleep(for: .seconds(attempt < 5 ? 3 : 8))
            }
        }
    }

    /// 「重新连接」按钮：马上再试一次。
    func reconnectNow() {
        guard offline else { return }
        startReconnect()
    }

    private func reconnectOnce() async -> Bool {
        guard let cam = lastCamera else { return false }
        status = "正在重新连接 \(cam.host)…"
        guard await probe(host: cam.host)?.fingerprint == cam.fingerprint else { return false }
        do {
            let lib = try await openLibrary(cam, interactive: false)
            guard offline else { await lib.close(); return true }
            let keep = selectedKeys()
            let keepDays = shownDays
            deviceInfo = await lib.deviceInfo
            cameraID = deviceInfo?.cameraID ?? cameraID
            attach(lib, name: connectedName ?? cam.host, host: cam.host)
            offline = false
            log.add("已重新连上相机")
            await loadAll(restoring: keep, days: keepDays)
            status = ""
            return true
        } catch {
            log.add("重连失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 选择的「身份」：卡槽 + 文件名 + 拍摄时间。重新列目录后句柄会变，用它把选择找回来。
    private static func stableKey(_ i: CameraContentItem) -> String { "\(i.storageID >> 16)|\(i.filename)|\(i.captureDateRaw)" }

    private func selectedKeys() -> Set<String> {
        Set(grid.selected.compactMap { shots[$0] }.flatMap(\.handles).compactMap { items[$0].map(Self.stableKey) })
    }

    private func resetContent() {
        items = [:]; allShots = []; shots = [:]; shotOfFile = [:]; slots = []; days = []
        grid = GridSelection(); shownDays = []
        thumbnails = [:]; thumbOrder = []; pendingThumbs = []
        connectedName = nil; connectedHost = nil; cameraID = nil; deviceInfo = nil; cardRoot = nil
        previewShot = nil; previewImage = nil
        progress = nil; lastResult = nil; interrupted = nil; offline = false
    }

    // MARK: 存储卡

    func refreshCards() {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        cards = vols.filter { $0.path != "/" && LocalCardLibrary.looksLikeCard($0) }
    }

    private func volumesChanged(unmounted: URL?) {
        refreshCards()
        if let unmounted, let cardRoot, unmounted.standardizedFileURL == cardRoot.standardizedFileURL,
           let lib = library as? LocalCardLibrary {
            lib.markLost()
        }
    }

    func openCard(_ url: URL) {
        guard phase == .idle else { return }
        connectTask?.cancel()
        errorMessage = nil
        notice = nil
        lastCamera = nil
        let lib = LocalCardLibrary(root: url)
        sourceKind = .card
        usesRemoteTransfer = false
        cameraID = nil
        deviceInfo = nil
        cardRoot = url
        attach(lib, name: url.lastPathComponent, host: nil)
        log.add("打开存储卡 \(url.path)")
        connectTask = Task { await loadAll() }
    }

    func ejectCard() {
        guard let root = cardRoot else { return }
        disconnect()
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: root)
            notice = "已推出 \(root.lastPathComponent)，可以拔卡了"
        } catch {
            errorMessage = "推出存储卡失败：\(error.localizedDescription)"
        }
    }

    // MARK: 读取存储卡

    private func loadAll(restoring keep: Set<String>? = nil, days keepDays: Set<String> = []) async {
        guard let library else { return }
        phase = .loading
        thumbnails = [:]; thumbOrder = []; pendingThumbs = []   // 句柄会变，旧缩略图不能再用
        do {
            let folders = try await library.folders()
            var all: [UInt32: CameraContentItem] = [:]
            var ord: [UInt32] = []
            for f in folders {
                status = "正在读取\(f.name)…"
                let hs = try await library.handles(in: f)
                for (i, h) in hs.enumerated() {
                    if i % 200 == 0 && i > 0 { status = "正在读取\(f.name)：\(i)/\(hs.count)" }
                    guard let item = try? await library.item(h), item.kind != .other else { continue }
                    all[h] = item
                    ord.append(h)
                }
            }
            for n in await library.listingNotes { log.add("读卡：\(n)") }
            items = all
            ord.sort { (all[$0]?.captureDateRaw ?? "") > (all[$1]?.captureDateRaw ?? "") }
            allShots = ShotBuilder.group(ord.compactMap { all[$0] })
            shots = Dictionary(uniqueKeysWithValues: allShots.map { ($0.id, $0) })
            shotOfFile = [:]
            for s in allShots { for h in s.handles { shotOfFile[h] = s.id } }
            slots = Array(Set(all.values.map { $0.storageID >> 16 })).sorted()
            grid = GridSelection()
            rebuild()
            if let keep {
                // 重连后：按文件身份找回原来的选择和查看的日期。
                let ids = allShots.filter { s in s.handles.contains { items[$0].map { keep.contains(Self.stableKey($0)) } ?? false } }.map(\.id)
                grid.set(ids, selected: true)
                let valid = keepDays.intersection(Set(days.map(\.id)))
                if !valid.isEmpty { shownDays = valid }
            } else {
                selectDefault()
            }
            phase = .ready
            log.add("读卡完成：\(all.count) 个文件，\(allShots.count) 次拍摄，\(days.count) 天")
        } catch {
            log.add("读取存储卡失败：\(error.localizedDescription)")
            errorMessage = "读取存储卡失败：\(error.localizedDescription)"
            phase = .ready
        }
        status = ""
    }

    /// 打开后默认：显示并勾选最近一天里没导入过的。
    private func selectDefault() {
        if let day = days.first(where: { $0.newCount > 0 }) ?? days.first {
            shownDays = [day.id]
            grid.set(day.shots.filter { !isImported(shot: $0) }, selected: true)
        }
    }

    static func dayKey(_ item: CameraContentItem) -> String {
        let raw = item.captureDateRaw
        if raw.count >= 8, raw.prefix(8).allSatisfy(\.isNumber) { return String(raw.prefix(8)) }
        guard let d = item.captureDate else { return "unknown" }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    static func dayTitle(_ key: String) -> String {
        guard key != "unknown" else { return "没有日期" }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: key) else { return key }
        let out = DateFormatter(); out.locale = Locale(identifier: "zh_CN"); out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = Calendar.current.component(.year, from: Date()) == Int(key.prefix(4)) ? "M月d日 EEE" : "yyyy年M月d日 EEE"
        return out.string(from: d)
    }

    /// 文件类型 / 卡槽筛选（不含「只看未导入」）。
    private func kindAccepted(_ item: CameraContentItem) -> Bool {
        if let slotFilter, item.storageID >> 16 != slotFilter { return false }
        switch item.kind {
        case .jpeg, .heif: return showPhotos
        case .raw: return showRaw
        case .video: return showVideo
        case .other: return false
        }
    }

    /// 一次拍摄里，按当前筛选和配对规则实际要导入的文件。
    func importFiles(of shot: Shot) -> [UInt32] {
        // 先按筛选（卡槽、类型）去掉，再去重：选了「卡 2」时就用卡 2 上的那份。
        ShotBuilder.files(of: shot, policy: pairPolicy, kindOf: { items[$0]?.kind },
                          identity: { items[$0].map { "\($0.filename)|\($0.size)" } },
                          include: { items[$0].map(kindAccepted) ?? false })
    }

    func isFileImported(_ h: UInt32) -> Bool { items[h].map { ImportHistory.shared.contains($0, camera: cameraID) } ?? false }

    /// 这次拍摄要导入的文件都导过了。
    func isImported(shot id: UInt32) -> Bool {
        guard let s = shots[id] else { return false }
        let files = importFiles(of: s)
        return !files.isEmpty && files.allSatisfy(isFileImported)
    }

    func rebuild() {
        var groups: [String: [UInt32]] = [:]
        var keys: [String] = []
        var importedCounts: [String: Int] = [:]
        for s in allShots {
            guard !importFiles(of: s).isEmpty, let first = items[s.primary] else { continue }
            let imported = isImported(shot: s.id)
            if onlyNew && imported { continue }
            let k = Self.dayKey(first)
            if groups[k] == nil { keys.append(k) }
            groups[k, default: []].append(s.id)
            if imported { importedCounts[k, default: 0] += 1 }
        }
        keys.sort { a, b in a == "unknown" ? false : b == "unknown" ? true : a > b }
        days = keys.map { k in
            ShootingDay(id: k, title: Self.dayTitle(k), shots: groups[k]!, importedCount: importedCounts[k] ?? 0)
        }
        // 被筛掉的内容不再算选中（否则会导入看不见的东西）。
        let visible = Set(days.flatMap(\.shots))
        grid.replace(with: grid.selected.intersection(visible))
        let validDays = Set(keys)
        if !shownDays.isSubset(of: validDays) { shownDays = shownDays.intersection(validDays) }
        if shownDays.isEmpty, let first = days.first { shownDays = [first.id] }
        updateGridOrder()
    }

    private func updateGridOrder() {
        grid.setOrder(visibleDays.flatMap(\.shots))
    }

    /// 某个卡槽里的拍摄数（侧栏显示）。
    func shotCount(slot: UInt32) -> Int {
        allShots.filter { $0.handles.contains { items[$0].map { $0.storageID >> 16 == slot } ?? false } }.count
    }

    /// 当前来源上没导入过的拍摄数。
    var newShotCount: Int { days.reduce(0) { $0 + $1.newCount } }

    var visibleDays: [ShootingDay] { days.filter { shownDays.contains($0.id) } }

    func item(_ h: UInt32) -> CameraContentItem? { items[h] }

    // MARK: 选择

    func checkState(_ day: ShootingDay) -> CheckState {
        let n = day.shots.filter(grid.contains).count
        if n == 0 { return .off }
        let target = day.newCount > 0 ? day.shots.filter { !isImported(shot: $0) } : day.shots
        return target.allSatisfy(grid.contains) ? .on : .mixed
    }

    /// 侧栏勾选框：勾上 = 这一天没导入过的全部选中（都导过了就全选）；再点一下取消这一天。
    func toggleDay(_ day: ShootingDay) {
        if checkState(day) == .on {
            grid.set(day.shots, selected: false)
        } else {
            let target = day.newCount > 0 ? day.shots.filter { !isImported(shot: $0) } : day.shots
            grid.set(target, selected: true)
        }
    }

    func selectNew(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { grid.set(d.shots.filter { !isImported(shot: $0) }, selected: true) }
    }

    func selectAll(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { grid.set(d.shots, selected: true) }
    }

    func deselect(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { grid.set(d.shots, selected: false) }
    }

    func day(of shot: UInt32) -> ShootingDay? { days.first { $0.shots.contains(shot) } }

    /// 要导入的文件（按显示顺序：新的在前）。
    func selectedFiles() -> [CameraContentItem] {
        allShots.filter { grid.contains($0.id) }.flatMap(importFiles).compactMap { items[$0] }
    }

    var selectedShotCount: Int { grid.selected.count }
    var selectionBytes: UInt64 { selectedFiles().reduce(0) { $0 + $1.size } }

    /// 这次拍摄的文件已经在本地的位置（用来「在访达中显示」）。
    func localFile(of shot: UInt32) -> URL? {
        guard let s = shots[shot] else { return nil }
        for h in s.handles { if let i = items[h], let u = ImportHistory.shared.localFile(i, camera: cameraID) { return u } }
        return nil
    }

    // MARK: 缩略图

    func requestThumbnail(_ h: UInt32) {
        guard thumbnails[h] == nil, !pendingThumbs.contains(h) else { return }
        pendingThumbs.append(h)
        if !thumbLoaderRunning { Task { await runThumbLoader() } }
    }

    func cancelThumbnail(_ h: UInt32) { pendingThumbs.removeAll { $0 == h } }

    private func runThumbLoader() async {
        thumbLoaderRunning = true
        defer { thumbLoaderRunning = false }
        while let library, let h = pendingThumbs.popLast() {
            // 下载时让出通道，优先传文件。
            if progress != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard let data = try? await library.thumbnail(h), let img = NSImage(data: data) else { continue }
            thumbnails[h] = img
            thumbOrder.append(h)
            if thumbOrder.count > 1500 {
                let drop = thumbOrder.prefix(300)
                thumbOrder.removeFirst(300)
                for d in drop { thumbnails[d] = nil }
            }
        }
    }

    // MARK: 预览

    func openPreview(_ shot: UInt32? = nil) {
        guard let id = shot ?? grid.focus ?? grid.order.first(where: grid.contains) ?? grid.order.first else { return }
        showPreview(id)
    }

    private func showPreview(_ id: UInt32) {
        previewShot = id
        previewLoaded = false
        previewImage = shots[id].flatMap { thumbnails[$0.primary] }
        previewTask?.cancel()
        guard let library, let s = shots[id] else { return }
        previewTask = Task {
            guard let data = try? await library.preview(s.primary), !Task.isCancelled, let img = NSImage(data: data) else { return }
            if previewShot == id { previewImage = img; previewLoaded = true }
        }
    }

    func previewStep(_ delta: Int) {
        guard let cur = previewShot, let i = grid.order.firstIndex(of: cur) else { return }
        let j = i + delta
        guard grid.order.indices.contains(j) else { return }
        grid.setFocus(grid.order[j])     // 翻页只移动焦点，不改变选择
        showPreview(grid.order[j])
    }

    /// 预览里按 P：切换当前这张的选中状态。
    func togglePreviewSelection() {
        guard let id = previewShot else { return }
        grid.set([id], selected: !grid.contains(id))
    }

    func closePreview() {
        previewTask?.cancel()
        previewShot = nil
        previewImage = nil
    }

    // MARK: 导入

    func refreshCaptureOne() {
        captureOneDocument = CaptureOneBridge.currentDocument()
    }

    static func folder(for item: CameraContentItem, root: URL) -> URL {
        let key = dayKey(item)
        guard key != "unknown" else { return root.appending(path: "没有日期", directoryHint: .isDirectory) }
        let y = String(key.prefix(4)), m = String(key.dropFirst(4).prefix(2)), d = String(key.suffix(2))
        return root.appending(path: y, directoryHint: .isDirectory).appending(path: "\(y)-\(m)-\(d)", directoryHint: .isDirectory)
    }

    /// 点「导入」：新建会话模式先问会话名，其他模式直接开始。
    func beginImport() {
        guard progress == nil, !grid.selected.isEmpty else { return }
        if captureOneMode == .newSession {
            refreshCaptureOne()
            sessionRequest = SessionRequest(suggestedName: suggestedSessionName(),
                                            existing: Array(CaptureOneBridge.sessions(in: sessionsFolder).prefix(15)))
        } else {
            startImport(session: nil)
        }
    }

    func startImport(session: SessionChoice?) {
        sessionRequest = nil
        interrupted = nil
        lastResult = nil
        lostDuringImport = false
        guard let library, progress == nil else { return }
        let picked = Array(selectedFiles().reversed())  // 旧的先导
        guard !picked.isEmpty else { return }
        let pickedShots = grid.selected
        let root = destination
        let mode = captureOneMode
        let camera = cameraID
        progress = ImportProgress(total: picked.count, bytesTotal: picked.reduce(0) { $0 + $1.size })
        lastSummary = nil
        log.add("开始导入 \(picked.count) 个文件到 \(root.path)，Capture One：\(mode.title)")
        let sessionsFolder = self.sessionsFolder
        importTask = Task {
            // 新建 / 打开会话，文件直接下载到它的 Capture 文件夹（C1 会自动显示，不用再导入）。
            var captureDir: URL?
            var sessionName = ""
            if mode == .newSession, let session {
                status = "正在准备 Capture One 会话…"
                do {
                    switch session {
                    case .new(let name):
                        sessionName = name
                        rememberContent(of: name)
                        captureDir = try await CaptureOneBridge.createSession(name: name, in: sessionsFolder)
                    case .existing(let file):
                        sessionName = file.deletingPathExtension().lastPathComponent
                        captureDir = try await CaptureOneBridge.openSession(file)
                    case .resolved(let dir, let name):
                        sessionName = name
                        captureDir = dir
                    }
                    log.add("会话「\(sessionName)」，Capture 文件夹：\(captureDir!.path)")
                } catch {
                    // C1 用不了时仍然建同样的文件夹结构，文件不会丢。
                    let dir = sessionsFolder.appending(path: sessionName.isEmpty ? "未命名" : sessionName, directoryHint: .isDirectory)
                        .appending(path: "Capture", directoryHint: .isDirectory)
                    captureDir = dir
                    log.add("新建会话失败：\(error.localizedDescription)，改存到 \(dir.path)")
                    errorMessage = "Capture One 新建会话失败：\(error.localizedDescription)\n照片会先存到 \(dir.path)。"
                }
                status = ""
                refreshCaptureOne()
            }
            var saved: [URL] = []
            var done: [(CameraContentItem, URL)] = []
            let fm = FileManager.default
            for item in picked {
                if Task.isCancelled { break }
                progress?.current = item.filename
                let dir = captureDir ?? Self.folder(for: item, root: root)
                let target = dir.appending(path: item.filename)
                do {
                    try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                    if ImportHistory.matches(target, item) {
                        // 目标位置已经有同样大小的同名文件：不重复下载，也不再交给 C1。
                        progress?.skipped += 1
                        progress?.bytesDone += item.size
                        done.append((item, target))
                        continue
                    }
                    let final = fm.fileExists(atPath: target.path) ? Self.uniqueURL(target) : target
                    if let local = Self.localCopy(of: item, root: root, camera: camera), local.standardizedFileURL != final.standardizedFileURL {
                        // 本地已经有（上次下载过）：直接拿来用。在下载文件夹里的就移过去，在别处（比如别的会话）的就复制。
                        if local.path.hasPrefix(root.path + "/") {
                            try fm.moveItem(at: local, to: final)
                            log.add("用本地文件（移动）\(local.path) → \(final.path)")
                        } else {
                            try fm.copyItem(at: local, to: final)
                            log.add("用本地文件（复制）\(local.path) → \(final.path)")
                        }
                        progress?.reused += 1
                        progress?.bytesDone += item.size
                    } else {
                        let part = dir.appending(path: ".\(item.filename).part")
                        let base = progress?.bytesDone ?? 0
                        try await library.download(item, to: part) { d, _ in
                            Task { @MainActor in
                                if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                            }
                        }
                        progress?.bytesDone = base + item.size
                        guard ImportHistory.matches(part, item) else {
                            try? fm.removeItem(at: part)
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        try fm.moveItem(at: part, to: final)
                        if let date = item.captureDate {
                            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: final.path)
                        }
                        progress?.done += 1
                    }
                    saved.append(final)
                    done.append((item, final))
                } catch is CancellationError {
                    break
                } catch {
                    if error is PTPIPTransportError { progress?.failed.append(item.filename); lostDuringImport = true; break }
                    log.add("导入失败 \(item.filename)：\(error.localizedDescription)")
                    progress?.failed.append(item.filename)
                }
            }
            ImportHistory.shared.record(done, camera: camera)
            let wasLost = lostDuringImport || (progress.map { !$0.failed.isEmpty } ?? false) && offline
            var summary = "导入 \(done.count) 个文件"
            if let p = progress, p.reused > 0 { summary += "，其中 \(p.reused) 个用了本地已有的" }
            if let p = progress, p.skipped > 0 { summary += "，\(p.skipped) 个目标文件夹里已有" }
            if let p = progress, !p.failed.isEmpty { summary += "，\(p.failed.count) 个失败" }
            if Task.isCancelled { summary += "（已取消）" }
            lastBatch = saved
            if mode == .newSession {
                if !sessionName.isEmpty { summary += "，已存入会话「\(sessionName)」" }
            } else if mode != .off && !saved.isEmpty {
                summary += await sendToCaptureOne(saved, inPlace: mode == .inPlace)
            }
            var c1Failed = false
            if mode != .newSession && mode != .off && !saved.isEmpty { c1Failed = summary.contains("Capture One 导入失败") }
            lastSummary = summary
            if wasLost {
                let resume: SessionChoice? = captureDir.map { .resolved(captureDir: $0, name: sessionName) }
                interrupted = Interrupted(done: done.count, total: picked.count, session: mode == .newSession ? resume : nil)
            } else {
                lastResult = ImportResult(files: done.count, reused: progress?.reused ?? 0, failed: progress?.failed.count ?? 0,
                                          session: mode == .newSession && !sessionName.isEmpty ? sessionName : nil,
                                          c1Failed: c1Failed, cancelled: Task.isCancelled)
            }
            log.add("导入结束：\(summary)")
            // 全部文件都导好的拍摄取消选中。
            let doneIDs = Set(done.map(\.0.id))
            grid.remove(pickedShots.filter { id in shots[id].map { importFiles(of: $0).allSatisfy(doneIDs.contains) } ?? false })
            progress = nil
            rebuild()
            importTask = nil
        }
    }

    func cancelImport() { importTask?.cancel() }

    /// 中断后继续：导到同一个会话，不再问名字。
    func continueImport() {
        guard !offline, let i = interrupted else { return }
        if i.session == nil, captureOneMode == .newSession { beginImport(); return }
        startImport(session: i.session)
    }

    func dismissResult() { lastResult = nil }

    /// 本地已有的同一个文件：先看导入记录里的位置，再看「保存位置/年/年-月-日/」（旧版记录没有位置）。
    static func localCopy(of item: CameraContentItem, root: URL, camera: String?) -> URL? {
        if let u = ImportHistory.shared.localFile(item, camera: camera) { return u }
        let guess = folder(for: item, root: root).appending(path: item.filename)
        return ImportHistory.matches(guess, item) ? guess : nil
    }

    func retryCaptureOne() {
        Task {
            let r = await sendToCaptureOne(lastBatch, inPlace: captureOneMode == .inPlace)
            lastSummary = "重新导入 \(lastBatch.count) 个文件" + r
            lastResult?.c1Failed = r.contains("失败")
        }
    }

    private func sendToCaptureOne(_ urls: [URL], inPlace: Bool) async -> String {
        if !CaptureOneBridge.isRunning {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: CaptureOneBridge.bundleID) {
                log.add("启动 Capture One")
                _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
                for _ in 0..<30 where CaptureOneBridge.currentDocument() == nil {
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
        refreshCaptureOne()
        do {
            try CaptureOneBridge.importFiles(urls, inPlace: inPlace)
            let target = captureOneDocument.map { "\($0.kind)「\($0.name)」" } ?? "Capture One"
            log.add("已交给 \(target) 导入 \(urls.count) 个文件")
            return "，已交给 \(target) 导入"
        } catch {
            log.add("Capture One 导入失败：\(error.localizedDescription)")
            errorMessage = "文件已下载到文件夹，但交给 Capture One 失败：\(error.localizedDescription)"
            return "，Capture One 导入失败"
        }
    }

    static func uniqueURL(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for n in 2...999 {
            let u = dir.appending(path: "\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return dir.appending(path: "\(base)-\(UUID().uuidString.prefix(6)).\(ext)")
    }
}
