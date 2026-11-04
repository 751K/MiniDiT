import AppKit
import Foundation
import Observation
import SonyRemoteKit

/// 一天的照片（按相机里的拍摄日期分组，不受 Mac 时区影响）。
struct ShootingDay: Identifiable, Hashable {
    let id: String          // yyyyMMdd，没有日期的是 "unknown"
    let title: String
    var handles: [UInt32]
    var importedCount: Int
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

enum PairPolicy: String, CaseIterable, Identifiable {
    case both, rawOnly, jpegOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .both: "RAW 和 JPEG/HEIF 都导"
        case .rawOnly: "有 RAW 时只导 RAW"
        case .jpegOnly: "有 JPEG/HEIF 时只导 JPEG/HEIF"
        }
    }
}

@MainActor @Observable
final class AppModel {
    // MARK: 连接

    enum Phase: Equatable { case idle, searching, connecting, loading, ready }

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
    private(set) var usesRemoteTransfer = false
    var errorMessage: String?
    var credentialRequest: CredentialRequest?
    var fingerprintRequest: FingerprintRequest?
    private var credentialContinuation: CheckedContinuation<SSHCredentials?, Never>?
    private var fingerprintContinuation: CheckedContinuation<Bool, Never>?
    private var library: (any CameraLibrary)?
    private var connectTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private let log = AppLog.shared

    var knownCameras: [KnownCamera] = KnownCamera.load()

    // MARK: 内容

    private(set) var items: [UInt32: CameraContentItem] = [:]
    private(set) var order: [UInt32] = []        // 新的在前
    private(set) var slots: [UInt32] = []
    var slotFilter: UInt32? = nil { didSet { rebuild() } }        // nil = 全部卡槽
    var showPhotos = true { didSet { rebuild() } }
    var showRaw = true { didSet { rebuild() } }
    var showVideo = false { didSet { rebuild() } }
    var onlyNew = false { didSet { rebuild() } }
    private(set) var days: [ShootingDay] = []
    var selectedDays: Set<String> = []
    var selection: Set<UInt32> = []
    private(set) var thumbnails: [UInt32: NSImage] = [:]
    private var thumbOrder: [UInt32] = []
    private var pendingThumbs: [UInt32] = []
    private var thumbLoaderRunning = false

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

    private(set) var progress: ImportProgress?
    private(set) var lastSummary: String?
    private(set) var lastBatch: [URL] = []
    private var importTask: Task<Void, Never>?

