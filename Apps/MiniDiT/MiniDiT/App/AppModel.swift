import AppKit
import Foundation
import MiniDiTCore
import Observation
import ServiceManagement
import SonyRemoteKit

/// 一天的拍摄（按相机里的拍摄日期分组，不受 Mac 时区影响）。
struct ShootingDay: Identifiable, Hashable {
    let id: String          // yyyyMMdd，没有日期的是 "unknown"
    let title: String
    var shots: [UInt32]
    var importedCount: Int
    var newCount: Int { shots.count - importedCount }
    /// 按时间间隔分出的场次（新的在前）；没有分组或只有一场时只有一个。
    var scenes: [ShootingScene] = []
    /// 只显示了这一天的部分场次（侧栏点的是场次，不是日期）。
    var partial = false
}

/// 一天里的一场：相邻两张隔得比「场次间隔」久，就分成两场。
struct ShootingScene: Identifiable, Hashable {
    let id: String          // 「yyyyMMdd-场次号」
    /// 这一天里的第几场（从早到晚，从 1 开始）。
    let number: Int
    /// 「14:05–16:30」，按相机记录的时间（不换算时区）。
    let timeRange: String
    var shots: [UInt32]
    var importedCount: Int
    var newCount: Int { shots.count - importedCount }
}

enum CaptureOneMode: String, CaseIterable, Identifiable {
    case newSession, c1Settings, inPlace, lightroom, off
    var id: String { rawValue }
    /// 导入时要给每组照片起名字（C1 会话 / LrC 收藏夹）。
    var namesGroups: Bool { self == .newSession || self == .lightroom }
    var title: String {
        switch self {
        case .newSession: "新建 C1 会话（日期 + 事件），直接存入 Capture 文件夹"
        case .lightroom: "导入到 Lightroom Classic（按收藏夹整理）"
        case .off: "不导入，仅下载至文件夹"
        case .c1Settings: "按 Capture One 的导入设置导入"
        case .inPlace: "就地添加（不复制文件，仅添加到目录）"
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
    /// 和主来源同时打开的其他存储卡（多机位：主机的卡、副机的卡一起导）。主来源仍是上面 library 那一套，id 为 0。
    var extraSources: [ExtraSource] = []
    var nextSourceID = 1
    /// 同时连接的相机：盯着断线、自动重连的任务（按来源 id）。
    var extraTasks: [Int: Task<Void, Never>] = [:]
    /// 每个文件（全局句柄）来自哪个来源、在来源里的句柄。几个来源的句柄会重复，所以界面上用的是重新编号的全局句柄。
    var origins: [UInt32: Origin] = [:]
    /// 存储卡上照片的机型（从 EXIF 读，比如「α7 V」），读卡器来源用它当名字。
    var cardCameraNames: [Int: String] = [:]
    /// 存储卡上照片的机身（「型号#序列号」，从 EXIF 读），用来找这台相机的档案。
    var cardCameraKeys: [Int: String] = [:]
    /// 要改名的来源（菜单或右键里点了「重命名…」，侧栏弹出输入框）。
    var renamingSource: Int?
    /// 侧栏里点了「输入地址同时连接相机…」。
    var askingHost = false
    /// 每台机身的档案：自己起的名字、只导哪个卡槽、时钟校正。按机身存，换卡、换连接方式都跟着走。
    var cameraProfiles: [String: CameraProfile] = CameraProfile.loadAll() {
        didSet { CameraProfile.saveAll(cameraProfiles) }
    }

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
    /// 同时打开了几个来源时，只看其中一个（来源 id）；nil = 全部。
    var sourceFilter: Int? = nil { didSet { rebuild() } }
    var showPhotos = true { didSet { rebuild() } }
    var showRaw = true { didSet { rebuild() } }
    var showVideo = UserDefaults.standard.bool(forKey: "showVideo") {
        didSet { UserDefaults.standard.set(showVideo, forKey: "showVideo"); rebuild() }
    }
    /// 视频片段的拍摄信息（读卡器来源，读 M01.XML），随缩略图一起读。
    var clipInfos: [UInt32: ClipInfo] = [:]
    /// Wi-Fi 相机上视频片段的代理大小（只导代理时算选中大小用），随缩略图一起读。
    var proxySizes: [UInt32: UInt64] = [:]
    var onlyNew = UserDefaults.standard.object(forKey: "onlyNew") as? Bool ?? true {
        didSet { UserDefaults.standard.set(onlyNew, forKey: "onlyNew"); rebuild() }
    }
    /// 场次间隔（分钟）：相邻两张隔得比这久就分成两场；0 = 不分场次。
    var sceneGap = UserDefaults.standard.object(forKey: "sceneGap") as? Int ?? 0 {
        didSet { UserDefaults.standard.set(sceneGap, forKey: "sceneGap"); rebuild() }
    }
    var days: [ShootingDay] = []
    /// 侧栏里点中的日期（右边显示哪几天）。
    /// 侧栏里点中的日期或场次的 id。
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
    /// 预览中这张的拍摄参数。
    var previewExif: ShotExif?
    /// Wi-Fi 相机的预览图里有没有 EXIF，只记一次日志。
    var exifNoted = false
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
        /// 交给 Lightroom Classic 的收藏夹名（「A」「B」）。
        var lightroom: String? = nil
        /// 「只下载」导入后打开了文件夹：「，已在访达中打开」之类。
        var opened: String? = nil
        /// 只导了代理的视频片段数。
        var proxyOnly = 0
    }
    /// 导入中断（相机掉线）：没导完的仍然选中，重连后可以继续。
    struct Interrupted {
        var done: Int
        var total: Int
        /// 已经建好 / 打开的会话（按导入分组的 key），继续时直接用，不再问名字。
        var sessions: [String: ResumeSession] = [:]
        var grouping: SessionGrouping = .single
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

    /// 视频放在哪：和照片分开，按「视频文件夹」模板（默认「{M}.{D}-{事件}」）建文件夹，片段平铺在里面。
    var videoDestination: URL {
        get { _ = destinationVersion; return UserDefaults.standard.url(forKey: "videoDestination") ?? Self.defaultVideoDestination }
        set { UserDefaults.standard.set(newValue, forKey: "videoDestination"); destinationVersion += 1 }
    }
    static var defaultVideoDestination: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "MiniDiT", directoryHint: .isDirectory)
    }
    /// Wi-Fi 导视频时只导代理和 XML，原片留在卡上（之后用读卡器导）。
    var proxyOnlyWiFi: Bool = UserDefaults.standard.bool(forKey: "proxyOnlyWiFi") {
        didSet { UserDefaults.standard.set(proxyOnlyWiFi, forKey: "proxyOnlyWiFi") }
    }
    /// 代理（SUB 里的小 MP4）一起导，放进片段旁边的 Proxy/，名字改成和原片一样，Resolve 会自动链接。
    var importProxies: Bool = UserDefaults.standard.object(forKey: "importProxies") as? Bool ?? true {
        didSet { UserDefaults.standard.set(importProxies, forKey: "importProxies") }
    }

