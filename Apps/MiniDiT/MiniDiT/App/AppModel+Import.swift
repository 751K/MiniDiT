import AppKit
import Dispatch
import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {

    // MARK: 导入

    /// 改变照片软件接收方式时，仍保留用户选中的项目归属。
    func startImport(session: SessionChoice?) {
        guard var job = currentSessionJob() else {
            newSessionPrompt = .init(importAfter: true)
            return
        }
        job.session = session
        startImport(jobs: [job], grouping: .single)
    }

    func startImport(jobs: [ImportJob], grouping: SessionGrouping,
                     captureOneFiles: [CaptureOneBridge.SessionTarget: [URL]] = [:]) {
        guard importJournal.repairTask == nil, !openSources.isEmpty, phase == .ready, progress == nil, !isRefreshingSources,
              !jobs.isEmpty, !retryingCaptureOne else { return }
        // 所有普通导入入口（含自动导入和续传）都必须携带有效项目；拖出由 FileExport 独立处理。
        let projects = Set(sessions.map(\.id))
        guard jobs.allSatisfy({ job in job.appSession.map { projects.contains($0) } == true }) else {
            errorMessage = "请先选择或新建项目，再开始导入。"
            return
        }
        sessionRequest = nil
        interrupted = nil
        lastResult = nil
        pendingCaptureOneSessions = [:]
        lostDuringImport = false
        prepareSourceIdentities()
        let plan = jobs.first?.plan ?? importPlan
        let organization = plan.organization
        let jobs = jobs.map { original in
            var job = original
            job.files = job.files.filter { plan.content.accepts($0.kind) }
            job.plan = plan
            return job
        }.filter { !$0.files.isEmpty }
        let picked = jobs.flatMap(\.files)  // 旧的先导
        guard !picked.isEmpty else { return }
        deliveryID = UUID()
        let deliveryToken = deliveryID
        deliveryMessages = [:]
        deliveryFailures = []
        lightroomWatch?.cancel()
        lightroomStatus = nil
        let hasWiFiSource = picked.contains { !(route($0.id)?.library is LocalCardLibrary) }
        let pickedShots = grid.selected
        let root = plan.photoRoot
        let mode = plan.captureOneMode
        let folders = sourceFolders()
        let backupRoot = plan.backupTargets.first?.root ?? plan.backupRoot
        noBackupThisTime = false
        let wantsBackup = plan.backupRequested || backupRoot != nil
        let requestedBackupRoot = backupRoot ?? (wantsBackup ? plan.configuredBackupRoot : nil)
        let journal = importJournal
        let journalFiles = jobs.flatMap { job in
            job.files.map { item in
                var record = ImportedFileRecord(id: "\(job.key)|\(item.id)", projectID: job.appSession,
                                                filename: item.filename, source: importDeviceName(source(of: item.id)))
                record.sourceIdentity = sourceIdentitySnapshot(source(of: item.id), slot: item.storageID >> 16)
                record.mediaKind = item.kind == .video ? "video" : "photo"
                record.capturedAt = item.captureDate
                record.captureDateRaw = item.captureDateRaw.isEmpty ? nil : item.captureDateRaw
                record.expectedBytes = item.sizeKnown ? item.size : nil
                record.proxyOnly = importsProxyOnly(item)
                return record
            }
        }
        var journalBatch = ImportBatchRecord(id: deliveryToken, files: journalFiles, backupRequested: wantsBackup,
                                            backupRoot: requestedBackupRoot?.path)
        journalBatch.backupVolumeID = requestedBackupRoot.flatMap { BackupRepair.volumeID(at: $0) }
        journalBatch.workingRoots = Array(Set([root.path, plan.videoRoot.path, plan.captureRoot.path])).sorted()
        if !plan.backupTargets.isEmpty { journalBatch.backupTargets = plan.backupTargets }
        guard journal.begin(journalBatch) else { errorMessage = journal.persistenceError; return }
        let deleteRequested = willDeleteFromSource
        let weight: UInt64 = 1 // Primary reads; target copies are added as assets are checkpointed.
        progress = ImportProgress(total: picked.count, bytesTotal: picked.reduce(0) { $0 + transferSize($1) } * weight)
        updateBackupProgress(deliveryToken)
        lastSummary = nil
        log.add("开始导入 \(picked.count) 个文件到 \(root.path)，Capture One：\(mode.title)，"
                + (backupRoot.map { "备份到 \($0.path)" } ?? "没有备份")
                + (jobs.count > 1 ? "，分成 \(jobs.count) 个会话" : ""))
        let run = ImportRun(jobs: jobs, grouping: grouping, plan: plan, picked: picked, token: deliveryToken,
                            hasWiFiSource: hasWiFiSource, pickedShots: pickedShots, folders: folders,
                            backupRoot: backupRoot, wantsBackup: wantsBackup, requestedBackupRoot: requestedBackupRoot,
                            journal: journal, deleteRequested: deleteRequested, proxies: importProxies,
                            captureOneFiles: captureOneFiles)
        importTask = Task { await runImport(run) }
    }

    func cancelImport() { importTask?.cancel() }

    /// 这些文件共同所在的最深一层文件夹（一天就是那一天的文件夹，跨了几天就是上一层）。
    static func commonFolder(_ files: [URL]) -> URL? {
        let dirs = files.map { $0.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var common = dirs.first else { return nil }
        for d in dirs.dropFirst() {
            var n = 0
            while n < min(common.count, d.count), common[n] == d[n] { n += 1 }
            common = Array(common.prefix(n))
        }
        guard common.count > 1 else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: common), isDirectory: true)
    }

    /// 照片和视频分别保存，各取一个共同文件夹；一个在另一个里面时只留外层的。照片在前。
    static func importFolders(photos: [URL], videos: [URL]) -> [URL] {
        let folders = [commonFolder(photos), commonFolder(videos)].compactMap { $0?.standardizedFileURL }
        return folders.enumerated().filter { i, folder in
            !folders.enumerated().contains { j, other in
                j != i && (folder.path.hasPrefix(other.path + "/") || (folder.path == other.path && j < i))
            }
        }.map(\.element)
    }

    /// 用选好的软件打开下载的文件夹，返回接在导入结果后面的说明。Bridge 和 DxO PhotoLab 打开文件夹时会定位到它。
    /// 访达打开全部文件夹；Bridge 和 DxO PhotoLab 只打开第一个（有照片时是照片文件夹）。
    func openFolders(_ folders: [URL], in app: FolderApp) -> String? {
        guard let folder = folders.first else { return nil }
        switch app {
        case .none:
            return nil
        case .finder:
            for f in folders { NSWorkspace.shared.open(f) }
            return "，已在访达中打开"
        case .bridge, .dxo:
            guard let kind = app.appKind, let appURL = AppInfo.find(kind).url else {
                log.add("导入后打开：没有找到 \(app.title)")
                return "；未找到 \(app.title)，未打开文件夹"
            }
            NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { Task { @MainActor in AppLog.shared.add("用 \(app.title) 打开 \(folder.path) 失败：\(error.localizedDescription)") } }
            }
            log.add("导入后用 \(app.title) 打开：\(folder.path)")
            return "，已在 \(app.title) 中打开"
        }
    }

    /// 会话名「3.15-公园」里的「公园」；没有「-」就用整个名字。
    static func eventName(of sessionName: String) -> String? {
        let s = sessionName.firstIndex(of: "-").map { String(sessionName[sessionName.index(after: $0)...]) } ?? sessionName
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// 续传沿用原任务的项目和路径，不使用此时侧栏里选中的其他项目。
    func continueImport() {
        guard !sourcesOffline, let i = interrupted else { return }
        guard !i.jobs.isEmpty else {
            errorMessage = "此导入缺少项目记录，请选择项目后重新导入。"
            return
        }
        startImport(jobs: i.jobs, grouping: i.grouping, captureOneFiles: i.captureOneFiles)
    }

    func dismissResult() { lastResult = nil }
    /// 放弃继续导入：没导完的照片仍然选中，可以重新导入。
    func dismissInterrupted() { interrupted = nil }

}