    var destination: URL {
        get { UserDefaults.standard.url(forKey: "destination") ?? Self.defaultDestination }
        set { UserDefaults.standard.set(newValue, forKey: "destination"); destinationVersion += 1 }
    }
    private(set) var destinationVersion = 0
    static var defaultDestination: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "相机导入", directoryHint: .isDirectory)
    }

    var captureOneMode: CaptureOneMode = CaptureOneMode(rawValue: UserDefaults.standard.string(forKey: "c1Mode") ?? "") ?? .newSession {
        didSet { UserDefaults.standard.set(captureOneMode.rawValue, forKey: "c1Mode") }
    }
    var pairPolicy: PairPolicy = PairPolicy(rawValue: UserDefaults.standard.string(forKey: "pairPolicy") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(pairPolicy.rawValue, forKey: "pairPolicy"); rebuild() }
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
    enum SessionChoice { case new(String), existing(URL) }
    struct SessionRequest: Identifiable {
        let id = UUID()
        let suggestedName: String
        let existing: [URL]
    }
    var sessionRequest: SessionRequest?

    /// 会话名默认是选中文件里最早一天的日期，格式「月.日-」（如 3.15-公园），用户在后面补内容。
    func suggestedSessionName() -> String {
        let keys = selection.compactMap { items[$0].map(Self.dayKey) }.filter { $0 != "unknown" }.sorted()
        guard let first = keys.first, let m = Int(first.dropFirst(4).prefix(2)), let d = Int(first.suffix(2)) else { return "" }
        return "\(m).\(d)-"
    }

    // MARK: 搜索

    func search() {
        guard phase == .idle else { return }
        phase = .searching
        errorMessage = nil
        log.add("搜索相机：\(CameraFinder.networkSummary())")
        let known = knownCameras
        connectTask = Task {
            let result = await CameraFinder.search(known: known) { s in
                Task { @MainActor in self.status = s }
            }
            found = result
            searched = true
            log.add("搜索结果：\(result.map { "\($0.host)\($0.knownName.map { "（\($0)）" } ?? "")" })")
            if phase == .searching { phase = .idle }
            status = ""
        }
    }

    func connect(host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        connectTask = Task {
            phase = .connecting
            status = "正在检查 \(h)…"
            if await CameraDiscovery.probe(host: h, port: PTPIPClient.defaultPort, timeout: 1.5) {
                await connect(FoundCamera(host: h, kind: .direct))
                return
            }
            if let (key, _) = try? await CameraSSHTunnel.probe(host: h, timeout: 4) {
                await connect(FoundCamera(host: h, kind: .ssh(fingerprint: key.sha256Base64)))
                return
            }
            phase = .idle
            errorMessage = "\(h) 上没有找到相机（22 和 15740 端口都连不上）。请确认相机开着、打开了「遥控拍摄」，并且和这台 Mac 在同一个网络。"
        }
    }

    func connect(_ cam: FoundCamera) {
        connectTask = Task { await connect(cam) }
    }

    private func connect(_ cam: FoundCamera) async {
        phase = .connecting
        errorMessage = nil
        log.add("连接 \(cam.host)")
        do {
            let lib = try await openLibrary(cam)
            library = lib
            connectedHost = cam.host
            connectedName = cam.knownName ?? cam.host
            KnownCamera.remember(KnownCamera(fingerprint: cam.fingerprint, host: cam.host, name: connectedName!, lastSeen: Date()))
            knownCameras = KnownCamera.load()
            let lost = lib.connectionLost
            watchTask = Task { [weak self] in
                for await _ in lost {
                    self?.handleLost()
                    return
                }
            }
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

    private func openLibrary(_ cam: FoundCamera) async throws -> any CameraLibrary {
        let step: @Sendable (String) -> Void = { s in Task { @MainActor in self.status = s; self.log.add(s) } }
        do {
            let tunnel = try await prepareTunnel(cam)
            let lib = try await SonyRemoteTransferLibrary.open(host: cam.host, identity: HostIdentityStore.identity,
                                                               tunnel: tunnel, progress: step)
            usesRemoteTransfer = true
            log.add("使用远程传输（相机界面不锁，可读两个卡槽）")
            return lib
        } catch let e where e is SonyRemoteTransferError || e is PTPError {
            log.add("远程传输不可用（\(e.localizedDescription)），改用内容传输模式")
            try? await Task.sleep(for: .milliseconds(800))
            let tunnel = try await prepareTunnel(cam)
            usesRemoteTransfer = false
            return try await SonyContentsTransfer.openLibrary(host: cam.host, identity: HostIdentityStore.identity,
                                                              tunnel: tunnel, progress: step)
        }
    }

    private func prepareTunnel(_ cam: FoundCamera) async throws -> CameraSSHTunnel? {
        guard case .ssh(let fingerprint) = cam.kind else { return nil }
        var creds = CredentialStore.load(fingerprint)
        if creds == nil { creds = await askCredentials(host: cam.host, message: nil, prefillUser: nil) }
        while true {
            guard var current = creds else { throw CancellationError() }
            try Task.checkCancellation()
            status = "正在建立加密连接…"
            do {
                let trusted = current.trustedFingerprint
                let tunnel = try await CameraSSHTunnel.open(host: cam.host, credentials: current) { key in
                    if let trusted, trusted == key.sha256Base64 { return true }
                    return await self.confirmFingerprint(host: cam.host, key: key)
                }
                current.trustedFingerprint = tunnel.hostKey.sha256Base64
                CredentialStore.save(current, tunnel.hostKey.sha256Base64)
                log.add("加密连接成功：\(tunnel.hostKey.keyType) \(tunnel.hostKey.sha256Base64)；\(tunnel.negotiated?.description ?? "")")
                return tunnel
            } catch SSHTunnelError.authenticationFailed(let detail) {
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
    }

    func disconnect() {
        importTask?.cancel()
        connectTask?.cancel()
        watchTask?.cancel()
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
        log.add("和相机的连接断开了")
        importTask?.cancel()
        library = nil
        resetContent()
        phase = .idle
        errorMessage = "和相机的连接断开了（相机关机、离开 Wi-Fi，或者被别的设备连上了）。"
    }

    private func resetContent() {
        items = [:]; order = []; slots = []; days = []
        selection = []; selectedDays = []
        thumbnails = [:]; thumbOrder = []; pendingThumbs = []
        connectedName = nil; connectedHost = nil
        progress = nil
    }

    // MARK: 读取存储卡

    private func loadAll() async {
        guard let library else { return }
        phase = .loading
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
            order = ord
            slots = Array(Set(all.values.map { $0.storageID >> 16 })).sorted()
            rebuild()
            if let first = days.first { selectedDays = [first.id] }
            phase = .ready
            log.add("读卡完成：\(all.count) 个文件，\(days.count) 天")
        } catch {
            log.add("读取存储卡失败：\(error.localizedDescription)")
            errorMessage = "读取存储卡失败：\(error.localizedDescription)"
            phase = .ready
        }
        status = ""
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

    private func accepts(_ item: CameraContentItem) -> Bool {
        if let slotFilter, item.storageID >> 16 != slotFilter { return false }
        switch item.kind {
        case .jpeg, .heif: if !showPhotos { return false }
        case .raw: if !showRaw { return false }
        case .video: if !showVideo { return false }
        case .other: return false
        }
        if onlyNew && ImportHistory.shared.contains(item) { return false }
        return true
    }

    /// 同一次拍摄的 RAW + JPEG：按设置去掉其中一个。
    private func applyPairPolicy(_ hs: [UInt32]) -> [UInt32] {
        guard pairPolicy != .both else { return hs }
        var byBase: [String: [CameraContentItem.Kind]] = [:]
        for h in hs { if let i = items[h] { byBase["\(i.storageID)/\(i.baseName)", default: []].append(i.kind) } }
        return hs.filter { h in
            guard let i = items[h], let kinds = byBase["\(i.storageID)/\(i.baseName)"] else { return true }
            let hasRaw = kinds.contains(.raw), hasPhoto = kinds.contains(.jpeg) || kinds.contains(.heif)
            switch pairPolicy {
            case .rawOnly: return !(hasRaw && (i.kind == .jpeg || i.kind == .heif))
            case .jpegOnly: return !(hasPhoto && i.kind == .raw)
            case .both: return true
            }
        }
    }

    func rebuild() {
        let visible = applyPairPolicy(order.filter { items[$0].map(accepts) ?? false })
        var groups: [String: [UInt32]] = [:]
        var keys: [String] = []
        for h in visible {
            let k = Self.dayKey(items[h]!)
            if groups[k] == nil { keys.append(k) }
            groups[k, default: []].append(h)
        }
        keys.sort { a, b in a == "unknown" ? false : b == "unknown" ? true : a > b }
        days = keys.map { k in
            let hs = groups[k]!
            return ShootingDay(id: k, title: Self.dayTitle(k), handles: hs,
                               importedCount: hs.filter { ImportHistory.shared.contains(items[$0]!) }.count)
        }
        let valid = Set(visible)
        selection = selection.intersection(valid)
        selectedDays = selectedDays.intersection(Set(keys))
    }

    var visibleDays: [ShootingDay] { days.filter { selectedDays.contains($0.id) } }

    func item(_ h: UInt32) -> CameraContentItem? { items[h] }
    func isImported(_ h: UInt32) -> Bool { items[h].map(ImportHistory.shared.contains) ?? false }

    func toggle(_ h: UInt32) {
        if selection.contains(h) { selection.remove(h) } else { selection.insert(h) }
    }

    func selectNew(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) {
            for h in d.handles where !isImported(h) { selection.insert(h) }
        }
    }

    func selectAll(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { selection.formUnion(d.handles) }
    }

    func deselect(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { selection.subtract(d.handles) }
    }

    var selectionBytes: UInt64 { selection.reduce(0) { $0 + (items[$1]?.size ?? 0) } }

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
        guard progress == nil, !selection.isEmpty else { return }
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
        guard let library, progress == nil, !selection.isEmpty else { return }
        let picked = order.filter { selection.contains($0) }.compactMap { items[$0] }.reversed()  // 旧的先导
        let root = destination
        let mode = captureOneMode
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
                        captureDir = try await CaptureOneBridge.createSession(name: name, in: sessionsFolder)
                    case .existing(let file):
                        sessionName = file.deletingPathExtension().lastPathComponent
                        captureDir = try await CaptureOneBridge.openSession(file)
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
                    if HistoryCheck.sameFile(target, item) {
                        // 目标位置已经有同样大小的同名文件：不重复下载，也不再交给 C1。
                        progress?.skipped += 1
                        progress?.bytesDone += item.size
                        done.append((item, target))
                        continue
                    }
                    let final = fm.fileExists(atPath: target.path) ? Self.uniqueURL(target) : target
                    if let local = Self.localCopy(of: item, root: root), local.standardizedFileURL != final.standardizedFileURL {
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
                    if error is PTPIPTransportError { progress?.failed.append(item.filename); break }
                    log.add("导入失败 \(item.filename)：\(error.localizedDescription)")
                    progress?.failed.append(item.filename)
                }
            }
            ImportHistory.shared.record(done)
            var summary = "下载 \(progress?.done ?? 0) 个"
            if let p = progress, p.reused > 0 { summary += "，\(p.reused) 个用了本地已有的文件" }
            if let p = progress, p.skipped > 0 { summary += "，\(p.skipped) 个目标文件夹里已有" }
            if let p = progress, !p.failed.isEmpty { summary += "，\(p.failed.count) 个失败" }
            if Task.isCancelled { summary += "（已取消）" }
            lastBatch = saved
            if mode == .newSession {
                if !sessionName.isEmpty { summary += "，已存入会话「\(sessionName)」" }
            } else if mode != .off && !saved.isEmpty {
                summary += await sendToCaptureOne(saved, inPlace: mode == .inPlace)
            }
            lastSummary = summary
            log.add("导入结束：\(summary)")
            selection.subtract(done.map(\.0.id))
            progress = nil
            rebuild()
            importTask = nil
        }
    }

    func cancelImport() { importTask?.cancel() }

    /// 本地已有的同一个文件：先看导入记录里的位置，再看「保存位置/年/年-月-日/」（旧版记录没有位置）。
    static func localCopy(of item: CameraContentItem, root: URL) -> URL? {
        if let u = ImportHistory.shared.localFile(item) { return u }
        let guess = folder(for: item, root: root).appending(path: item.filename)
        return HistoryCheck.sameFile(guess, item) ? guess : nil
    }

    func retryCaptureOne() {
        Task {
            let r = await sendToCaptureOne(lastBatch, inPlace: captureOneMode == .inPlace)
            lastSummary = "重新导入 \(lastBatch.count) 个文件" + r
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

@MainActor enum HistoryCheck {
    static func sameFile(_ url: URL, _ item: CameraContentItem) -> Bool { ImportHistory.matches(url, item) }
}
