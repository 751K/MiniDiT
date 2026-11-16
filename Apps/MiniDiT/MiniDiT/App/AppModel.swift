import AppKit
import Foundation
import MiniDiTCore
import Observation
import ServiceManagement
import SonyRemoteKit

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
    @ObservationIgnored var agentServer: AgentSocketServer?
    @ObservationIgnored var agentPlans: [String: AgentPreparedImport] = [:]

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
    var fileCameraKeys: [UInt32: String] = [:]
    var primaryConnectionID = UUID()
    var sourceIdentities: SourceIdentityStore
    var sessionCameraProfiles: [Int: CameraProfile] = [:]
    var confirmingCard: Int?
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
    @ObservationIgnored var nextGlobalHandle: UInt32 = 1
    var allShots: [Shot] = []                 // 新的在前
    var shots: [UInt32: Shot] = [:]
    var shotOfFile: [UInt32: UInt32] = [:]
    var slots: [UInt32] = []
    var slotFilter: UInt32? = nil { didSet { rebuild() } }        // nil = 全部卡槽
    /// 同时打开了几个来源时，只看其中一个（来源 id）；nil = 全部。
    var sourceFilter: Int? = nil { didSet { rebuild() } }
    var showPhotos = true { didSet { rebuild() } }
    var showRaw = true { didSet { rebuild() } }
    /// 导入范围跟着当前项目的类型走；没选项目时显示全部素材。
    var importContent: ImportContent { currentSession?.contentType ?? .all }
    var showVideo = UserDefaults.standard.object(forKey: "showVideo") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showVideo, forKey: "showVideo"); rebuild() }
    }
    /// 视频片段的拍摄信息（读卡器来源，读 M01.XML），随缩略图一起读。
    var clipInfos: [UInt32: ClipInfo] = [:]
    /// 照片在相机里打的星级（按句柄，读到才有）。
    var ratings: [UInt32: Int] = [:]
    /// 上次读完列表的时间：窗口回到前台时，隔得久了就重新读一次。
    var lastListed: Date?
    var autoRefresh = UserDefaults.standard.object(forKey: "autoRefresh") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoRefresh, forKey: "autoRefresh") }
    }
    var isRefreshingSources = false
    var refreshMessage: String?
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var refreshRequest = UUID()
    @ObservationIgnored var libraryGeneration = 0
    var mediaFilter = MediaFilter() { didSet { rebuild(); loadFilterMetadata() } }
    var metadataLoading = false
    @ObservationIgnored var metadataTask: Task<Void, Never>?
    @ObservationIgnored var metadataRead: Set<UInt32> = []
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
    /// 后台核对 fileCopies 的轮次：旧轮次算完时如果已经有新轮次，就不要覆盖。
    @ObservationIgnored var copiesGeneration = 0
    /// rebuild 时清空的派生缓存：每个 shot 要导入哪些文件、是否已经导入。
    @ObservationIgnored var importFilesCache: [UInt32: [UInt32]] = [:]
    @ObservationIgnored var importedCache: [UInt32: Bool] = [:]
    var thumbOrder: [UInt32] = []
    var pendingThumbs: [UInt32] = []
    var thumbLoaderRunning = false
    var thumbSize: Double = UserDefaults.standard.object(forKey: "thumbSize") as? Double ?? 170 {
        didSet { UserDefaults.standard.set(thumbSize, forKey: "thumbSize") }
    }

    // MARK: 预览

    var previewShot: UInt32?
    /// A context-menu request waits for this video's local preview/cache before opening the editor.
    var previewLivePhotoShot: UInt32?
    var previewImage: NSImage?
    var previewLoaded = false
    /// 预览中这张的拍摄参数。
    var previewExif: ShotExif?
    /// Wi-Fi 相机的预览图里有没有 EXIF，只记一次日志。
    var exifNoted = false
    var previewTask: Task<Void, Never>?
    @ObservationIgnored var previewRequest = UUID()
    var previewVideoURL: URL?
    var previewVideoMessage: String?
    var previewVideoProgress: Double?
    var previewIsProxy = false
    @ObservationIgnored let videoPlayback = VideoPlayback()

    // MARK: 导入

    var progress: ImportProgress?
    var lastResult: ImportResult?
    var interrupted: Interrupted?
    var lastSummary: String?
    var lastBatch: [URL] = []
    /// 上次导入的文件所在文件夹：照片和视频各一个（存在同一处时合成一个），「在访达中显示」用。
    var lastFolders: [URL] = []
    var pendingCaptureOneSessions: [CaptureOneBridge.SessionTarget: [URL]] = [:]
    var retryingCaptureOne = false
    var importTask: Task<Void, Never>?

    var destination: URL {
        get { UserDefaults.standard.url(forKey: "destination") ?? Self.defaultDestination }
        set { UserDefaults.standard.set(newValue, forKey: "destination"); destinationVersion += 1 }
    }
    var photoFolderLayout: ImportFolderLayout = ImportFolderLayout(rawValue: UserDefaults.standard.string(forKey: "photoFolderLayout") ?? "") ?? .session {
        didSet { UserDefaults.standard.set(photoFolderLayout.rawValue, forKey: "photoFolderLayout") }
    }
    var videoFolderLayout: ImportFolderLayout = ImportFolderLayout(rawValue: UserDefaults.standard.string(forKey: "videoFolderLayout") ?? "") ?? .session {
        didSet { UserDefaults.standard.set(videoFolderLayout.rawValue, forKey: "videoFolderLayout") }
    }
    var splitVideoByRoll: Bool = UserDefaults.standard.object(forKey: "splitVideoByRoll") as? Bool
        ?? (UserDefaults.standard.string(forKey: NameTemplate.Kind.video.key) == UsageMode.teamVideoTemplate) {
        didSet { UserDefaults.standard.set(splitVideoByRoll, forKey: "splitVideoByRoll") }
    }
    /// 旧版自定义备份规则继续可用；默认备份沿用各类素材的实际目录。
    var backupFollowsOrganization: Bool = UserDefaults.standard.object(forKey: "backupFollowsOrganization") as? Bool
        ?? ((UserDefaults.standard.string(forKey: NameTemplate.Kind.backup.key) ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || UserDefaults.standard.string(forKey: NameTemplate.Kind.backup.key) == NameTemplate.Kind.backup.defaultValue) {
        didSet { UserDefaults.standard.set(backupFollowsOrganization, forKey: "backupFollowsOrganization") }
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

    var sendToPremiere: Bool = UserDefaults.standard.bool(forKey: "sendToPremiere") {
        didSet { UserDefaults.standard.set(sendToPremiere, forKey: "sendToPremiere") }
    }
    /// 导入后在剪映专业版里新建草稿，视频放在素材区。
    var sendToJianying: Bool = UserDefaults.standard.bool(forKey: "sendToJianying") {
        didSet { UserDefaults.standard.set(sendToJianying, forKey: "sendToJianying") }
    }

    /// 交给 FCP 时给 S-Log3 片段打开 FCP 内置的 Log 处理。
    var fcpLogProcessing: Bool = UserDefaults.standard.object(forKey: "fcpLogProcessing") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fcpLogProcessing, forKey: "fcpLogProcessing") }
    }

    /// MiniDiT 项目在 FCP 里作为资源库还是事件。
    var fcpProjectAs: FCPXMLWriter.ProjectMapping = FCPXMLWriter.ProjectMapping(rawValue: UserDefaults.standard.string(forKey: "fcpProjectAs") ?? "") ?? .library {
        didSet { UserDefaults.standard.set(fcpProjectAs.rawValue, forKey: "fcpProjectAs") }
    }
    /// 「作为事件」时放进的资源库；没选过时用「影片」文件夹里的 MiniDiT.fcpbundle，FCP 会自动新建。
    var fcpEventLibrary: URL = UserDefaults.standard.string(forKey: "fcpEventLibrary").map { URL(filePath: $0) } ?? FCPXMLWriter.defaultEventLibrary {
        didSet { UserDefaults.standard.set(fcpEventLibrary.path, forKey: "fcpEventLibrary") }
    }

    /// 加入 Resolve 时按片段的伽马 / 色域写上输入色彩空间（不套 LUT）。
    var resolveColorSpace: Bool = UserDefaults.standard.object(forKey: "resolveColorSpace") as? Bool ?? true {
        didSet { UserDefaults.standard.set(resolveColorSpace, forKey: "resolveColorSpace") }
    }

    var backupTargets: [BackupDestination] = AppModel.loadBackupTargets() {
        didSet {
            if let data = try? JSONEncoder().encode(backupTargets) { UserDefaults.standard.set(data, forKey: "backupDestinations") }
            UserDefaults.standard.set(backupTargets.first?.root, forKey: "backupFolder")
            destinationVersion += 1
        }
    }
    var importBackupProgress: [BackupTargetProgress] = []
    var backupDiskIdentities: [String: PhysicalDiskIdentity] = [:]
    var backupDiskIdentityKey: String?

    @ObservationIgnored var activeBackupBatchID: UUID?
    @ObservationIgnored var backupAssetIDs: Set<UUID> = []
    @ObservationIgnored var verifiedBackupAssets: [UUID: Set<UUID>] = [:]
    @ObservationIgnored var failedBackupAssets: [UUID: Set<UUID>] = [:]
    /// The primary-target alias remains for callers that configure one location.
    var backupFolder: URL? {
        get { backupTargets.first?.root }
        set {
            guard let newValue else { backupTargets = []; return }
            if let first = backupTargets.first { replaceBackupTarget(first.id, root: newValue) }
            else { addBackupTarget(newValue) }
        }
    }
    var backupAvailable: Bool {
        _ = volumeVersion
        return !enabledBackupTargets.isEmpty && missingRequiredBackupTargets.isEmpty
    }
    /// 磁盘插拔时加一，让依赖「备份盘在不在」的界面刷新。
    var volumeVersion = 0
    /// 是否在导入时写入所选备份目标。
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
    /// 设置向导的版本：向导加了新步骤时加一，老用户升级后也会看到一次（已有的设置会填好）。
    static let setupVersion = 2
    /// 走完了当前版本的设置向导。
    var setupDone: Bool = UserDefaults.standard.integer(forKey: "setupVersion") > 0 {
        didSet { UserDefaults.standard.set(setupDone ? Self.setupVersion : 0, forKey: "setupVersion") }
    }
    /// 从“设置 › 通用”重新打开设置向导（在主窗口里显示）。
    var showingSetup = false
    /// 工作流程只提供推荐默认值；功能是否可用与流程无关。
    var usageMode: UsageMode = UsageMode(rawValue: UserDefaults.standard.string(forKey: "usageMode") ?? "") ?? .personal {
        didSet { UserDefaults.standard.set(usageMode.rawValue, forKey: "usageMode") }
    }

    /// 应用所选工作流程的建议；保留自定义命名，不在加载设置时自动调用。
    func applyModeDefaults() {
        let key = NameTemplate.Kind.video.key
        let current = UserDefaults.standard.string(forKey: key)?.trimmingCharacters(in: .whitespaces) ?? ""
        switch usageMode {
        case .team:
            if current.isEmpty || current == NameTemplate.Kind.video.defaultValue {
                UserDefaults.standard.set(UsageMode.teamVideoTemplate, forKey: key)
                if videoFolderLayout == .session { splitVideoByRoll = true }
            }
            // 交接前由团队确认，不自动导入或删除原卡文件。
            autoImportCamera = false
            deleteAfterImport = false
        case .personal:
            if current == UsageMode.teamVideoTemplate {
                UserDefaults.standard.removeObject(forKey: key)
                if videoFolderLayout == .session { splitVideoByRoll = false }
            }
        }
    }
    /// 点「导入」时发现没有备份盘，先问一下。
    var backupMissingPrompt = false
    /// 点「导入」时发现空间不够，先问一下。
    var spaceProblem: SpaceProblem?
    /// 这一次不备份（备份盘空间不够时用户选了「仅存储一份」）。
    var noBackupThisTime = false

    var captureOneMode: CaptureOneMode = CaptureOneMode(rawValue: UserDefaults.standard.string(forKey: "c1Mode") ?? "") ?? .off {
        didSet { UserDefaults.standard.set(captureOneMode.rawValue, forKey: "c1Mode") }
    }
    /// 「只下载」时，导入完成后用哪个软件打开下载的文件夹。
    var openAfterImport: FolderApp = FolderApp(rawValue: UserDefaults.standard.string(forKey: "openAfterImport") ?? "") ?? .none {
        didSet { UserDefaults.standard.set(openAfterImport.rawValue, forKey: "openAfterImport") }
    }

    var pairPolicy: PairPolicy = PairPolicy(rawValue: UserDefaults.standard.string(forKey: "pairPolicy") ?? "") ?? .both {
        // 配对规则会改变每个 shot 要导入哪些文件，缓存必须跟着重建。
        didSet { UserDefaults.standard.set(pairPolicy.rawValue, forKey: "pairPolicy"); rebuild() }
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

    var sessionRequest: SessionRequest?

    /// 软件自己管理的会话（侧栏「会话」）：一次拍摄任务（日期 + 事件）。和 Capture One 的会话无关，
    /// 导入时 C1 会话、LrC 收藏夹、下载文件夹都沿用它的名字。
    var sessionRecordURL: URL?
    var importJournal: ImportJournalStore
    var sessions: [ShootSession] = ShootSession.load()
    /// 当前会话：之后点「导入」都归到这里。
    var currentSessionID: UUID? { didSet { if currentSessionID != oldValue { contentChanged() } } }
    /// 右边正在浏览的会话（已导入到电脑上的文件）；nil = 浏览相机 / 存储卡。
    var browsingSession: UUID?
    /// 项目内容当前只看照片、只看视频，或 nil = 全部。
    var browsingSessionMedia: ProjectMedia?
    var newSessionPrompt: NewSessionPrompt?
    /// 导入到 LrC 前发现插件没装好 / 要重启 LrC。
    var lightroomPrompt: LightroomBridge.Status?
    /// 导入后 LrC 那边的进度（「Lightroom Classic 已添加 12/30」）。
    var deliveryID = UUID()
    var deliveryMessages: [String: String] = [:]
    var deliveryFailures: Set<String> = []
    var videoDeliveryServices = VideoDeliveryServices()
    var videoDeliveryTask: Task<Void, Never>?
    var videoDeliveryRunning: UUID?
    @ObservationIgnored var videoDeliveryQueue: [VideoDeliveryJob] = []

    /// 异步的软件回执只更新所属导入，避免覆盖下一批的结果。
    func updateDelivery(_ software: String, message: String, failed: Bool = false, id: UUID) {
        _ = importJournal.update(id) { $0.delivery[software] = message }
        guard id == deliveryID else { return }
        deliveryMessages[software] = message
        if failed { deliveryFailures.insert(software) }
        else { deliveryFailures.remove(software) }
    }

    var lightroomStatus: String?
    var lightroomWatch: Task<Void, Never>?

    var sessionGrouping = SessionGrouping(rawValue: UserDefaults.standard.string(forKey: "sessionGrouping") ?? "") ?? .single {
        didSet { UserDefaults.standard.set(sessionGrouping.rawValue, forKey: "sessionGrouping") }
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

    // MARK: 联机拍摄（AppModel+Tether）

    /// 正在联机拍摄的相机；它拍的照片放在联机缓存里，当作主来源（一张「存储卡」）。
    var tether: TetherSession?
    /// 上次联机的相机（断开后「重新连接」用）。
    var lastTetherCamera: FoundCamera?
    /// 加一 = 请求打开联机拍摄窗口。
    var tetherWindowRequest = 0
    /// 拍到新照片后自动导入当前项目。
    var tetherAutoImport = UserDefaults.standard.object(forKey: "tetherAutoImport") as? Bool ?? true {
        didSet { UserDefaults.standard.set(tetherAutoImport, forKey: "tetherAutoImport") }
    }
    @ObservationIgnored var tetherNeedsReload = false
    /// 已经自动导入过（或试过）的缓存文件名：导入失败的不反复重试，用户可以手动再导。
    @ObservationIgnored var tetherAttempted: Set<String> = []
    @ObservationIgnored var tetherTask: Task<Void, Never>?

    /// 最近用过的事件名（「3.15-公园」里的「公园」），新的在前。
    var recentContents: [String] = UserDefaults.standard.stringArray(forKey: "recentContents") ?? []

    init(startServices: Bool = true, journalURL: URL? = nil, identityURL: URL? = nil) {
        sourceIdentities = SourceIdentityStore(url: identityURL ?? (startServices ? SourceIdentityStore.defaultURL
            : FileManager.default.temporaryDirectory.appending(path: "minidit-identities-" + UUID().uuidString + ".json")))
        importJournal = ImportJournalStore(url: journalURL ?? (startServices ? ImportJournalStore.defaultURL
            : FileManager.default.temporaryDirectory.appending(path: "minidit-check-journal-" + UUID().uuidString + ".json")))
        guard startServices else { return }
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
        startLibraryWatch()
        startAgentControl()
    }

    func rememberEvent(_ event: String?) {
        let content = NameTemplate.sanitize(event ?? "")
        guard !content.isEmpty else { return }
        recentContents = [content] + recentContents.filter { $0 != content }
        recentContents = Array(recentContents.prefix(12))
        UserDefaults.standard.set(recentContents, forKey: "recentContents")
    }
}
