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

    // 存储属性都在这里；AppModel+Source / +Library / +Import 里的扩展会改它们，
    // 所以不能是 private。视图只读，不要从视图里直接赋值（带 didSet 的设置项除外）。

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

    var phase: Phase = .idle
    var status = ""
    var found: [FoundCamera] = []
    var searched = false
    var connectedName: String?
    var connectedHost: String?
    var sourceKind: SourceKind = .camera
    var usesRemoteTransfer = false
    /// 正在连接的相机地址（来源页的卡片上显示转圈）。
    var connectingHost: String?
    /// 从浏览页直接换到另一台连过的相机 / 另一张卡。
    /// 先确认目标相机在线（指纹一致）再断开当前来源，免得切换失败后选择也丢了。
    var switchingTo: String?
    /// 搜索没结果，而且看起来是没有本地网络权限。
    var networkBlocked = false
    /// 首页上显示的一句话（比如「已推出 TESTCARD，可以拔卡了」）。
    var notice: String?
    /// 相机掉线了，正在自动重连；浏览页的内容和选择都保留。
    var offline = false
    var lastCamera: FoundCamera?
    var reconnectTask: Task<Void, Never>?
    var lostDuringImport = false
    /// 机身 ID（型号#序列号），导入记录用来区分不同机身。读卡器没有。
    var cameraID: String?
    var deviceInfo: CameraDeviceInfo?
    var errorMessage: String?
    var credentialRequest: CredentialRequest?
    var fingerprintRequest: FingerprintRequest?
    var credentialContinuation: CheckedContinuation<SSHCredentials?, Never>?
    var fingerprintContinuation: CheckedContinuation<Bool, Never>?
    var library: (any CameraLibrary)?
    var cardRoot: URL?
    var connectTask: Task<Void, Never>?
    var watchTask: Task<Void, Never>?
    let log = AppLog.shared

    var knownCameras: [KnownCamera] = KnownCamera.load()
    /// 插着的存储卡（读卡器 / 相机 USB 大容量存储）。
    var cards: [URL] = []

    var autoConnect: Bool = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }

    // MARK: 内容

    var items: [UInt32: CameraContentItem] = [:]
    var allShots: [Shot] = []                 // 新的在前
    var shots: [UInt32: Shot] = [:]
    var shotOfFile: [UInt32: UInt32] = [:]
    var slots: [UInt32] = []
    var slotFilter: UInt32? = nil { didSet { rebuild() } }        // nil = 全部卡槽
    var showPhotos = true { didSet { rebuild() } }
    var showRaw = true { didSet { rebuild() } }
    var showVideo = false { didSet { rebuild() } }
    var onlyNew = UserDefaults.standard.object(forKey: "onlyNew") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onlyNew, forKey: "onlyNew"); rebuild() }
    }
    var days: [ShootingDay] = []
    /// 侧栏里点中的日期（右边显示哪几天）。
    var shownDays: Set<String> = [] { didSet { updateGridOrder() } }
    /// 选中的拍摄（Shot.id）。
    var grid = GridSelection<UInt32>()
    var thumbnails: [UInt32: NSImage] = [:]
    /// 每个文件在电脑上有几份（0 / 1 / 2），读卡和导入完以后检查一遍磁盘，结果存在这里。
    var fileCopies: [UInt32: Int] = [:]
    var thumbOrder: [UInt32] = []
    var pendingThumbs: [UInt32] = []
    var thumbLoaderRunning = false
    var thumbSize: Double = UserDefaults.standard.object(forKey: "thumbSize") as? Double ?? 170 {
        didSet { UserDefaults.standard.set(thumbSize, forKey: "thumbSize") }
    }

    // MARK: 预览

    var previewShot: UInt32?
    var previewImage: NSImage?
    var previewLoaded = false
    var previewTask: Task<Void, Never>?

    // MARK: 导入

    struct ImportProgress {
        var total: Int
        var done = 0
        var skipped = 0
        var reused = 0
        var failed: [String] = []
        var bytesDone: UInt64 = 0 { didSet { sample() } }
        var bytesTotal: UInt64
        var current = ""
        var backedUp = 0
        var backupFailed: [String] = []
        /// 当前文件是续传的：从这个字节数接着传。
        var resumingFrom: UInt64?
        /// 这次导入里续传了几个文件。
        var resumedFiles = 0
        var fraction: Double { bytesTotal == 0 ? 0 : min(1, Double(bytesDone) / Double(bytesTotal)) }

        // 速度按最近 10 秒算：下载（Wi-Fi）和写备份（本地盘）快慢不同，太短的窗口会跳得厉害。
        private struct Sample { var t: TimeInterval; var bytes: UInt64 }
        private var samples: [Sample] = [Sample(t: Date().timeIntervalSinceReferenceDate, bytes: 0)]

        private mutating func sample() {
            let now = Date().timeIntervalSinceReferenceDate
            if let last = samples.last, now - last.t < 0.25 { samples[samples.count - 1].bytes = bytesDone; return }
            samples.append(Sample(t: now, bytes: bytesDone))
            while samples.count > 2, now - samples[0].t > 10 { samples.removeFirst() }
        }

        /// 不用传就算完成的字节（续传时已有的部分、本地已有的文件）：进度往前走，但不算进速度。
        mutating func credit(_ n: UInt64) {
            for i in samples.indices { samples[i].bytes += n }
            bytesDone += n
        }

        /// 每秒多少字节；数据不够 2 秒时为 nil。
        var bytesPerSecond: Double? {
            guard let f = samples.first, let l = samples.last, l.t - f.t >= 2, l.bytes > f.bytes else { return nil }
            return Double(l.bytes - f.bytes) / (l.t - f.t)
        }

        /// 预计还要多少秒。
        var secondsLeft: Double? {
            guard let r = bytesPerSecond, r > 0, bytesTotal > bytesDone else { return nil }
            return Double(bytesTotal - bytesDone) / r
        }
    }

    /// 导入前发现磁盘空间不够。
    struct SpaceProblem: Identifiable {
        let id = UUID()
        let isBackup: Bool
        let folder: URL
        let needed: UInt64
        let available: UInt64
    }

    struct ImportResult {
        var files: Int
        var reused: Int
        var failed: Int
        var session: String?
        var c1Failed: Bool
        var cancelled: Bool
        /// 备份了几个；nil = 这次没有备份（没设置或备份盘没接上）。
        var backedUp: Int?
        var backupFailed = 0
        /// 从存储卡删除了几个；nil = 这次没有要求删除。
        var deleted: Int?
        /// 要求删除、但没有删的（没通过校验、没有备份，或是视频）。
        var keptOnCard = 0
        var deleteFailed = 0
        /// 存储卡是只读的（写保护开关，或文件系统不能写），没有删。
        var cardReadOnly = false
        /// 其中从断点接着传的文件数。
        var resumed = 0
        /// 没传完、留着下次接着传的字节数（取消时）。
        var savedBytes: UInt64 = 0
        /// 这次写的 MHL 校验清单。
        var reports: [URL] = []
        /// 结果里有需要注意的（只有一份、备份失败、没删成功）。
        var needsAttention: Bool { backedUp == nil || backupFailed > 0 || cardReadOnly || deleteFailed > 0 }
    }
    /// 导入中断（相机掉线）：没导完的仍然选中，重连后可以继续。
    struct Interrupted {
        var done: Int
        var total: Int
        var session: SessionChoice?
        /// 没传完、已经保存下来的字节数，继续时从这里接着传。
        var savedBytes: UInt64 = 0
    }

    var progress: ImportProgress?
    var lastResult: ImportResult?
    var interrupted: Interrupted?
    var lastSummary: String?
    var lastBatch: [URL] = []
    var importTask: Task<Void, Never>?

    var destination: URL {
        get { UserDefaults.standard.url(forKey: "destination") ?? Self.defaultDestination }
        set { UserDefaults.standard.set(newValue, forKey: "destination"); destinationVersion += 1 }
    }
    var destinationVersion = 0
    static var defaultDestination: URL {
        FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0].appending(path: "MiniDiT", directoryHint: .isDirectory)
    }

    /// 第二份放在哪（备份盘上的文件夹）。没设置时为 nil。
    var backupFolder: URL? {
        get { _ = destinationVersion; return UserDefaults.standard.url(forKey: "backupFolder") }
        set { UserDefaults.standard.set(newValue, forKey: "backupFolder"); destinationVersion += 1 }
    }
    /// 备份盘现在能不能用（设置了，而且盘接着）。
    var backupAvailable: Bool {
        _ = volumeVersion
        guard let u = backupFolder else { return false }
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) && isDir.boolValue
    }
    /// 磁盘插拔时加一，让依赖「备份盘在不在」的界面刷新。
    var volumeVersion = 0
    /// 是否另存一份到备份盘。
    var backupEnabled: Bool = UserDefaults.standard.object(forKey: "backupEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(backupEnabled, forKey: "backupEnabled") }
    }
    /// 导入并校验通过以后，删除存储卡上的照片。
    var deleteAfterImport: Bool = UserDefaults.standard.bool(forKey: "deleteAfterImport") {
        didSet { UserDefaults.standard.set(deleteAfterImport, forKey: "deleteAfterImport") }
    }
    /// 当前来源能不能删文件：只有读卡器可以，Wi-Fi 相机不支持删除。
    var canDeleteFromSource: Bool { sourceKind == .card && connectedName != nil }
    /// 这次导入会不会删卡上的文件。
    var willDeleteFromSource: Bool { deleteAfterImport && canDeleteFromSource }
    /// 第一次打开时选择导入方式。
    var setupDone: Bool = UserDefaults.standard.bool(forKey: "setupDone") {
        didSet { UserDefaults.standard.set(setupDone, forKey: "setupDone") }
    }
    /// 点「导入」时发现没有备份盘，先问一下。
    var backupMissingPrompt = false
    /// 点「导入」时发现空间不够，先问一下。
    var spaceProblem: SpaceProblem?
    /// 这一次不备份（备份盘空间不够时用户选了「仅存储一份」）。
    var noBackupThisTime = false

    var captureOneMode: CaptureOneMode = CaptureOneMode(rawValue: UserDefaults.standard.string(forKey: "c1Mode") ?? "") ?? .newSession {
        didSet { UserDefaults.standard.set(captureOneMode.rawValue, forKey: "c1Mode") }
    }
    var pairPolicy: PairPolicy = PairPolicy(rawValue: UserDefaults.standard.string(forKey: "pairPolicy") ?? "") ?? .both {
        didSet { UserDefaults.standard.set(pairPolicy.rawValue, forKey: "pairPolicy") }
    }
    var captureOneDocument: CaptureOneBridge.DocumentInfo?

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
    var recentContents: [String] = UserDefaults.standard.stringArray(forKey: "recentContents") ?? []

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

    func rememberContent(of sessionName: String) {
        guard let dash = sessionName.firstIndex(of: "-") else { return }
        let content = sessionName[sessionName.index(after: dash)...].trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return }
        recentContents = [content] + recentContents.filter { $0 != content }
        recentContents = Array(recentContents.prefix(12))
        UserDefaults.standard.set(recentContents, forKey: "recentContents")
    }
}
