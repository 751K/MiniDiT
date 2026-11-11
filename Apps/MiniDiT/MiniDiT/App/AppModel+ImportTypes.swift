import AppKit
import Foundation
import MiniDiTCore
import Observation
import ServiceManagement
import SonyRemoteKit


// 导入用到的类型：进度、结果、分组、任务。

extension AppModel {
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
        /// 结果中实际发生的异常；用户主动选择只存一份不视为失败。
        var needsAttention: Bool { failed > 0 || cancelled || c1Failed || backupFailed > 0 || cardReadOnly || deleteFailed > 0 }
        /// 交给 Lightroom Classic 的收藏夹名（「A」「B」）。
        var lightroom: String? = nil
        /// 「只下载」导入后打开了文件夹：「，已在访达中打开」之类。
        var opened: String? = nil
        /// 只导了代理的视频片段数。
        var proxyOnly = 0
        var hasWiFiSource = false
        var backupTargets: [BackupTargetProgress] = []
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
        var jobs: [ImportJob] = []
        var captureOneFiles: [CaptureOneBridge.SessionTarget: [URL]] = [:]
    }

    /// 导入前要用户填会话名。
    enum SessionChoice { case new(String), existing(URL), resolved(CaptureOneBridge.SessionTarget) }

    struct SessionRequest: Identifiable {
        let id = UUID()
        let existing: [URL]
        /// 中断后继续、但有的分组还没建会话时：已经建好的那些。
        var resume: [String: ResumeSession] = [:]
    }

    /// 弹出「新建会话」窗口；importAfter = 建好后马上导入当前选中的内容。
    struct NewSessionPrompt: Identifiable { let id = UUID(); var importAfter: Bool }

    /// 一个分组已经在用的会话（中断后继续用）。
    struct ResumeSession {
        var captureOneTarget: CaptureOneBridge.SessionTarget?
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
        /// 用于记录归属的会话名；物理目录由照片、视频各自的整理偏好决定。
        var folder: String? = nil
        /// 开始导入时冻结规则，中断后继续仍使用原目录。
        var plan: ImportPlan? = nil
        /// 导完后记进哪个软件会话。
        var appSession: UUID? = nil
    }
}

extension AppModel.ResumeSession {
    /// 继续导入时用：C1 会话直接用原来的 Capture 文件夹；LrC 收藏夹按名字找回（已有就加进去）。
    var session: AppModel.SessionChoice {
        captureOneTarget.map { .resolved($0) } ?? .new(name)
    }
}

extension CameraContentItem {
    /// 空间检查和进度用的估算：大小未知（≥4GB 的视频，ObjectInfo 里是 0xFFFFFFFF）时按 4 GiB 下限算，
    /// 避免被当成 0 字节。
    var sizeEstimate: UInt64 { sizeKnown ? size : 4 << 30 }
}
