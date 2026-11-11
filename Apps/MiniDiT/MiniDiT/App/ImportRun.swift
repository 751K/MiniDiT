import Foundation
import Dispatch
import MiniDiTCore
import SonyRemoteKit

/// 一次导入从开始到结束共用的状态：开始时冻结的计划，以及导入过程中逐步累积的结果。
/// 导入的各个阶段（登记来源、分卷号、逐组导入、收尾）都读写这一份。
@MainActor
final class ImportRun {
    let jobs: [AppModel.ImportJob]
    let grouping: AppModel.SessionGrouping
    let plan: ImportPlan
    /// 这次要导入的全部文件，旧的在前。
    let picked: [CameraContentItem]
    /// 本批导入的 ID（导入记录、后期发送都用它）。
    let token: UUID
    let hasWiFiSource: Bool
    /// 开始时选中的拍摄；全部文件都导好的，结束后取消选中。
    let pickedShots: Set<UInt32>
    /// 几个来源一起导时，每个来源的子文件夹名。
    let folders: [Int: String]
    let backupRoot: URL?
    let wantsBackup: Bool
    let requestedBackupRoot: URL?
    let journal: ImportJournalStore
    let deleteRequested: Bool
    let proxies: Bool
    /// Primary reads; target copies are added as assets are checkpointed.
    let weight: UInt64 = 1

    var root: URL { plan.photoRoot }
    var mode: CaptureOneMode { plan.captureOneMode }
    var sessionsFolder: URL { plan.captureRoot }
    /// 视频单独一套：「视频保存位置/{M}.{D}-{事件}/」，不进 C1 会话、不交给 LrC。
    var videoRoot: URL { plan.videoRoot }

    /// 卷号：这次导入的视频按机型各开一卷（之前分过卷的片段沿用原来的）。
    var rolls: [UInt32: String] = [:]
    var videoEvents: [FCPXMLWriter.Event] = []
    /// 新存下的照片（交给 Capture One 用）。
    var saved: [URL] = []
    var done: [ImportHistory.Entry] = []
    var proxyOnlyDone = 0
    /// 可以从卡上删的：和卡上数据核对过；要求备份时备份也成功了；不是视频（删视频会让相机的数据库对不上）。
    var deletable: [UInt32] = []
    var consecutiveFailures = 0
    var reports: [URL] = []
    var captureOneFiles: [CaptureOneBridge.SessionTarget: [URL]]
    var opened: [String: AppModel.ResumeSession] = [:]
    /// 相机掉线或连续失败：停止后面的分组，等重连后继续。
    var stop = false
    var lightroomJobs: [String] = []
    var lightroomCollections: [String] = []
    var wokeLightroom = false

    init(jobs: [AppModel.ImportJob], grouping: AppModel.SessionGrouping, plan: ImportPlan, picked: [CameraContentItem],
         token: UUID, hasWiFiSource: Bool, pickedShots: Set<UInt32>, folders: [Int: String],
         backupRoot: URL?, wantsBackup: Bool, requestedBackupRoot: URL?, journal: ImportJournalStore,
         deleteRequested: Bool, proxies: Bool, captureOneFiles: [CaptureOneBridge.SessionTarget: [URL]]) {
        self.jobs = jobs
        self.grouping = grouping
        self.plan = plan
        self.picked = picked
        self.token = token
        self.hasWiFiSource = hasWiFiSource
        self.pickedShots = pickedShots
        self.folders = folders
        self.backupRoot = backupRoot
        self.wantsBackup = wantsBackup
        self.requestedBackupRoot = requestedBackupRoot
        self.journal = journal
        self.deleteRequested = deleteRequested
        self.proxies = proxies
        self.captureOneFiles = captureOneFiles
    }

    /// 导入记录里一个文件的 ID。
    func fileID(_ job: AppModel.ImportJob, _ item: CameraContentItem) -> String { "\(job.key)|\(item.id)" }
}

/// 一次导入里的一个分组（一个会话）：目标目录、交给 LrC 的叠放顺序、这一组的校验清单。
@MainActor
final class ImportJobState {
    let job: AppModel.ImportJob
    /// 导入 C1 会话时的目标会话。Capture One 只在交接时打开。
    let target: CaptureOneBridge.SessionTarget?
    let captureDir: URL?
    let event: String?
    let layout: ImportOrganization
    let groupName: String?

    /// 导入到 LrC：收藏夹名就是这一组的名字。
    var collection: String?
    /// RAW + JPG/HIF 成对时要叠在一起，插件得先有 RAW 才能叠。下载顺序不一定是 RAW 在前，
    /// 所以 RAW 还没导完的 JPG/HIF 先留着，等 RAW 交出去后紧跟着交。
    var rawKeys: Set<String> = []
    var rawByKey: [String: URL] = [:]
    var waiting: [String: [URL]] = [:]
    var firstInCollection = true
    /// 写 MHL 校验清单用：照片、视频的第一份，各按所在文件夹分，每个文件夹一份。
    var mhlPhoto: [URL: [MHLWriter.Entry]] = [:]
    var mhlVideo: [URL: [MHLWriter.Entry]] = [:]
    /// 交给 Final Cut Pro 的片段，按视频文件夹分（一个文件夹一个事件）。
    var fcpClips: [URL: [FCPXMLWriter.Clip]] = [:]

    init(job: AppModel.ImportJob, target: CaptureOneBridge.SessionTarget?, event: String?,
         layout: ImportOrganization, groupName: String?) {
        self.job = job
        self.target = target
        self.captureDir = target?.captureDir
        self.event = event
        self.layout = layout
        self.groupName = groupName
    }
}

/// 一个文件导完后，这一组接着导下一个，还是停下来。
enum ImportStep { case next, stop }

/// 导入进度回调从后台线程每 8 MB 来一次。界面最多每 100 ms 更新一次，
/// 避免每个数据块都起一个 MainActor Task、触发一次整条进度栏重绘。
/// 每个文件结束时仍会精确写一次最终值。
final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt64 = 0

    func allow() -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        return lock.withLock {
            guard now &- last >= 100_000_000 else { return false }
            last = now
            return true
        }
    }
}
