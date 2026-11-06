import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {

    // MARK: 导入

    func refreshCaptureOne() {
        captureOneDocument = CaptureOneBridge.currentDocument()
    }

    /// 点「导入」：没有备份盘、空间不够先提醒；新建会话模式先问会话名，其他模式直接开始。
    /// 界面上点按钮时用默认参数；提醒里点「继续」时跳过已经确认过的检查。
    func beginImport(checkBackup: Bool = true, checkSpace: Bool = true, resume: [String: ResumeSession] = [:]) {
        guard progress == nil, !grid.selected.isEmpty else { return }
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
        if captureOneMode == .lightroom {
            let st = LightroomBridge.status()
            guard st.canImport else { lightroomPrompt = st; return }
            sessionRequest = SessionRequest(existing: [], resume: resume)
        } else if captureOneMode == .newSession {
            refreshCaptureOne()
            sessionRequest = SessionRequest(existing: Array(CaptureOneBridge.sessions(in: sessionsFolder).prefix(15)),
                                            resume: resume)
        } else {
            startImport(session: nil)
        }
    }

    /// 两块盘够不够放这次要导的文件。本地已经有的（上次导过、还在）不算。
    func spaceShortage() -> SpaceProblem? {
        let files = selectedFiles()
        let history = ImportHistory.shared
        let missing = files.filter { history.localFile($0, camera: camera(of: $0.id)) == nil }
        let photoNeed = missing.filter { $0.kind != .video }.reduce(0) { $0 + $1.size }
        let videoNeed = missing.filter { $0.kind == .video }.reduce(0) { $0 + $1.size }
        let primary = captureOneMode == .newSession ? sessionsFolder : destination
        // 照片和视频可能在不同的盘上；在同一块盘上就合起来算。
        let sameDisk = Self.volume(of: primary) == Self.volume(of: videoDestination)
        for (folder, need) in sameDisk ? [(primary, photoNeed + videoNeed)] : [(primary, photoNeed), (videoDestination, videoNeed)] {
            if need > 0, let free = Self.freeSpace(at: folder), free < need + Self.spaceMargin(need) {
                return SpaceProblem(isBackup: false, folder: folder, needed: need, available: free)
            }
        }
        if backupEnabled, backupAvailable, !noBackupThisTime, let backup = backupFolder {
            let need = files.filter { history.backupFile($0, camera: camera(of: $0.id)) == nil }.reduce(0) { $0 + $1.size }
            if need > 0, let free = Self.freeSpace(at: backup), free < need + Self.spaceMargin(need) {
                return SpaceProblem(isBackup: true, folder: backup, needed: need, available: free)
            }
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

    /// 不分会话的导入（下载到文件夹，或加入一个已有会话）。
    func startImport(session: SessionChoice?) {
        startImport(jobs: [ImportJob(key: "all", files: Array(selectedFiles().reversed()), session: session)],
                    grouping: .single)
    }

    func startImport(jobs: [ImportJob], grouping: SessionGrouping) {
        sessionRequest = nil
        interrupted = nil
        lastResult = nil
        lostDuringImport = false
        guard !openSources.isEmpty, progress == nil else { return }
        let jobs = jobs.filter { !$0.files.isEmpty }
        let picked = jobs.flatMap(\.files)  // 旧的先导
        guard !picked.isEmpty else { return }
        let pickedShots = grid.selected
        let root = destination
        let mode = captureOneMode
        // 几个来源一起导：每个来源一个子文件夹（「Capture/α7 V/DSC00001.ARW」），文件名不改。
        let folders = sourceFolders()
        @MainActor func sub(_ dir: URL, _ item: CameraContentItem) -> URL {
            guard let name = sourceFolder(for: item, in: folders) else { return dir }
            return dir.appending(path: name, directoryHint: .isDirectory)
        }
        let backupRoot = backupEnabled && backupAvailable && !noBackupThisTime ? backupFolder : nil
        noBackupThisTime = false
        let wantsBackup = backupEnabled
        let deleteRequested = willDeleteFromSource
        let weight: UInt64 = backupRoot == nil ? 1 : 2
        progress = ImportProgress(total: picked.count, bytesTotal: picked.reduce(0) { $0 + transferSize($1) } * weight)
        lastSummary = nil
        log.add("开始导入 \(picked.count) 个文件到 \(root.path)，Capture One：\(mode.title)，"
                + (backupRoot.map { "备份到 \($0.path)" } ?? "没有备份")
                + (jobs.count > 1 ? "，分成 \(jobs.count) 个会话" : ""))
        let sessionsFolder = self.sessionsFolder
        // 视频单独一套：「视频保存位置/{M}.{D}-{事件}/」，不进 C1 会话、不交给 LrC。
        let videoRoot = videoDestination
        let proxies = importProxies
        importTask = Task {
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
            var sessionNames: [String] = []
            var opened: [String: ResumeSession] = [:]
            var stop = false
            var lightroomJobs: [String] = []
            var lightroomCollections: [String] = []
            var wokeLightroom = false

            for job in jobs {
                if Task.isCancelled || stop { break }
                // 新建 / 打开会话，文件直接下载到它的 Capture 文件夹（C1 会自动显示，不用再导入）。
                var captureDir: URL?
                var sessionName = ""
                var event = job.event
                if mode == .newSession, let session = job.session {
                    status = "正在准备 Capture One 会话…"
                    do {
                        switch session {
                        case .new(let name):
                            sessionName = name
                            rememberEvent(job.event)
                            captureDir = try await CaptureOneBridge.createSession(name: name, in: sessionsFolder)
                        case .existing(let file):
                            sessionName = file.deletingPathExtension().lastPathComponent
                            event = event ?? Self.eventName(of: sessionName)
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
                        errorMessage = "Capture One 新建会话失败：\(error.localizedDescription)\n照片将先存储至 \(dir.path)。"
                    }
                    status = ""
                    refreshCaptureOne()
                }
                if let captureDir {
                    opened[job.key] = ResumeSession(captureDir: captureDir, name: sessionName, event: event)
                    sessionNames.append(sessionName)
                }
                // 每个文件交给它自己的来源去下载 / 复制。
                @MainActor func importer(for item: CameraContentItem) -> FileImporter? {
                    guard let lib = route(item.id)?.library else { return nil }
                    return FileImporter(library: lib, root: root, camera: camera(of: item.id), backupRoot: backupRoot,
                                        event: event, scene: job.scene, sourceFolder: sourceFolder(for: item, in: folders),
                                        backupSubfolder: item.kind == .video ? "视频" : nil,
                                        checkSource: deleteRequested)
                }
                // 视频的文件夹（不含按来源分的那层），MHL 写在这里。
                @MainActor func videoFolder(_ item: CameraContentItem) -> URL {
                    FileImporter.videoFolder(for: item, root: videoRoot, event: event, scene: job.scene)
                }
                @MainActor func destDir(_ item: CameraContentItem) -> URL {
                    if item.kind == .video { return sub(videoFolder(item), item) }
                    return sub(captureDir ?? FileImporter.folder(for: item, root: root, event: event, scene: job.scene), item)
                }
                // 导入到 LrC：收藏夹名就是这一组的名字；RAW 先导，同名的 JPG/HIF 叠到它下面。
                var collection: String?
                if mode == .lightroom, case .new(let name) = job.session {
                    collection = name
                    lightroomCollections.append(name)
                    rememberEvent(job.event)
                    opened[job.key] = ResumeSession(captureDir: nil, name: name, event: event)
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
                        log.add("交给 Lightroom Classic 失败 \(photos.map(\.url.lastPathComponent).joined(separator: "、"))：\(error.localizedDescription)")
                    }
                }
                // 写 MHL 校验清单用：第一份（这个会话 / 保存位置），备份盘（整次导入一份）。
                var mhlPrimary: [MHLWriter.Entry] = []
                var mhlVideo: [URL: [MHLWriter.Entry]] = [:]
                // 交给 Final Cut Pro 的片段，按视频文件夹分（一个文件夹一个事件）。
                var fcpClips: [URL: [FCPXMLWriter.Clip]] = [:]
                for item in job.files {
                    if Task.isCancelled { break }
                    progress?.current = "导入 \(item.filename)"
                    progress?.resumingFrom = nil
                    let dir = destDir(item)
                    let base = progress?.bytesDone ?? 0
                    guard let importer = importer(for: item) else {
                        // 来源已经关掉 / 拔掉了。
                        progress?.failed.append(item.filename)
                        log.add("导入失败 \(item.filename)：来源已关闭")
                        continue
                    }
                    // Wi-Fi「视频只导代理」：只下代理和 XML，原片留在卡上，不记进导入记录（还算没导）。
                    if importsProxyOnly(item) {
                        do {
                            guard let r = try await importer.importProxyOnly(localItem(item), into: dir, progress: { d in
                                Task { @MainActor in
                                    if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                                }
                            }, stage: { self.progress?.current = $0 }) else {
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
                            ProxyOnlyStore.shared.record(item, camera: camera(of: item.id), proxy: r.proxy.url)
                            proxyOnlyDone += 1
                            log.add("只导代理：\(item.filename) → \(r.proxy.url.path)")
                            consecutiveFailures = 0
                        } catch is CancellationError {
                            break
                        } catch {
                            if error is PTPIPTransportError { progress?.failed.append(item.filename); lostDuringImport = true; stop = true; break }
                            log.add("只导代理失败 \(item.filename)：\(error.localizedDescription)")
                            progress?.failed.append(item.filename)
                        }
                        continue
                    }
                    do {
                        let r = try await importer.importItem(localItem(item), into: dir, progress: { d in
                            Task { @MainActor in
                                if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                            }
                        }, stage: { self.progress?.current = $0 }, skipped: { self.progress?.credit($0) },
                           resumed: { self.progress?.resumingFrom = $0; self.progress?.resumedFiles += 1 })
                        progress?.bytesDone = base + importer.weight(of: item)
                        let isVideo = item.kind == .video
                        switch r.outcome {
                        case .alreadyThere: progress?.skipped += 1
                        case .reused(let u): progress?.reused += 1; if !isVideo { saved.append(u) }
                        case .downloaded(let u): progress?.done += 1; if !isVideo { saved.append(u) }
                        }
                        var backupURL: URL?
                        switch r.backup {
                        case .none: break
                        case .done(let u): progress?.backedUp += 1; backupURL = u
                        case .failed: progress?.backupFailed.append(item.filename)
                        }
                        if deleteRequested, r.matchesSource, item.kind != .video, !wantsBackup || backupURL != nil {
                            deletable.append(item.id)
                        }
                        done.append(.init(item: item, url: r.outcome.url, xxh64: r.xxh64, backup: backupURL))
                        var there = false
                        if case .alreadyThere = r.outcome { there = true }
                        let entry = MHLWriter.Entry(url: r.outcome.url, xxh64: r.xxh64, action: there ? .verified : .original)
                        if isVideo { mhlVideo[videoFolder(item), default: []].append(entry) } else { mhlPrimary.append(entry) }
                        if let backupURL { mhlBackup.append(.init(url: backupURL, xxh64: r.xxh64, action: .original)) }
                        if isVideo {
                            // XML 和代理跟着片段走，一样校验、备份、写进 MHL。
                            var proxy: URL?
                            for c in await importer.importSidecars(of: localItem(item), clip: r.outcome.url, backupClip: backupURL,
                                                                   proxies: proxies, stage: { self.progress?.current = $0 }) {
                                mhlVideo[videoFolder(item), default: []].append(.init(url: c.url, xxh64: c.xxh64,
                                                                                      action: c.alreadyThere ? .verified : .original))
                                if let b = c.backup { mhlBackup.append(.init(url: b, xxh64: c.xxh64, action: .original)) }
                                if c.url.deletingLastPathComponent().lastPathComponent == "Proxy" { proxy = c.url }
                            }
                            // 已经在电脑上的（之前导过）不再交给 FCP，免得事件里出现重复的片段。
                            if !there { fcpClips[videoFolder(item), default: []].append(.init(url: r.outcome.url, proxy: proxy)) }
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
                // 交给 Final Cut Pro / DaVinci Resolve：事件（媒体夹）名用视频文件夹相对保存位置的路径（「11.04-公园」「11.04-公园 · a7 V」）。
                if sendToFCP || sendToResolve, !fcpClips.isEmpty {
                    let base = videoRoot.standardizedFileURL.pathComponents
                    let events = fcpClips.sorted { $0.key.path < $1.key.path }.map { folder, clips in
                        let parts = folder.standardizedFileURL.pathComponents
                        let rel = parts.starts(with: base) ? Array(parts.dropFirst(base.count)) : [folder.lastPathComponent]
                        return FCPXMLWriter.Event(name: rel.isEmpty ? folder.lastPathComponent : rel.joined(separator: " · "), clips: clips)
                    }
                    if sendToFCP {
                        do {
                            if let u = try FCPXMLWriter.send(events, logProcessing: fcpLogProcessing) { log.add("交给 Final Cut Pro：\(fcpClips.values.joined().count) 个片段，\(u.path)") }
                            else { log.add("未找到 Final Cut Pro，未交给 FCP") }
                        } catch { log.add("写 FCPXML 失败：\(error.localizedDescription)") }
                    }
                    if sendToResolve {
                        // 不挡着导入收尾：Resolve 可能要先启动。
                        Task {
                            do {
                                let r = try await ResolveBridge.send(events, setColorSpace: self.resolveColorSpace)
                                self.log.add("加入 DaVinci Resolve 项目“\(r.project)”：导入 \(r.imported) 个片段，链接代理 \(r.proxies) 个"
                                             + (r.colored > 0 ? "，设置输入色彩空间 \(r.colored) 个" : "")
                                             + (r.skipped > 0 ? "，\(r.skipped) 个已在媒体夹中" : ""))
                                if r.unmanaged > 0 {
                                    self.log.add("DaVinci Resolve 项目“\(r.project)”未开启色彩管理，\(r.unmanaged) 个 Log / HLG 片段未设置输入色彩空间")
                                    Notifier.shared.post(id: "resolve", title: "已加入 DaVinci Resolve，未设置色彩空间",
                                                         body: "项目“\(r.project)”未开启色彩管理，\(r.unmanaged) 个 Log / HLG 片段需在 Resolve 中手动设置。", info: [:])
                                }
                            } catch {
                                self.log.add("加入 DaVinci Resolve 失败：\(error.localizedDescription)")
                                Notifier.shared.post(id: "resolve", title: "未能加入 DaVinci Resolve", body: error.localizedDescription, info: [:])
                            }
                        }
                    }
                }
                // 导入报告：ASC MHL 清单。会话模式写在 Capture 文件夹里（C1 自己的 CaptureOne/ 子文件夹不算），其他模式写在保存位置根目录。
                if !mhlPrimary.isEmpty {
                    do {
                        reports.append(try MHLWriter.append(root: captureDir ?? root, entries: mhlPrimary,
                                                            ignore: captureDir != nil ? ["CaptureOne", "CaptureOne/"] : []))
                    } catch { log.add("写校验清单失败：\(error.localizedDescription)") }
                }
            }
            // 导入记录按机身分开记（读卡器的没有机身 ID）。
            for (cam, entries) in Dictionary(grouping: done, by: { camera(of: $0.item.id) }) {
                ImportHistory.shared.record(entries, camera: cam)
            }
            if let backupRoot, !mhlBackup.isEmpty {
                do { reports.append(try MHLWriter.append(root: backupRoot, entries: mhlBackup)) }
                catch { log.add("写备份盘校验清单失败：\(error.localizedDescription)") }
            }
            for r in reports { log.add("校验清单：\(r.path)") }
            // 没导完的文件里，已经传了一部分、留着续传的有多少。
            let finishedIDs = Set(done.map(\.item.id))
            var savedBytes: UInt64 = 0
            for job in jobs {
                var dir = opened[job.key]?.captureDir
                if dir == nil, case .resolved(let d, _) = job.session { dir = d }
                for f in job.files where !finishedIDs.contains(f.id) {
                    let folder = f.kind == .video ? FileImporter.videoFolder(for: f, root: videoRoot, event: job.event, scene: job.scene)
                        : dir ?? FileImporter.folder(for: f, root: root, event: job.event, scene: job.scene)
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
            let wasLost = lostDuringImport || (progress.map { !$0.failed.isEmpty } ?? false) && offline
            var summary = done.isEmpty && proxyOnlyDone > 0 ? "导入 \(proxyOnlyDone) 个片段的代理"
                : "导入 \(done.count) 个文件" + (proxyOnlyDone > 0 ? "、\(proxyOnlyDone) 个片段的代理" : "")
            if let p = progress, p.reused > 0 { summary += "，其中 \(p.reused) 个使用本地已有文件" }
            if let p = progress, p.skipped > 0 { summary += "，\(p.skipped) 个已存在于目标文件夹" }
            if let p = progress, !p.failed.isEmpty { summary += "，\(p.failed.count) 个失败" }
            if let deleted { summary += "，已从存储卡删除 \(deleted) 个" }
            if let p = progress, backupRoot != nil {
                summary += "，备份 \(p.backedUp) 个" + (p.backupFailed.isEmpty ? "" : "（\(p.backupFailed.count) 个备份失败）")
            } else {
                summary += "，未备份"
            }
            if Task.isCancelled { summary += "（已取消）" }
            lastBatch = saved
            let sessionText = sessionNames.isEmpty ? nil : sessionNames.joined(separator: "”“")
            let lightroomText = lightroomCollections.isEmpty ? nil : lightroomCollections.joined(separator: "”“")
            var openedText: String?
            if mode == .newSession {
                if let sessionText { summary += "，已存入会话“\(sessionText)”" }
                if !saved.isEmpty { for n in Set(sessionNames) { CaptureOneBridge.refreshCapture(session: n) } }
                if applyCreativeLook, !saved.isEmpty, let t = await applyLooks(saved, sessions: Array(Set(sessionNames))) { summary += t }
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
            var c1Failed = false
            if mode != .newSession && mode != .off && mode != .lightroom && !saved.isEmpty { c1Failed = summary.contains("Capture One 导入失败") }
            lastSummary = summary
            if wasLost {
                interrupted = Interrupted(done: done.count, total: picked.count, sessions: mode.namesGroups ? opened : [:],
                                          grouping: grouping, savedBytes: savedBytes)
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
                                          proxyOnly: proxyOnlyDone)
            }
            log.add("导入结束：\(summary)")
            // 全部文件都导好的拍摄取消选中。
            let doneIDs = Set(done.map(\.item.id))
            grid.remove(pickedShots.filter { id in shots[id].map { importFiles(of: $0).allSatisfy(doneIDs.contains) } ?? false })
            progress = nil
            refreshCopies()
            rebuild()
            importTask = nil
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

    /// 中断后继续：导到原来的会话，不再问名字。有的分组上次还没来得及建会话时，再问一次（已建好的那些不用再填）。
    func continueImport() {
        guard !sourcesOffline, let i = interrupted else { return }
        guard captureOneMode.namesGroups else { startImport(session: nil); return }
        let groups = importGroups(i.grouping)
        if !groups.isEmpty, groups.allSatisfy({ i.sessions[$0.id] != nil }) {
            startImport(jobs: groups.map { g in
                let r = i.sessions[g.id]!
                return ImportJob(key: g.id, files: g.files, session: r.session, event: r.event, scene: g.scene)
            }, grouping: i.grouping)
        } else {
            sessionGrouping = i.grouping
            beginImport(resume: i.sessions)
        }
    }

    /// 导入完以后看 LrC 插件的回执，更新「已添加 n/N」。LrC 没开时它会被打开，可能要等一会儿。
    func watchLightroom(_ names: [String]) {
        lightroomWatch?.cancel()
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
            log.add(s)
        }
    }

    func dismissResult() { lastResult = nil }
    /// 放弃继续导入：没导完的照片仍然选中，可以重新导入。
    func dismissInterrupted() { interrupted = nil }

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
    /// 按创意外观设 C1 的 ICC 配置文件和曲线（只看 RAW：HIF / JPG 已经带着相机的外观）。
    /// C1 刚收到文件时可能还没建好变体，找不到的隔一会儿再试几次。返回加在导入结果后面的说明。
    func applyLooks(_ saved: [URL], sessions: [String]) async -> String? {
        let raws = saved.filter { ["ARW", "SR2", "SRF"].contains($0.pathExtension.uppercased()) }
        guard !raws.isEmpty else { return nil }
        var applied = 0, unknown = 0, missingProfiles = Set<String>(), notFound = 0
        for name in sessions {
            let mine = raws.filter { $0.path.contains("/\(name)/Capture/") }
            var pairs: [(variant: String, look: String)] = []
            for u in mine {
                if let c = CreativeLook.code(ofRaw: u) { pairs.append((u.deletingPathExtension().lastPathComponent, c)) }
                else { unknown += 1; log.add("创意外观：\(u.lastPathComponent) 读到「\(CreativeLook.raw(u) ?? "无")」，不认识，保持原样") }
            }
            for attempt in 0..<6 where !pairs.isEmpty {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1.5)) }
                let r = CaptureOneBridge.applyLooks(session: name, pairs)
                applied += r.applied
                missingProfiles.formUnion(r.noProfile)
                pairs = pairs.filter { r.notFound.contains($0.variant) }
            }
            notFound += pairs.count
        }
        log.add("创意外观：已设 \(applied) 张" + (missingProfiles.isEmpty ? "" : "，未安装 \(missingProfiles.sorted().joined(separator: "、"))")
                + (unknown > 0 ? "，\(unknown) 张不认识" : "") + (notFound > 0 ? "，\(notFound) 张在 C1 里没找到" : ""))
        var s = "，已按创意外观设置 \(applied) 张"
        if !missingProfiles.isEmpty { s += "（未安装：\(missingProfiles.sorted().joined(separator: "、"))）" }
        return applied > 0 || !missingProfiles.isEmpty ? s : nil
    }
}