    /// 视频导完交给 Final Cut Pro（原地引用，不复制）。
    var sendToFCP: Bool = UserDefaults.standard.bool(forKey: "sendToFCP") {
        didSet { UserDefaults.standard.set(sendToFCP, forKey: "sendToFCP") }
    }

    /// 视频导完加进 DaVinci Resolve 当前打开的项目（每个视频文件夹一个媒体夹）。
    var sendToResolve: Bool = UserDefaults.standard.bool(forKey: "sendToResolve") {
        didSet { UserDefaults.standard.set(sendToResolve, forKey: "sendToResolve") }
    }

    /// 加入 Resolve 时按片段的伽马 / 色域写上输入色彩空间（不套 LUT）。
    var resolveColorSpace: Bool = UserDefaults.standard.object(forKey: "resolveColorSpace") as? Bool ?? true {
        didSet { UserDefaults.standard.set(resolveColorSpace, forKey: "resolveColorSpace") }
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
    /// 几个来源一起导时，Wi-Fi 相机的照片再按卡槽分一层（「α7 V/卡 2/」）。
    var splitBySlot: Bool = UserDefaults.standard.bool(forKey: "splitBySlot") {
        didSet { UserDefaults.standard.set(splitBySlot, forKey: "splitBySlot") }
    }
    /// 导入并校验通过以后，删除存储卡上的照片。
    var deleteAfterImport: Bool = UserDefaults.standard.bool(forKey: "deleteAfterImport") {
        didSet { UserDefaults.standard.set(deleteAfterImport, forKey: "deleteAfterImport") }
    }
    /// 当前来源能不能删文件：只有读卡器可以，Wi-Fi 相机不支持删除。
    var canDeleteFromSource: Bool { (sourceKind == .card && connectedName != nil) || !extraSources.isEmpty }
    /// 这次导入会不会删卡上的文件。
    var willDeleteFromSource: Bool { deleteAfterImport && canDeleteFromSource && !autoRunning }
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
    /// 「只下载」时，导入完成后用哪个软件打开下载的文件夹。
    var openAfterImport: FolderApp = FolderApp(rawValue: UserDefaults.standard.string(forKey: "openAfterImport") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(openAfterImport.rawValue, forKey: "openAfterImport") }
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
        let existing: [URL]
        /// 中断后继续、但有的分组还没建会话时：已经建好的那些。
        var resume: [String: ResumeSession] = [:]
    }
    var sessionRequest: SessionRequest?
    /// 导入到 LrC 前发现插件没装好 / 要重启 LrC。
    var lightroomPrompt: LightroomBridge.Status?
    /// 导入后 LrC 那边的进度（「Lightroom Classic 已添加 12/30」）。
    var lightroomStatus: String?
    var lightroomWatch: Task<Void, Never>?

