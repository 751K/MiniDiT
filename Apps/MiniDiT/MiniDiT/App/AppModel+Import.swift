import AppKit
import Dispatch
import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {

    // MARK: 导入

    func refreshCaptureOne() {
        captureOneDocument = CaptureOneBridge.currentDocument()
    }

    /// 普通导入必须有用户选择的项目；先确定项目，再检查备份、空间和后期软件。
    /// 界面上点按钮时用默认参数；提醒里点「继续」时跳过已经确认过的检查。
    func beginImport(checkBackup: Bool = true, checkSpace: Bool = true) {
        guard importJournal.repairTask == nil, progress == nil, phase == .ready, !isRefreshingSources, !grid.selected.isEmpty else { return }
        guard currentSession != nil else {
            newSessionPrompt = .init(importAfter: true)
            return
        }
        if checkBackup {
            noBackupThisTime = false
            if backupEnabled, !backupAvailable {
                backupMissingPrompt = true
                return
            }
        }
        if checkSpace, let p = spaceShortage() {
            log.add("空间不够：\(p.folder.path) 剩 \(p.available) 字节，需要 \(p.needed)")
            spaceProblem = p
            return
        }
        let hasPhotos = selectedFiles().contains { $0.kind != .video }
        if hasPhotos, captureOneMode == .lightroom {
            let st = LightroomBridge.status()
            guard st.canImport else { lightroomPrompt = st; return }
        }
        if hasPhotos, captureOneMode == .newSession { refreshCaptureOne() }
        importToCurrentSession()
    }

    /// Aggregate storage requirements per mounted volume, including every required target.
    func spaceShortage() -> SpaceProblem? {
        let files = selectedFiles(), history = ImportHistory.shared
        let missing = files.filter { history.localFile($0, camera: camera(of: $0.id)) == nil }
        let photoNeed = missing.filter { $0.kind != .video }.reduce(UInt64(0)) { $0 + $1.sizeEstimate }
        let videoNeed = missing.filter { $0.kind == .video }.reduce(UInt64(0)) { $0 + $1.sizeEstimate }
        let primary = captureOneMode == .newSession ? sessionsFolder : destination
        var used: [String: UInt64] = [:]
        var requests: [(URL, UInt64, Bool)] = [(primary, photoNeed, false), (videoDestination, videoNeed, false)]
        if backupEnabled, !noBackupThisTime {
            for target in enabledBackupTargets where target.required && target.availability == .available {
                let need = files.filter { item in
                    !history.backupFiles(item, camera: camera(of: item.id)).contains { $0.path.hasPrefix(target.path + "/") }
                }.reduce(UInt64(0)) { $0 + $1.sizeEstimate }
                requests.append((target.root, need, true))
            }
        }
        for (folder, need, backup) in requests where need > 0 {
            let key = Self.volume(of: folder)?.path ?? folder.path
            let combined = (used[key] ?? 0) + need
            if let free = Self.freeSpace(at: folder), free < combined + Self.spaceMargin(combined) {
                return SpaceProblem(isBackup: backup, folder: folder, needed: combined, available: free)
            }
            used[key] = combined
        }
        return nil
    }

    /// 文件夹所在的磁盘（还没建的文件夹看它最近的上级）。
    static func volume(of folder: URL) -> URL? {
        var u = folder
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// 多留一点余量：2%，至少 50 MB。
    private static func spaceMargin(_ need: UInt64) -> UInt64 { max(need / 50, 50_000_000) }

    /// 文件夹所在磁盘的剩余空间（文件夹还没建时看它最近的上级）。
    static func freeSpace(at folder: URL) -> UInt64? {
        var u = folder
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        if let i = v.volumeAvailableCapacityForImportantUsage, i > 0 { return UInt64(i) }
        return v.volumeAvailableCapacity.map { UInt64($0) }
    }

    // MARK: 分组

    /// 选中的照片按会话分组（旧的在前）。只有一天 / 一场时，各种分法都只有一组。
    func importGroups(_ grouping: SessionGrouping) -> [ImportGroup] {
        func files(_ ids: [UInt32]) -> [CameraContentItem] {
            Array(allShots.filter { ids.contains($0.id) && grid.contains($0.id) }.flatMap(importFiles).compactMap { items[$0] }.reversed())
        }
        let selectedDays = days.filter { $0.shots.contains(where: grid.contains) }.reversed()
        switch grouping {
        case .single:
            let all = Array(selectedFiles().reversed())
            guard !all.isEmpty else { return [] }
            let day = all.map(Self.dayKey).filter { $0 != "unknown" }.min() ?? "unknown"
            let title = selectedDays.count == 1 ? selectedDays.first!.title : "\(selectedDays.count) 天"
            return [ImportGroup(id: "all", day: day, scene: nil, title: title, shotCount: grid.selected.count, files: all)]
        case .perDay:
            return selectedDays.map { d in
                ImportGroup(id: d.id, day: d.id, scene: nil, title: d.title,
                            shotCount: d.shots.filter(grid.contains).count, files: files(d.shots))
            }
        case .perScene:
            return selectedDays.flatMap { d in
                d.scenes.reversed().filter { $0.shots.contains(where: grid.contains) }.map { sc in
                    ImportGroup(id: d.scenes.count > 1 ? sc.id : d.id, day: d.id, scene: d.scenes.count > 1 ? sc.number : nil,
                                title: d.scenes.count > 1 ? "\(d.title) · \(Self.sceneTitle(sc))" : d.title,
                                shotCount: sc.shots.filter(grid.contains).count, files: files(sc.shots))
                }
            }
        }
    }

    /// 分组的会话名：按会话命名模板。
    static func sessionName(for group: ImportGroup, event: String?) -> String {
        NameTemplate.render(.session, day: group.day, event: event, scene: group.scene)
    }

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
        // 几个来源一起导：每个来源一个子文件夹（「Capture/α7 V/DSC00001.ARW」），文件名不改。
        let folders = sourceFolders()
        @MainActor func sub(_ dir: URL, _ item: CameraContentItem) -> URL {
            guard let name = sourceFolder(for: item, in: folders) else { return dir }
            return dir.appending(path: name, directoryHint: .isDirectory)
        }
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
        let sessionsFolder = plan.captureRoot
        // 视频单独一套：「视频保存位置/{M}.{D}-{事件}/」，不进 C1 会话、不交给 LrC。
        let videoRoot = plan.videoRoot
        let proxies = importProxies
        importTask = Task {
            var addresses: [String: String] = [:]
            var identities: [String: ImportSourceIdentity] = [:]
            var videoEvents: [FCPXMLWriter.Event] = []
            for job in jobs {
                for item in job.files {
                    guard let route = route(item.id) else { continue }
                    let path = await route.library.sourcePath(route.local)
                    let source = source(of: item.id)
                    let address: String
                    var identity = sourceIdentitySnapshot(source, slot: item.storageID >> 16)
                    if let card = route.library as? LocalCardLibrary {
                        fileCameraKeys[item.id] = nil
                        address = path ?? "来源路径未提供"
                        if item.kind == .video {
                            identity.cameraModel = await card.clipInfo(route.local)?.model
                        } else if let metadata = await card.exif(route.local) {
                            identity.cameraModel = metadata.camera
                            if let model = metadata.camera, let serial = metadata.serial,
                               let body = ImportSourceIdentity.bodyKey(model: model, serial: serial) {
                                identity.cameraID = body; identity.cameraSerial = serial
                                fileCameraKeys[item.id] = body
                            }
                        }
                    } else {
                        let host = source == Self.primarySource ? connectedHost : extra(source)?.camera?.host
                        address = [host.map { "Wi-Fi \($0)" } ?? "相机", "卡 \(item.storageID >> 16)", path ?? item.filename].joined(separator: " · ")
                    }
                    addresses["\(job.key)|\(item.id)"] = address
                    identities["\(job.key)|\(item.id)"] = identity
                }
            }
            guard journal.update(deliveryToken, { b in
                for i in b.files.indices {
                    b.files[i].sourceAddress = addresses[b.files[i].id]
                    b.files[i].sourceIdentity = identities[b.files[i].id] ?? b.files[i].sourceIdentity
                }
            }) else {
                errorMessage = journal.persistenceError
                progress = nil
                importTask = nil
                return
            }
            // 只导代理的视频：还没读到代理大小的先问一下，总进度才按代理算。
            if picked.contains(where: { importsProxyOnly($0) && proxySizes[$0.id] == nil }) {
                for item in picked where importsProxyOnly(item) && proxySizes[item.id] == nil {
                    if let r = route(item.id), let p = await r.library.proxy(of: r.local) { proxySizes[item.id] = p.size }
                }
                progress?.bytesTotal = picked.reduce(0) { $0 + transferSize($1) } * weight
            }
            var saved: [URL] = []
            var done: [ImportHistory.Entry] = []
            var proxyOnlyDone = 0
            // 可以从卡上删的：和卡上数据核对过；要求备份时备份也成功了；不是视频（删视频会让相机的数据库对不上）。
            var deletable: [UInt32] = []
            var consecutiveFailures = 0
            var mhlBackup: [MHLWriter.Entry] = []
            var reports: [URL] = []
            var captureOneFiles = captureOneFiles
            var opened: [String: ResumeSession] = [:]
            var stop = false
            var lightroomJobs: [String] = []
            var lightroomCollections: [String] = []
            var wokeLightroom = false
            // 卷号：这次导入的视频按机型各开一卷（之前分过卷的片段沿用原来的）。
            var videoItems: [(item: CameraContentItem, model: String)] = []
            var reportClipInfo = clipInfos
            for item in picked where item.kind == .video {
                var model = clipInfos[item.id]?.model ?? ""
                if model.isEmpty, let r = route(item.id), let info = await r.library.clipInfo(r.local) {
                    reportClipInfo[item.id] = info
                    model = info.model
                }
                videoItems.append((item, model.isEmpty ? (camera(of: item.id) ?? "未知") : model))
            }
            let rolls = RollStore.shared.assign(videoItems)
            let reportItems = Dictionary(uniqueKeysWithValues: picked.map { ($0.id, $0) })
            guard journal.update(deliveryToken, { batch in
                for i in batch.files.indices {
                    guard let raw = batch.files[i].id.split(separator: "|").last, let id = UInt32(raw),
                          let item = reportItems[id], item.kind == .video else { continue }
                    batch.files[i].roll = rolls[item.id]
                    if let info = reportClipInfo[item.id] {
                        batch.files[i].startTimecode = info.timecode.isEmpty ? nil : info.timecode
                        batch.files[i].endTimecode = info.endTimecode
                        batch.files[i].timecodeRate = info.timecodeRate.isEmpty ? info.formatFps : info.timecodeRate
                        batch.files[i].resolution = info.width > 0 && info.height > 0 ? "\(info.width)×\(info.height)" : nil
                        batch.files[i].frameRate = info.formatFps.isEmpty ? nil : info.formatFps
                        batch.files[i].codec = info.codec.isEmpty ? nil : info.codec
                        batch.files[i].durationSeconds = info.duration
                    }
                }
            }) else {
                errorMessage = journal.persistenceError; progress = nil; importTask = nil
                return
            }
            for r in Set(rolls.values).sorted() {
                log.add("卷号 \(r)：\(rolls.filter { $0.value == r }.count) 个片段")
            }

            for job in jobs {
                if Task.isCancelled || stop { break }
                // Plan the final folder on disk. Capture One opens only at handoff.
                var target: CaptureOneBridge.SessionTarget?
                var event = job.event
                if mode == .newSession, job.files.contains(where: { $0.kind != .video }), let session = job.session {
                    switch session {
                    case .new(let name):
                        rememberEvent(job.event)
                        let database = sessionsFolder.appending(path: name, directoryHint: .isDirectory).appending(path: name + ".cosessiondb")
                        target = .init(database: database)
                    case .existing(let file):
                        target = .init(database: file)
                        event = event ?? Self.eventName(of: file.deletingPathExtension().lastPathComponent)
                    case .resolved(let existing):
                        target = existing
                    }
                    if let target {
                        opened[job.key] = ResumeSession(captureOneTarget: target, name: target.name, event: event)
                        log.add("会话「\(target.name)」，Capture 文件夹：\(target.captureDir.path)")
                    }
                }
                let captureDir = target?.captureDir
                let layout = job.plan?.organization ?? organization
                let groupName: String? = job.folder ?? {
                    switch job.session {
                    case .new(let name): name
                    case .resolved(let target): target.name
                    case .existing(let url): url.deletingPathExtension().lastPathComponent
                    case nil: nil
                    }
                }()
                // 照片、视频分别套用整理规则，会话只记录它们属于同一次拍摄。
                @MainActor func videoFolder(_ item: CameraContentItem) -> URL {
                    layout.folder(for: item, root: videoRoot, sessionName: groupName,
                                  event: event, scene: job.scene, roll: rolls[item.id])
                }
                @MainActor func destDir(_ item: CameraContentItem) -> URL {
                    if item.kind == .video { return sub(videoFolder(item), item) }
                    let photos = layout.folder(for: item, root: root, sessionName: groupName,
                                               event: event, scene: job.scene)
                    return sub(captureDir ?? photos, item)
                }
                // 每个文件交给自己的来源；默认备份镜像实际目录，并按照片、视频分开。
                @MainActor func importer(for item: CameraContentItem) -> FileImporter? {
                    guard let lib = route(item.id)?.library else { return nil }
                    let backupDirectory = backupRoot.flatMap { backup in
                        layout.mirrorBackup ? ImportOrganization.mirroredBackup(root: backup, primaryFolder: destDir(item),
                            primaryRoot: item.kind == .video ? videoRoot : (captureDir == nil ? root : sessionsFolder),
                            video: item.kind == .video) : nil
                    }
                    return FileImporter(library: lib, root: root, camera: camera(of: item.id), backupRoot: nil,
                                        event: event, scene: job.scene, sourceFolder: sourceFolder(for: item, in: folders),
                                        backupSubfolder: item.kind == .video ? "视频" : nil,
                                        backupDirectory: backupDirectory, checkSource: deleteRequested)
                }
                @MainActor func assetRecord(url: URL, hash: UInt64, backup: URL?, main: URL,
                                            item: CameraContentItem, kind: ImportedAssetRecord.Kind,
                                            sourceCompared: Bool = false) -> ImportedAssetRecord {
                    let backupBase = requestedBackupRoot ?? URL(filePath: "/__minidit_backup__")
                    var planned: URL
                    if layout.mirrorBackup {
                        planned = ImportOrganization.mirroredBackup(root: backupBase, primaryFolder: destDir(item),
                            primaryRoot: item.kind == .video ? videoRoot : (captureDir == nil ? root : sessionsFolder), video: item.kind == .video)
                    } else {
                        let relative = NameTemplate.render(layout.backupTemplate, allowsFolders: false, day: Self.dayKey(item), event: event, scene: job.scene)
                        planned = backupBase.appending(path: relative, directoryHint: .isDirectory)
                        if item.kind == .video { planned.append(path: "视频") }
                        if let name = sourceFolder(for: item, in: folders) { planned.append(path: name) }
                    }
                    let mainDirectory = main.deletingLastPathComponent().path + "/"
                    let relativeAsset = url.path.hasPrefix(mainDirectory) ? String(url.path.dropFirst(mainDirectory.count)) : url.lastPathComponent
                    let target = backup ?? planned.appending(path: relativeAsset)
                    let prefix = backupBase.standardizedFileURL.path + "/"
                    let relative = target.path.hasPrefix(prefix) ? String(target.path.dropFirst(prefix.count))
                        : "\(deliveryToken.uuidString)/\(item.id)/\(relativeAsset)"
                    var copies = [ImportedCopyRecord(role: .working, path: url.path, verifiedAt: Date(),
                                                     evidence: sourceCompared ? .sourceComparison : .localReadback)]
                    if let backup { copies.append(.init(role: .backup, path: backup.path, verifiedAt: Date(), evidence: .localReadback)) }
                    return .init(kind: kind, size: FileImporter.fileSize(url) ?? 0, xxh64: XXH64.hex(hash),
                                 backupRelativePath: relative, copies: copies)
                }
                @MainActor func checkpoint(_ item: CameraContentItem, assets: [ImportedAssetRecord], proxyOnly: Bool = false,
                                           message: String? = nil) {
                    if !journal.update(deliveryToken, { batch in
                        if let i = batch.files.firstIndex(where: { $0.id == "\(job.key)|\(item.id)" }) {
                            batch.files[i].state = .saved
                            if batch.files[i].importedAt == nil { batch.files[i].importedAt = Date() }
                            batch.files[i].assets = assets
                            batch.files[i].proxyOnly = proxyOnly
                            batch.files[i].message = message
                        }
                    }) {
                        errorMessage = journal.persistenceError
                        importTask?.cancel()
                    }
                }
                // 导入到 LrC：收藏夹名就是这一组的名字；RAW 先导，同名的 JPG/HIF 叠到它下面。
                var collection: String?
                if mode == .lightroom, case .new(let name) = job.session {
                    collection = name
                    lightroomCollections.append(name)
                    rememberEvent(job.event)
                    opened[job.key] = ResumeSession(captureOneTarget: nil, name: name, event: event)
                }
                // RAW + JPG/HIF 成对时要叠在一起，插件得先有 RAW 才能叠。下载顺序不一定是 RAW 在前，
                // 所以 RAW 还没导完的 JPG/HIF 先留着，等 RAW 交出去后紧跟着交。
                @MainActor func pairKey(_ item: CameraContentItem) -> String {
                    let dir = destDir(item)
                    return dir.path + "/" + (item.filename as NSString).deletingPathExtension.lowercased()
                }
                let rawKeys = mode == .lightroom ? Set(job.files.filter { $0.kind == .raw }.map(pairKey)) : []
                var rawByKey: [String: URL] = [:]
                var waiting: [String: [URL]] = [:]
                var firstInCollection = true
                @MainActor func sendToLightroom(_ photos: [LightroomBridge.Photo]) {
                    do {
                        lightroomJobs.append(try LightroomBridge.enqueue(collection: collection, select: firstInCollection, photos: photos))
                        firstInCollection = false
                        if !wokeLightroom { LightroomBridge.wake(); wokeLightroom = true }
                    } catch {
                        updateDelivery("Lightroom Classic", message: "部分文件未能发送：" + error.localizedDescription, failed: true, id: deliveryToken)
                        log.add("交给 Lightroom Classic 失败 \(photos.map(\.url.lastPathComponent).joined(separator: "、"))：\(error.localizedDescription)")
                    }
                }
                // 写 MHL 校验清单用：第一份（这个会话 / 保存位置），备份盘（整次导入一份）。
                var mhlPrimary: [MHLWriter.Entry] = []
                var mhlVideo: [URL: [MHLWriter.Entry]] = [:]
                // 交给 Final Cut Pro 的片段，按视频文件夹分（一个文件夹一个事件）。
                var fcpClips: [URL: [FCPXMLWriter.Clip]] = [:]
                for item in job.files {
                    if Task.isCancelled || journal.persistenceError != nil { break }
                    progress?.current = "导入 \(item.filename)"
                    progress?.resumingFrom = nil
                    let dir = destDir(item)
                    let base = progress?.bytesDone ?? 0
                    let throttle = ProgressThrottle()
                    guard let importer = importer(for: item) else {
                        // 来源已经关掉 / 拔掉了。
                        progress?.failed.append(item.filename)
                        _ = journal.update(deliveryToken) { b in if let i = b.files.firstIndex(where: { $0.id == "\(job.key)|\(item.id)" }) { b.files[i].state = .failed; b.files[i].message = "来源已关闭" } }
                        log.add("导入失败 \(item.filename)：来源已关闭")
                        continue
                    }
                    // Wi-Fi「视频只导代理」：只下代理和 XML，原片留在卡上，不记进导入记录（还算没导）。
                    if importsProxyOnly(item) {
                        do {
                            var issues: [String] = []
                            guard let r = try await importer.importProxyOnly(localItem(item), into: dir, progress: { d in
                                guard throttle.allow() else { return }
                                Task { @MainActor in
                                    if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                                }
                            }, stage: { self.progress?.current = $0 }, issue: { issues.append($0) }) else {
                                log.add("只导代理：\(item.filename) 在相机上没有代理，跳过")
                                progress?.failed.append(item.filename + "（无代理）")
                                continue
                            }
                            progress?.bytesDone = base + transferSize(item) * weight
                            if r.proxy.alreadyThere { progress?.skipped += 1 } else { progress?.done += 1 }
                            if r.proxy.backup != nil { progress?.backedUp += 1 }
                            for c in [r.proxy] + (r.xml.map { [$0] } ?? []) {
                                mhlVideo[videoFolder(item), default: []].append(.init(url: c.url, xxh64: c.xxh64,
                                                                                      action: c.alreadyThere ? .verified : .original))
                                if let b = c.backup { mhlBackup.append(.init(url: b, xxh64: c.xxh64, action: .original)) }
                            }
                            let proxyAssets = ([r.proxy] + (r.xml.map { [$0] } ?? [])).map { c in
                                assetRecord(url: c.url, hash: c.xxh64, backup: c.backup,
                                            main: r.proxy.url.deletingLastPathComponent().deletingLastPathComponent().appending(path: item.filename),
                                            item: item, kind: c.url.pathExtension.lowercased() == "xml" ? .metadata : .proxy)
                            }
                            checkpoint(item, assets: proxyAssets, proxyOnly: true, message: issues.isEmpty ? nil : issues.joined(separator: "；"))
                            await backupImportedFile(batchID: deliveryToken, fileID: "\(job.key)|\(item.id)", run: plan.runBackups)
                            ProxyOnlyStore.shared.record(item, camera: camera(of: item.id), proxy: r.proxy.url)
                            proxyOnlyDone += 1
                            log.add("只导代理：\(item.filename) → \(r.proxy.url.path)")
                            consecutiveFailures = 0
                        } catch is CancellationError {
                            break
                        } catch {
                            _ = journal.update(deliveryToken) { b in
                                if let i = b.files.firstIndex(where: { $0.id == "\(job.key)|\(item.id)" }) { b.files[i].state = .failed; b.files[i].message = error.localizedDescription }
                            }
                            if error is PTPIPTransportError { progress?.failed.append(item.filename); lostDuringImport = true; stop = true; break }
                            log.add("只导代理失败 \(item.filename)：\(error.localizedDescription)")
                            progress?.failed.append(item.filename)
                        }
                        continue
                    }
                    do {
                        let r = try await importer.importItem(localItem(item), into: dir, progress: { d in
                            guard throttle.allow() else { return }
                            Task { @MainActor in
                                if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                            }
                        }, stage: { self.progress?.current = $0 }, skipped: { self.progress?.credit($0) },
                           resumed: { self.progress?.resumingFrom = $0; self.progress?.resumedFiles += 1 },
                           primarySaved: { url, hash, matchesSource in
                            checkpoint(item, assets: [assetRecord(url: url, hash: hash, backup: nil, main: url,
                                item: item, kind: .original, sourceCompared: matchesSource)],
                                message: item.kind == .video ? "附属文件整理尚未完成" : nil)
                            ImportHistory.shared.record([.init(item: item, url: url, xxh64: hash, backup: nil)], camera: camera(of: item.id))
                            if let project = job.appSession { recordSessionFiles([url], in: project) }
                           })
                        let actual = importer.weight(of: item, at: r.outcome.url)
                        let estimate = transferSize(item) * weight
                        // 先读、再赋值：`progress?.x = ... progress?.x ...` 会让左侧的独占访问
                        // 和右侧的 getter 冲突（Swift exclusivity，SIGABRT）。
                        if actual > estimate {
                            let total = progress?.bytesTotal ?? 0
                            progress?.bytesTotal = total + (actual - estimate)
                        }
                        let doneNow = progress?.bytesDone ?? 0
                        progress?.bytesDone = max(doneNow, base + actual)
                        let isVideo = item.kind == .video
                        switch r.outcome {
                        case .alreadyThere: progress?.skipped += 1
                        case .reused(let u): progress?.reused += 1; if !isVideo { saved.append(u) }
                        case .downloaded(let u): progress?.done += 1; if !isVideo { saved.append(u) }
                        }
                        if let target, !isVideo {
                            if case .alreadyThere = r.outcome {
                                if captureOneFiles[target] == nil { captureOneFiles[target] = [] }
                            } else {
                                captureOneFiles[target, default: []].append(r.outcome.url)
                            }
                        }
                        var backupURL: URL?
                        switch r.backup {
                        case .none: break
                        case .done(let u): progress?.backedUp += 1; backupURL = u
                        case .failed: progress?.backupFailed.append(item.filename)
                        }
                        if deleteRequested, r.matchesSource, item.kind != .video {
                            deletable.append(item.id)
                        }
                        done.append(.init(item: item, url: r.outcome.url, xxh64: r.xxh64, backup: backupURL))
                        var there = false
                        if case .alreadyThere = r.outcome { there = true }
                        let entry = MHLWriter.Entry(url: r.outcome.url, xxh64: r.xxh64, action: there ? .verified : .original)
                        if isVideo { mhlVideo[videoFolder(item), default: []].append(entry) } else { mhlPrimary.append(entry) }
                        if let backupURL { mhlBackup.append(.init(url: backupURL, xxh64: r.xxh64, action: .original)) }
                        var journalAssets = [assetRecord(url: r.outcome.url, hash: r.xxh64, backup: backupURL,
                                                         main: r.outcome.url, item: item, kind: .original, sourceCompared: r.matchesSource)]
                        var journalIssues: [String] = []
                        if case .failed(let error) = r.backup { journalIssues.append("备份未完成：" + error) }
                        checkpoint(item, assets: journalAssets, message: isVideo ? "附属文件整理尚未完成" : journalIssues.first)
                        if isVideo {
                            // XML 和代理跟着片段走，一样校验、备份、写进 MHL。
                            var proxy: URL?
                            for c in await importer.importSidecars(of: localItem(item), clip: r.outcome.url, backupClip: backupURL,
                                                                   proxies: proxies, stage: { self.progress?.current = $0 }, issue: { journalIssues.append($0) }) {
                                mhlVideo[videoFolder(item), default: []].append(.init(url: c.url, xxh64: c.xxh64,
                                                                                      action: c.alreadyThere ? .verified : .original))
                                if let b = c.backup { mhlBackup.append(.init(url: b, xxh64: c.xxh64, action: .original)) }
                                journalAssets.append(assetRecord(url: c.url, hash: c.xxh64, backup: c.backup,
                                    main: r.outcome.url, item: item, kind: c.url.pathExtension.lowercased() == "xml" ? .metadata : .proxy))
                                if c.url.deletingLastPathComponent().lastPathComponent == "Proxy" { proxy = c.url }
                            }
                            // 已经在电脑上的（之前导过）不再交给 FCP，免得事件里出现重复的片段。
                            if !there { fcpClips[videoFolder(item), default: []].append(.init(url: r.outcome.url, proxy: proxy, roll: rolls[item.id])) }
                        }
                        if Task.isCancelled, isVideo { journalIssues.append("附属文件整理已中断，部分文件可能尚未保存。") }
                        checkpoint(item, assets: journalAssets, message: journalIssues.isEmpty ? nil : journalIssues.joined(separator: "；"))
                        await backupImportedFile(batchID: deliveryToken, fileID: "\(job.key)|\(item.id)", run: plan.runBackups)
                        if let file = journal.batches.first(where: { $0.id == deliveryToken })?.files.first(where: { $0.id == "\(job.key)|\(item.id)" }),
                           let original = file.assets.first(where: { $0.kind == .original }),
                           let index = done.lastIndex(where: { $0.item.id == item.id }) {
                            let copies = original.copies.filter { $0.role == .backup && $0.verifiedAt != nil }
                            done[index].backup = copies.first.map { URL(filePath: $0.path) }
                            done[index].backups = copies.map { URL(filePath: $0.path) }
                        }
                        if mode == .lightroom, !isVideo {
                            let url = r.outcome.url
                            let key = pairKey(item)
                            if item.kind == .raw {
                                rawByKey[key] = url
                                let look = applyCreativeLook ? LightroomLooks.profile(for: url) : nil
                                sendToLightroom([.init(url: url, look: look)] + (waiting.removeValue(forKey: key) ?? []).map { .init(url: $0, stackWith: url) })
                            } else if let raw = rawByKey[key] {
                                sendToLightroom([.init(url: url, stackWith: raw)])
                            } else if rawKeys.contains(key) {
                                waiting[key, default: []].append(url)
                            } else {
                                sendToLightroom([.init(url: url)])
                            }
                        }
                    } catch is CancellationError {
                        break
                    } catch {
                        _ = journal.update(deliveryToken) { b in
                                if let i = b.files.firstIndex(where: { $0.id == "\(job.key)|\(item.id)" }) { b.files[i].state = .failed; b.files[i].message = error.localizedDescription }
                            }
                            if error is PTPIPTransportError { progress?.failed.append(item.filename); lostDuringImport = true; stop = true; break }
                        log.add("导入失败 \(item.filename)：\(error.localizedDescription)")
                        progress?.failed.append(item.filename)
                        // 连着几个文件都失败，多半是相机在关机 / 断开（关机前会先对所有请求回「不支持」），
                        // 当作中断处理：停下来，等重连后继续，而不是把剩下的全标成失败。
                        consecutiveFailures += 1
                        if consecutiveFailures >= 3 {
                            log.add("连续 \(consecutiveFailures) 个文件失败，当作中断处理")
                            lostDuringImport = true
                            stop = true
                            break
                        }
                        continue
                    }
                    consecutiveFailures = 0
                }
                // RAW 没导成（失败或取消）的 JPG/HIF：不叠了，单独交。
                for urls in waiting.values { sendToLightroom(urls.map { .init(url: $0) }) }
                // 视频文件夹各写一份 MHL（「10.21-Int/ascmhl/」）。
                for (folder, entries) in mhlVideo {
                    do { reports.append(try MHLWriter.append(root: folder, entries: entries)) }
                    catch { log.add("写视频校验清单失败：\(error.localizedDescription)") }
                }
                if plan.sendToFCP || plan.sendToResolve || plan.sendToPremiere, !fcpClips.isEmpty {
                    let base = videoRoot.standardizedFileURL.pathComponents
                    videoEvents += fcpClips.sorted { $0.key.path < $1.key.path }.map { folder, clips in
                        let parts = folder.standardizedFileURL.pathComponents
                        let rel = parts.starts(with: base) ? Array(parts.dropFirst(base.count)) : [folder.lastPathComponent]
                        return FCPXMLWriter.Event(name: rel.isEmpty ? folder.lastPathComponent : rel.joined(separator: " · "), clips: clips,
                            uid: FCPXMLWriter.stableUID((job.appSession?.uuidString ?? "") + "|" + folder.path))
                    }
                }
            }

            // 导入记录按机身分开记（读卡器的没有机身 ID）。
            for (cam, entries) in Dictionary(grouping: done, by: { camera(of: $0.item.id) }) {
                ImportHistory.shared.record(entries, camera: cam)
            }
            // 记进软件会话，之后在侧栏点开会话能看到。
            for job in jobs {
                guard let sid = job.appSession else { continue }
                let ids = Set(job.files.map(\.id))
                recordSessionFiles(done.filter { ids.contains($0.item.id) }.map(\.url), in: sid)
            }
            if let batch = journal.batches.first(where: { $0.id == deliveryToken }) {
                for target in batch.targets {
                    let entries = batch.files.flatMap(\.assets).compactMap { asset -> MHLWriter.Entry? in
                        guard let hash = asset.xxh64.flatMap({ UInt64($0, radix: 16) }),
                              let copy = asset.copies.last(where: { $0.role == .backup && $0.targetID == target.id && $0.verifiedAt != nil }) else { return nil }
                        return .init(url: URL(filePath: copy.path), xxh64: hash, action: .verified)
                    }
                    guard !entries.isEmpty else { continue }
                    do {
                        guard target.availability == .available else { throw BackupRepair.Failure.targetUnavailable }
                        reports.append(try MHLWriter.append(root: target.root, entries: entries))
                    } catch {
                        progress?.backupFailed.append(target.name + "（校验清单）")
                        log.add("写备份清单失败 \(target.name)：\(error.localizedDescription)")
                        _ = journal.update(deliveryToken) { b in
                            if b.backupReportErrors == nil { b.backupReportErrors = [:] }
                            b.backupReportErrors?[target.id.uuidString] = error.localizedDescription
                        }
                    }
                }
            }
            for r in reports { log.add("校验清单：\(r.path)") }
            // 没导完的文件里，已经传了一部分、留着续传的有多少。
            let finishedIDs = Set(done.map(\.item.id))
            var savedBytes: UInt64 = 0
            for job in jobs {
                var dir = opened[job.key]?.captureOneTarget?.captureDir
                if dir == nil, case .resolved(let target) = job.session { dir = target.captureDir }
                for f in job.files where !finishedIDs.contains(f.id) {
                    let layout = job.plan?.organization ?? organization
                    let planned = layout.folder(for: f, root: f.kind == .video ? videoRoot : root,
                                                sessionName: job.folder, event: job.event, scene: job.scene,
                                                roll: RollStore.shared.roll(of: f))
                    let folder = f.kind == .video ? planned : dir ?? planned
                    savedBytes += FileImporter.savedPartBytes(f, in: sub(folder, f))
                }
            }
            var deleted: Int?
            var deleteFailed = 0
            var cardReadOnly = false
            var cardFiles = picked.count
            if deleteRequested {
                // 只删读卡器来源上的；Wi-Fi 相机不能删。
                var n = 0
                for h in deletable {
                    if Task.isCancelled { break }
                    if wantsBackup {
                        guard plan.runBackups,
                              let batch = journal.batches.first(where: { $0.id == deliveryToken }), !batch.targets.isEmpty,
                              let file = batch.files.first(where: { $0.id.hasSuffix("|\(h)") }) else { continue }
                        let required = batch.targets.filter(\.required)
                        let needed = required.isEmpty ? batch.targets : required
                        guard file.assets.allSatisfy({ asset in needed.allSatisfy { asset.hasBackup(at: $0) && asset.error(for: $0) == nil } }) else { continue }
                    }
                    guard let r = route(h), let card = r.library as? LocalCardLibrary else { continue }
                    if (try? card.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false {
                        cardReadOnly = true
                        continue
                    }
                    progress?.current = "删除存储卡上的 \(items[h]?.filename ?? "")"
                    do { try await card.delete(r.local); n += 1 }
                    catch { deleteFailed += 1; log.add("删除失败 \(items[h]?.filename ?? "\(h)")：\(error.localizedDescription)") }
                }
                if cardReadOnly { log.add("存储卡是只读的，有文件没有删除") }
                log.add("从存储卡删除了 \(n) 个文件；\(picked.count - n) 个保留")
                deleted = n
                cardFiles = picked.filter { route($0.id)?.library is LocalCardLibrary }.count
            }
            updateBackupProgress(deliveryToken, final: true)
            let wasLost = lostDuringImport || (progress.map { !$0.failed.isEmpty } ?? false) && offline
            var summary = done.isEmpty && proxyOnlyDone > 0 ? "导入 \(proxyOnlyDone) 个片段的代理"
                : "导入 \(done.count) 个文件" + (proxyOnlyDone > 0 ? "、\(proxyOnlyDone) 个片段的代理" : "")
            if let p = progress, p.reused > 0 { summary += "，其中 \(p.reused) 个使用本地已有文件" }
            if let p = progress, p.skipped > 0 { summary += "，\(p.skipped) 个已存在于目标文件夹" }
            if let p = progress, !p.failed.isEmpty { summary += "，\(p.failed.count) 个失败" }
            if let deleted { summary += "，已从存储卡删除 \(deleted) 个" }
            if !importBackupProgress.isEmpty {
                summary += "，" + importBackupProgress.map { "\($0.target.name)：\($0.verified)/\($0.total) 个文件已校验" }.joined(separator: "；")
            } else {
                summary += "，未备份"
            }
            if Task.isCancelled { summary += "（已取消）" }
            lastBatch = saved
            let sessionNames = Set(captureOneFiles.keys.map(\.name)).sorted()
            let sessionText = sessionNames.isEmpty ? nil : sessionNames.joined(separator: "”“")
            let lightroomText = lightroomCollections.isEmpty ? nil : lightroomCollections.joined(separator: "”“")
            var openedText: String?
            var c1Failed = false
            if mode == .newSession {
                if let sessionText { summary += "，已存入会话“\(sessionText)”的 Capture 文件夹" }
                if !Task.isCancelled, !wasLost, !captureOneFiles.isEmpty {
                    let handoff = await finishCaptureOneSessions(captureOneFiles)
                    summary += handoff.message
                    pendingCaptureOneSessions = handoff.failed
                    c1Failed = !handoff.failed.isEmpty
                }
            } else if mode == .lightroom {
                if !lightroomJobs.isEmpty {
                    summary += "，已交由 Lightroom Classic 导入" + (lightroomText.map { "（收藏夹“\($0)”）" } ?? "")
                    watchLightroom(lightroomJobs)
                }
            } else if mode != .off && !saved.isEmpty {
                summary += await sendToCaptureOne(saved, inPlace: mode == .inPlace)
            } else if mode == .off && !Task.isCancelled, let folder = Self.commonFolder(done.map(\.url)) {
                openedText = openFolder(folder, in: openAfterImport)
                if let openedText { summary += openedText }
            }
            if mode != .newSession && mode != .off && mode != .lightroom && !saved.isEmpty { c1Failed = summary.contains("Capture One 导入失败") }
            lastSummary = summary
            if wasLost {
                interrupted = Interrupted(done: done.count, total: picked.count, sessions: mode.namesGroups ? opened : [:],
                                          grouping: grouping, savedBytes: savedBytes,
                                          jobs: jobs.compactMap { original in
                                              var job = original
                                              job.files.removeAll { finishedIDs.contains($0.id) }
                                              if let resumed = opened[job.key] { job.session = resumed.session }
                                              return job.files.isEmpty ? nil : job
                                          }, captureOneFiles: captureOneFiles)
            } else {
                lastResult = ImportResult(files: done.count, reused: progress?.reused ?? 0, failed: progress?.failed.count ?? 0,
                                          session: mode == .newSession ? sessionText : nil,
                                          c1Failed: c1Failed, cancelled: Task.isCancelled,
                                          backedUp: backupRoot == nil ? nil : progress?.backedUp ?? 0,
                                          backupFailed: progress?.backupFailed.count ?? 0,
                                          deleted: deleted, keptOnCard: deleted.map { cardFiles - $0 } ?? 0,
                                          deleteFailed: deleteFailed, cardReadOnly: cardReadOnly,
                                          resumed: progress?.resumedFiles ?? 0, savedBytes: savedBytes, reports: reports,
                                          lightroom: mode == .lightroom ? lightroomText : nil, opened: openedText,
                                          proxyOnly: proxyOnlyDone, hasWiFiSource: hasWiFiSource)
            }
            log.add("导入结束：\(summary)")
            // 全部文件都导好的拍摄取消选中。
            let doneIDs = Set(done.map(\.item.id))
            grid.remove(pickedShots.filter { id in shots[id].map { importFiles(of: $0).allSatisfy(doneIDs.contains) } ?? false })
            var videoDeliveries: [VideoDelivery] = []
            do { videoDeliveries = try await makeVideoDeliveries(events: videoEvents, batchID: deliveryToken, plan: plan) }
            catch { log.add("保存后期发送计划失败：" + error.localizedDescription); errorMessage = error.localizedDescription }
            if Task.isCancelled {
                videoDeliveries = videoDeliveries.map { var record = $0; record.state = .failed; record.message = "导入已取消，未向后期软件发送；可使用已保存的文件重试。"; return record }
            }
            let finalized = journal.update(deliveryToken) { batch in
                batch.videoDeliveries = videoDeliveries.isEmpty ? nil : videoDeliveries
                for record in videoDeliveries { batch.delivery[record.software.name] = record.message }
                batch.finishedAt = Date()
                batch.state = wasLost || journal.persistenceError != nil ? .interrupted : Task.isCancelled ? .cancelled : .completed
                batch.reports = reports.map(\.path)
                if mode == .newSession, !captureOneFiles.isEmpty {
                    if c1Failed { batch.delivery["Capture One"] = "部分会话未能打开。照片已保存至本地。" }
                    else if wasLost || Task.isCancelled { batch.delivery["Capture One"] = "照片已保存至本地，等待整批下载完成。" }
                    else { batch.delivery["Capture One"] = "下载完成后已打开会话。" }
                } else if mode != .off && mode != .lightroom && !saved.isEmpty {
                    batch.delivery["Capture One"] = c1Failed ? "软件接收失败。文件已保存在本地。" : "文件已发送，请在 Capture One 中确认接收。"
                }
                for i in batch.files.indices where batch.files[i].state == .pending {
                    batch.files[i].state = .failed
                    batch.files[i].message = batch.files[i].message ?? (wasLost ? "来源连接中断，文件未保存" : Task.isCancelled ? "导入已取消，文件未保存" : "文件未完成导入")
                }
            }
            if let error = journal.persistenceError { errorMessage = error }
            updateBackupProgress(deliveryToken)
            if lastResult != nil { lastResult?.backupTargets = importBackupProgress }
            progress = nil
            refreshCopies()
            rebuild()
            importTask = nil
            if finalized { queueVideoDeliveries(batchID: deliveryToken) }
            if autoRunning { autoImportFinished() }
            // 删了卡上的文件：重新列一遍卡。
            if let deleted, deleted > 0 { await loadAll(restoring: selectedKeys(), days: shownDays) }
        }
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

    /// 用选好的软件打开下载的文件夹，返回接在导入结果后面的说明。Bridge 和 DxO PhotoLab 打开文件夹时会定位到它。
    func openFolder(_ folder: URL, in app: FolderApp) -> String? {
        switch app {
        case .none:
            return nil
        case .finder:
            NSWorkspace.shared.open(folder)
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

    /// 导入完以后看 LrC 插件的回执，更新「已添加 n/N」。LrC 没开时它会被打开，可能要等一会儿。
    func watchLightroom(_ names: [String]) {
        lightroomWatch?.cancel()
        let deliveryToken = deliveryID
        let total = names.count
        lightroomStatus = "等待 Lightroom Classic 添加 \(total) 个文件…"
        lightroomWatch = Task {
            var remaining = Set(names)
            var sum = LightroomBridge.Results()
            var lastProgress = Date()
            var lastWake = Date()
            while !remaining.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let r = LightroomBridge.collect(Array(remaining))
                if !r.done.isEmpty { lastProgress = Date() }
                remaining.subtract(r.done)
                sum.added += r.added; sum.skipped += r.skipped; sum.failed += r.failed; sum.failures += r.failures
                let done = total - remaining.count
                if remaining.isEmpty { break }
                let fresh = LightroomBridge.heartbeat()?.isFresh ?? false
                // LrC 是被唤醒链接打开的话，启动途中那次唤醒会丢，插件要等下一次才开始干活：插件没在跑就隔 10 秒再唤醒一次。
                if !fresh, Date().timeIntervalSince(lastWake) > 10 {
                    LightroomBridge.wake()
                    lastWake = Date()
                }
                if !fresh, Date().timeIntervalSince(lastProgress) > 45 {
                    lightroomStatus = "Lightroom Classic 无响应（已添加 \(done)/\(total)）。请打开 Lightroom Classic 并确认 MiniDiT 插件已启用，其余照片将继续添加"
                } else {
                    lightroomStatus = "Lightroom Classic 已添加 \(done)/\(total)"
                }
            }
            guard !Task.isCancelled else { return }
            var s = "Lightroom Classic 已添加 \(sum.added + sum.skipped) 个文件"
            if sum.skipped > 0 { s += "（其中 \(sum.skipped) 个已在目录中）" }
            if sum.failed > 0 {
                s += "，\(sum.failed) 个失败"
                log.add("Lightroom Classic 添加失败：" + sum.failures.joined(separator: "；"))
            }
            lightroomStatus = s
            updateDelivery("Lightroom Classic", message: s, failed: sum.failed > 0, id: deliveryToken)
            log.add(s)
        }
    }

    func dismissResult() { lastResult = nil }
    /// 放弃继续导入：没导完的照片仍然选中，可以重新导入。
    func dismissInterrupted() { interrupted = nil }

    func retryCaptureOne() {
        guard !retryingCaptureOne, progress == nil else { return }
        retryingCaptureOne = true
        Task {
            defer { retryingCaptureOne = false }
            if !pendingCaptureOneSessions.isEmpty {
                let handoff = await finishCaptureOneSessions(pendingCaptureOneSessions)
                pendingCaptureOneSessions = handoff.failed
                lastSummary = "Capture One" + handoff.message
                lastResult?.c1Failed = !handoff.failed.isEmpty
                updateDelivery("Capture One", message: lastSummary ?? "", failed: !handoff.failed.isEmpty, id: deliveryID)
            } else {
                let r = await sendToCaptureOne(lastBatch, inPlace: captureOneMode == .inPlace)
                lastSummary = "重新导入 \(lastBatch.count) 个文件" + r
                lastResult?.c1Failed = r.contains("失败")
            }
        }
    }

    private func finishCaptureOneSessions(_ files: [CaptureOneBridge.SessionTarget: [URL]]) async
        -> (message: String, failed: [CaptureOneBridge.SessionTarget: [URL]]) {
        var message = ""
        var failed: [CaptureOneBridge.SessionTarget: [URL]] = [:]
        for target in files.keys.sorted(by: { $0.database.path < $1.database.path }) {
            let photos = files[target, default: []]
            progress?.current = "正在打开 Capture One 会话…"
            do {
                try await CaptureOneBridge.openCompletedSession(target)
                message += "，已打开 Capture One 会话“\(target.name)”"
                if applyCreativeLook, !photos.isEmpty {
                    progress?.current = "正在套用 Capture One 创意外观…"
                    if let look = await applyLooks(photos, target: target) { message += look }
                }
                if let ratings = await applyRatings(photos, target: target) { message += ratings }
            } catch {
                failed[target] = photos
                message += "，Capture One 会话“\(target.name)”未打开"
                log.add("打开 Capture One 会话失败：\(error.localizedDescription)")
                if !Task.isCancelled { errorMessage = "照片已保存至 \(target.captureDir.path)。\n\(error.localizedDescription)" }
            }
        }
        refreshCaptureOne()
        return (message, failed)
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
            let target = captureOneDocument.map { "\($0.kind)“\($0.name)”" } ?? "Capture One"
            log.add("已交给 \(target) 导入 \(urls.count) 个文件")
            return "，已交由 \(target) 导入"
        } catch {
            log.add("Capture One 导入失败：\(error.localizedDescription)")
            errorMessage = "文件已下载至文件夹，但交由 Capture One 导入失败：\(error.localizedDescription)"
            return "，Capture One 导入失败"
        }
    }
}

extension AppModel {
    /// 按相机里打的星级给 C1 会话里的照片设星级（从下载好的文件开头读）。C1 还没建好变体的隔一会儿再试。
    func applyRatings(_ saved: [URL], target: CaptureOneBridge.SessionTarget) async -> String? {
        var applied = 0
        var pairs: [String: Int] = [:]
        for u in saved {
            guard let r = PhotoRating.read(fileAt: u), r > 0 else { continue }
            let n = u.deletingPathExtension().lastPathComponent
            pairs[n] = max(pairs[n] ?? 0, r)
        }
        var todo = pairs.map { (variant: $0.key, rating: $0.value) }
        for attempt in 0..<6 where !todo.isEmpty {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
            let done = CaptureOneBridge.applyRatings(session: target.name, collection: target.captureDir.lastPathComponent, todo)
            applied += done.count
            todo = todo.filter { !done.contains($0.variant) }
        }
        if !todo.isEmpty { log.add("星级：\(todo.count) 张在 C1 里没找到") }
        guard applied > 0 else { return nil }
        log.add("星级：已按相机里的星级设置 \(applied) 张")
        return "，已设置星级 \(applied) 张"
    }

    /// 按创意外观设 C1 的 ICC 配置文件和曲线（只看 RAW：HIF / JPG 已经带着相机的外观）。
    /// C1 刚收到文件时可能还没建好变体，找不到的隔一会儿再试几次。返回加在导入结果后面的说明。
    func applyLooks(_ saved: [URL], target: CaptureOneBridge.SessionTarget) async -> String? {
        let raws = Set(saved.filter { ["ARW", "SR2", "SRF"].contains($0.pathExtension.uppercased()) })
        guard !raws.isEmpty else { return nil }
        var applied = 0, unknown = 0, missingProfiles = Set<String>(), notFound = 0
        let mine = raws.sorted { $0.path < $1.path }
        var pairs: [(file: URL, look: String)] = []
        for u in mine {
            if let c = CreativeLook.code(ofRaw: u) { pairs.append((u, c)) }
            else { unknown += 1; log.add("创意外观：\(u.lastPathComponent) 读到「\(CreativeLook.raw(u) ?? "无")」，不认识，保持原样") }
        }
        for attempt in 0..<6 where !pairs.isEmpty {
            if attempt > 0 {
                do { try await Task.sleep(for: .seconds(1.5)) } catch { break }
            }
            let r = CaptureOneBridge.applyLooks(session: target.name, collection: target.captureDir.lastPathComponent, pairs)
            if let error = r.scriptError {
                log.add("创意外观：\(error)")
                pairs.removeAll()
                break
            }
            applied += r.applied
            missingProfiles.formUnion(r.noProfile)
            for failure in r.failures { log.add("创意外观：\(failure)") }
            if let error = r.refreshError { log.add("创意外观：已套用，Capture One 界面刷新失败：\(error)") }
            pairs = pairs.filter { r.notFound.contains($0.file.path) }
        }
        notFound += pairs.count
        log.add("创意外观：已确认 \(applied) 张" + (missingProfiles.isEmpty ? "" : "，未安装 \(missingProfiles.sorted().joined(separator: "、"))")
                + (unknown > 0 ? "，\(unknown) 张不认识" : "") + (notFound > 0 ? "，\(notFound) 张在 C1 里没找到" : ""))
        let unapplied = max(0, raws.count - applied)
        var summary = applied > 0 ? "，Capture One 已套用创意外观 \(applied) 张" : ""
        if unapplied > 0 { summary += "，\(unapplied) 张 RAW 未套用创意外观" }
        if !missingProfiles.isEmpty { summary += "（缺少：\(missingProfiles.sorted().joined(separator: "、"))）" }
        return summary
    }
}

/// 导入进度回调从后台线程每 8 MB 来一次。界面最多每 100 ms 更新一次，
/// 避免每个数据块都起一个 MainActor Task、触发一次整条进度栏重绘。
/// 每个文件结束时仍会精确写一次最终值。
private final class ProgressThrottle: @unchecked Sendable {
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
