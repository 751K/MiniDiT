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
        let primaryNeed = files.filter { history.localFile($0, camera: cameraID) == nil }.reduce(0) { $0 + $1.size }
        let primary = captureOneMode == .newSession ? sessionsFolder : destination
        if primaryNeed > 0, let free = Self.freeSpace(at: primary), free < primaryNeed + Self.spaceMargin(primaryNeed) {
            return SpaceProblem(isBackup: false, folder: primary, needed: primaryNeed, available: free)
        }
        if backupEnabled, backupAvailable, !noBackupThisTime, let backup = backupFolder {
            let need = files.filter { history.backupFile($0, camera: cameraID) == nil }.reduce(0) { $0 + $1.size }
            if need > 0, let free = Self.freeSpace(at: backup), free < need + Self.spaceMargin(need) {
                return SpaceProblem(isBackup: true, folder: backup, needed: need, available: free)
            }
        }
        return nil
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
        guard let library, progress == nil else { return }
        let jobs = jobs.filter { !$0.files.isEmpty }
        let picked = jobs.flatMap(\.files)  // 旧的先导
        guard !picked.isEmpty else { return }
        let pickedShots = grid.selected
        let root = destination
        let mode = captureOneMode
        let camera = cameraID
        let backupRoot = backupEnabled && backupAvailable && !noBackupThisTime ? backupFolder : nil
        noBackupThisTime = false
        let wantsBackup = backupEnabled
        let deleteRequested = willDeleteFromSource
        let weight: UInt64 = backupRoot == nil ? 1 : 2
        progress = ImportProgress(total: picked.count, bytesTotal: picked.reduce(0) { $0 + $1.size } * weight)
        lastSummary = nil
        log.add("开始导入 \(picked.count) 个文件到 \(root.path)，Capture One：\(mode.title)，"
                + (backupRoot.map { "备份到 \($0.path)" } ?? "没有备份")
                + (jobs.count > 1 ? "，分成 \(jobs.count) 个会话" : ""))
        let sessionsFolder = self.sessionsFolder
        importTask = Task {
            var saved: [URL] = []
            var done: [ImportHistory.Entry] = []
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
                let importer = FileImporter(library: library, root: root, camera: camera, backupRoot: backupRoot, event: event,
                                            scene: job.scene, checkSource: deleteRequested)
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
                    let dir = captureDir ?? FileImporter.folder(for: item, root: root, event: event, scene: job.scene)
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
                for item in job.files {
                    if Task.isCancelled { break }
                    progress?.current = "导入 \(item.filename)"
                    progress?.resumingFrom = nil
                    let dir = captureDir ?? FileImporter.folder(for: item, root: root, event: event, scene: job.scene)
                    let base = progress?.bytesDone ?? 0
                    do {
                        let r = try await importer.importItem(item, into: dir, progress: { d in
                            Task { @MainActor in
                                if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                            }
                        }, stage: { self.progress?.current = $0 }, skipped: { self.progress?.credit($0) },
                           resumed: { self.progress?.resumingFrom = $0; self.progress?.resumedFiles += 1 })
                        progress?.bytesDone = base + importer.weight(of: item)
                        switch r.outcome {
                        case .alreadyThere: progress?.skipped += 1
                        case .reused(let u): progress?.reused += 1; saved.append(u)
                        case .downloaded(let u): progress?.done += 1; saved.append(u)
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
                        if case .alreadyThere = r.outcome {
                            mhlPrimary.append(.init(url: r.outcome.url, xxh64: r.xxh64, action: .verified))
                        } else {
                            mhlPrimary.append(.init(url: r.outcome.url, xxh64: r.xxh64, action: .original))
                        }
                        if let backupURL { mhlBackup.append(.init(url: backupURL, xxh64: r.xxh64, action: .original)) }
                        if mode == .lightroom {
                            let url = r.outcome.url
                            let key = pairKey(item)
                            if item.kind == .raw {
                                rawByKey[key] = url
                                sendToLightroom([.init(url: url)] + (waiting.removeValue(forKey: key) ?? []).map { .init(url: $0, stackWith: url) })
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
                // 导入报告：ASC MHL 清单。会话模式写在 Capture 文件夹里（C1 自己的 CaptureOne/ 子文件夹不算），其他模式写在保存位置根目录。
                if !mhlPrimary.isEmpty {
                    do {
                        reports.append(try MHLWriter.append(root: captureDir ?? root, entries: mhlPrimary,
                                                            ignore: captureDir != nil ? ["CaptureOne", "CaptureOne/"] : []))
                    } catch { log.add("写校验清单失败：\(error.localizedDescription)") }
                }
            }
            ImportHistory.shared.record(done, camera: camera)
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
                    savedBytes += FileImporter.savedPartBytes(f, in: dir ?? FileImporter.folder(for: f, root: root, event: job.event, scene: job.scene))
                }
            }
            var deleted: Int?
            var deleteFailed = 0
            var cardReadOnly = false
            if deleteRequested, let card = library as? LocalCardLibrary {
                var n = 0
                cardReadOnly = (try? card.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false
                if cardReadOnly {
                    log.add("存储卡是只读的，没有删除文件")
                } else {
                    for h in deletable {
                        progress?.current = "删除存储卡上的 \(items[h]?.filename ?? "")"
                        do { try await card.delete(h); n += 1 }
                        catch { deleteFailed += 1; log.add("删除失败 \(items[h]?.filename ?? "\(h)")：\(error.localizedDescription)") }
                    }
                    log.add("从存储卡删除了 \(n) 个文件；\(picked.count - n) 个保留")
                }
                deleted = n
            }
            let wasLost = lostDuringImport || (progress.map { !$0.failed.isEmpty } ?? false) && offline
            var summary = "导入 \(done.count) 个文件"
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
            if mode == .newSession {
                if let sessionText { summary += "，已存入会话“\(sessionText)”" }
            } else if mode == .lightroom {
                if !lightroomJobs.isEmpty {
                    summary += "，已交由 Lightroom Classic 导入" + (lightroomText.map { "（收藏夹“\($0)”）" } ?? "")
                    watchLightroom(lightroomJobs)
                }
            } else if mode != .off && !saved.isEmpty {
                summary += await sendToCaptureOne(saved, inPlace: mode == .inPlace)
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
                                          deleted: deleted, keptOnCard: deleted.map { picked.count - $0 } ?? 0,
                                          deleteFailed: deleteFailed, cardReadOnly: cardReadOnly,
                                          resumed: progress?.resumedFiles ?? 0, savedBytes: savedBytes, reports: reports,
                                          lightroom: mode == .lightroom ? lightroomText : nil)
            }
            log.add("导入结束：\(summary)")
            // 全部文件都导好的拍摄取消选中。
            let doneIDs = Set(done.map(\.item.id))
            grid.remove(pickedShots.filter { id in shots[id].map { importFiles(of: $0).allSatisfy(doneIDs.contains) } ?? false })
            progress = nil
            refreshCopies()
            rebuild()
            importTask = nil
            // 删了卡上的文件：重新列一遍卡。
            if let deleted, deleted > 0 { await loadAll(restoring: selectedKeys(), days: shownDays) }
        }
    }

    func cancelImport() { importTask?.cancel() }

    /// 会话名「3.15-公园」里的「公园」；没有「-」就用整个名字。
    static func eventName(of sessionName: String) -> String? {
        let s = sessionName.firstIndex(of: "-").map { String(sessionName[sessionName.index(after: $0)...]) } ?? sessionName
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// 中断后继续：导到原来的会话，不再问名字。有的分组上次还没来得及建会话时，再问一次（已建好的那些不用再填）。
    func continueImport() {
        guard !offline, let i = interrupted else { return }
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
            while !remaining.isEmpty, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let r = LightroomBridge.collect(Array(remaining))
                if !r.done.isEmpty { lastProgress = Date() }
                remaining.subtract(r.done)
                sum.added += r.added; sum.skipped += r.skipped; sum.failed += r.failed; sum.failures += r.failures
                let done = total - remaining.count
                if remaining.isEmpty { break }
                let fresh = LightroomBridge.heartbeat()?.isFresh ?? false
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