    /// 一个分组已经在用的会话（中断后继续用）。
    struct ResumeSession {
        /// C1 会话的 Capture 文件夹；LrC 收藏夹没有。
        var captureDir: URL?
        var name: String
        var event: String?
    }

    /// 一次导入分成几个会话。
    enum SessionGrouping: String, CaseIterable, Identifiable {
        case single, perDay, perScene
        var id: String { rawValue }
        var title: String {
            switch self {
            case .single: "合并为一个会话"
            case .perDay: "每天一个"
            case .perScene: "每场一个"
            }
        }
    }
    var sessionGrouping = SessionGrouping(rawValue: UserDefaults.standard.string(forKey: "sessionGrouping") ?? "") ?? .single {
        didSet { UserDefaults.standard.set(sessionGrouping.rawValue, forKey: "sessionGrouping") }
    }

    /// 要导入的一组文件（一个会话）。
    struct ImportGroup: Identifiable {
        /// 「all」、日期 id 或场次 id。
        let id: String
        /// 这组最早一天（「yyyyMMdd」），会话名的日期用它。
        let day: String
        /// 分场次导入时是这一天的第几场。
        let scene: Int?
        let title: String
        let shotCount: Int
        /// 其中的视频片段数。
        var videoCount: Int { files.filter { $0.kind == .video }.count }
        /// 旧的在前。
        let files: [CameraContentItem]
    }

    /// 一个分组的一次导入：去哪个会话、事件名。
    struct ImportJob {
        var key: String
        var files: [CameraContentItem]
        var session: SessionChoice?
        var event: String?
        var scene: Int?
    }

    // MARK: 后台（v0.6）

    /// 关掉主窗口后留在菜单栏继续运行（导入不中断，插卡、相机上线时再弹出来）。
    var keepInMenuBar: Bool = UserDefaults.standard.object(forKey: "keepInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepInMenuBar, forKey: "keepInMenuBar") }
    }
    /// 插入相机存储卡时怎么办。
    var cardInsertAction: CardInsertAction = CardInsertAction(rawValue: UserDefaults.standard.string(forKey: "cardInsertAction") ?? "") ?? .open {
        didSet {
            UserDefaults.standard.set(cardInsertAction.rawValue, forKey: "cardInsertAction")
            if cardInsertAction == .notify { Notifier.shared.requestPermission() }
        }
    }
    /// 登录时打开（系统的登录项）。初始值读系统当前的状态。
    var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled {
        didSet { applyLaunchAtLogin() }
    }
    /// 导入到 C1 会话后，按拍摄时的创意外观设 ICC 配置文件（自己装的「… Look-ST」）和 Linear Response 曲线。
    var applyCreativeLook: Bool = UserDefaults.standard.bool(forKey: "applyCreativeLook") {
        didSet { UserDefaults.standard.set(applyCreativeLook, forKey: "applyCreativeLook") }
    }
    /// 连过的相机开机、连上同一网络时发通知。
    var notifyCameraOnline: Bool = UserDefaults.standard.object(forKey: "notifyCameraOnline") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(notifyCameraOnline, forKey: "notifyCameraOnline")
            startCameraWatch()
        }
    }
    /// 相机开机（连过的相机上线）后自动导入新照片。
    var autoImportCamera: Bool = UserDefaults.standard.bool(forKey: "autoImportCamera") {
        didSet { UserDefaults.standard.set(autoImportCamera, forKey: "autoImportCamera") }
    }
    /// 自动导入开始前的倒计时（菜单栏面板上显示、可取消）。
    var autoCountdown: AutoCountdown?
    var autoTask: Task<Void, Never>?
    /// 这次导入是自动开始的：不删卡上的照片，结束时发通知。
    var autoRunning = false
    /// 系统设置里允不允许 MiniDiT 发通知（nil = 还没查）。
    var notificationsAllowed: Bool?
    /// 后台看连过的相机在不在线。
    var cameraWatchTask: Task<Void, Never>?
    /// 后台看到在线的相机（按地址）：从不在线变成在线时才通知，免得每轮都弹。
    var watchOnline: [String: String] = [:]
    var watchMisses: [String: Int] = [:]
    /// 主窗口开着没有（菜单栏模式下关了窗口就隐藏程序坞图标）。
    var mainWindowOpen = false
    /// 加一 = 请求把主窗口打开到最前（由一直存在的菜单栏图标去调 openWindow）。
    var windowRequest = 0

    /// 最近用过的事件名（「3.15-公园」里的「公园」），新的在前。
    var recentContents: [String] = UserDefaults.standard.stringArray(forKey: "recentContents") ?? []

    init() {
        refreshCards()
        Notifier.shared.model = self
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let path = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)
                MainActor.assumeIsolated {
                    self?.volumesChanged(unmounted: name == NSWorkspace.didUnmountNotification ? path : nil)
                    if name == NSWorkspace.didMountNotification, let path { self?.volumeMounted(path) }
                }
            }
        }
        if autoConnect, !knownCameras.isEmpty {
            connectTask = Task { await autoConnectLast() }
        }
        startCameraWatch()
    }

    func rememberEvent(_ event: String?) {
        let content = NameTemplate.sanitize(event ?? "")
        guard !content.isEmpty else { return }
        recentContents = [content] + recentContents.filter { $0 != content }
        recentContents = Array(recentContents.prefix(12))
        UserDefaults.standard.set(recentContents, forKey: "recentContents")
    }
}

extension AppModel.ResumeSession {
    /// 继续导入时用：C1 会话直接用原来的 Capture 文件夹；LrC 收藏夹按名字找回（已有就加进去）。
    var session: AppModel.SessionChoice {
        captureDir.map { .resolved(captureDir: $0, name: name) } ?? .new(name)
    }
}

/// 按文件夹管理照片的软件：「只下载」导入完成后用它打开下载的文件夹。
enum FolderApp: String, CaseIterable, Identifiable {
    case none, finder, bridge, dxo
    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "不打开"
        case .finder: "访达"
        case .bridge: "Adobe Bridge"
        case .dxo: "DxO PhotoLab"
        }
    }

    /// 对应「设置 › 软件」里的哪一个（访达不用找）。
    var appKind: AppInfo.Kind? {
        switch self {
        case .bridge: .bridge
        case .dxo: .dxo
        default: nil
        }
    }

    /// 装了才能选（访达总是有）。
    var isAvailable: Bool { appKind.map { AppInfo.find($0).isInstalled } ?? true }
}
