import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

// 导入一个文件：下载、校验、备份、写导入记录，照片交给 LrC，视频带上代理和 XML。

extension AppModel {

    /// 导入一个文件。相机掉线、连续失败或取消时返回 .stop，这一组不再往下导。
    func importFile(_ item: CameraContentItem, _ state: ImportJobState, _ run: ImportRun) async -> ImportStep {
        let dir = importDestination(item, state, run)
        let base = progress?.bytesDone ?? 0
        let throttle = ProgressThrottle()
        guard let importer = makeImporter(for: item, state, run) else {
            // 来源已经关掉 / 拔掉了。
            progress?.failed.append(item.filename)
            let id = run.fileID(state.job, item)
            _ = run.journal.update(run.token) { b in if let i = b.files.firstIndex(where: { $0.id == id }) { b.files[i].state = .failed; b.files[i].message = "来源已关闭" } }
            log.add("导入失败 \(item.filename)：来源已关闭")
            return .next
        }
        if importsProxyOnly(item) {
            return await importProxyOnlyFile(item, into: dir, base: base, throttle: throttle, importer: importer, state, run)
        }
        return await importOriginalFile(item, into: dir, base: base, throttle: throttle, importer: importer, state, run)
    }

    /// Wi-Fi「视频只导代理」：只下代理和 XML，原片留在卡上，不记进导入记录（还算没导）。
    private func importProxyOnlyFile(_ item: CameraContentItem, into dir: URL, base: UInt64, throttle: ProgressThrottle,
                                     importer: FileImporter, _ state: ImportJobState, _ run: ImportRun) async -> ImportStep {
        let job = state.job
        do {
            var issues: [String] = []
            guard let r = try await importer.importProxyOnly(localItem(item), into: dir, progress: { d in
                guard throttle.allow() else { return }
                Task { @MainActor in
                    if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                }
            }, stage: { self.progress?.current = $0 }, issue: { issues.append($0) }) else {
                log.add("只导代理：\(item.filename) 在相机上没有代理，跳过")
                progress?.failed.append(String(localized: "\(item.filename)（无代理）"))
                return .next
            }
            progress?.bytesDone = base + transferSize(item) * run.weight
            if r.proxy.alreadyThere { progress?.skipped += 1 } else { progress?.done += 1 }
            if r.proxy.backup != nil { progress?.backedUp += 1 }
            for c in [r.proxy] + (r.xml.map { [$0] } ?? []) {
                state.mhlVideo[importVideoFolder(item, state, run), default: []].append(.init(url: c.url, xxh64: c.xxh64,
                                                                                         action: c.alreadyThere ? .verified : .original))
            }
            let proxyAssets = ([r.proxy] + (r.xml.map { [$0] } ?? [])).map { c in
                importAssetRecord(url: c.url, hash: c.xxh64, backup: c.backup,
                                  main: r.proxy.url.deletingLastPathComponent().deletingLastPathComponent().appending(path: item.filename),
                                  item: item, kind: c.url.pathExtension.lowercased() == "xml" ? .metadata : .proxy, state, run)
            }
            checkpointImport(item, assets: proxyAssets, proxyOnly: true, message: issues.isEmpty ? nil : issues.joined(separator: "；"), state, run)
            await backupImportedFile(batchID: run.token, fileID: run.fileID(job, item), run: run.plan.runBackups)
            ProxyOnlyStore.shared.record(item, camera: camera(of: item.id), proxy: r.proxy.url)
            run.proxyOnlyDone += 1
            log.add("只导代理：\(item.filename) → \(r.proxy.url.path)")
            run.consecutiveFailures = 0
        } catch is CancellationError {
            return .stop
        } catch {
            let id = run.fileID(job, item)
            _ = run.journal.update(run.token) { b in
                if let i = b.files.firstIndex(where: { $0.id == id }) { b.files[i].state = .failed; b.files[i].message = error.localizedDescription }
            }
            if error is PTPIPTransportError { progress?.failed.append(item.filename); lostDuringImport = true; run.stop = true; return .stop }
            log.add("只导代理失败 \(item.filename)：\(error.localizedDescription)")
            progress?.failed.append(item.filename)
        }
        return .next
    }

    /// 导入原文件：先存第一份并立即记账，再备份；视频接着导代理和 XML；照片按需交给 LrC。
    private func importOriginalFile(_ item: CameraContentItem, into dir: URL, base: UInt64, throttle: ProgressThrottle,
                                    importer: FileImporter, _ state: ImportJobState, _ run: ImportRun) async -> ImportStep {
        let job = state.job
        do {
            let r = try await importer.importItem(localItem(item), into: dir, progress: { d in
                guard throttle.allow() else { return }
                Task { @MainActor in
                    if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                }
            }, stage: { self.progress?.current = $0 }, skipped: { self.progress?.credit($0) },
               resumed: { self.progress?.resumingFrom = $0; self.progress?.resumedFiles += 1 },
               primarySaved: { url, hash, matchesSource in
                self.checkpointImport(item, assets: [self.importAssetRecord(url: url, hash: hash, backup: nil, main: url,
                    item: item, kind: .original, sourceCompared: matchesSource, state, run)],
                    message: item.kind == .video ? "附属文件整理尚未完成" : nil, state, run)
                ImportHistory.shared.record([.init(item: item, url: url, xxh64: hash, backup: nil)], camera: self.camera(of: item.id))
                if let project = job.appSession { self.recordSessionFiles([url], in: project) }
               })
            let actual = importer.weight(of: item, at: r.outcome.url)
            let estimate = transferSize(item) * run.weight
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
            case .reused(let u): progress?.reused += 1; if !isVideo { run.saved.append(u) }
            case .downloaded(let u): progress?.done += 1; if !isVideo { run.saved.append(u) }
            }
            if let target = state.target, !isVideo {
                if case .alreadyThere = r.outcome {
                    if run.captureOneFiles[target] == nil { run.captureOneFiles[target] = [] }
                } else {
                    run.captureOneFiles[target, default: []].append(r.outcome.url)
                }
            }
            var backupURL: URL?
            switch r.backup {
            case .none: break
            case .done(let u): progress?.backedUp += 1; backupURL = u
            case .failed: progress?.backupFailed.append(item.filename)
            }
            if run.deleteRequested, r.matchesSource, item.kind != .video {
                run.deletable.append(item.id)
            }
            run.done.append(.init(item: item, url: r.outcome.url, xxh64: r.xxh64, backup: backupURL))
            var there = false
            if case .alreadyThere = r.outcome { there = true }
            let entry = MHLWriter.Entry(url: r.outcome.url, xxh64: r.xxh64, action: there ? .verified : .original)
            if isVideo { state.mhlVideo[importVideoFolder(item, state, run), default: []].append(entry) } else { state.mhlPhoto[importPhotoFolder(item, state, run), default: []].append(entry) }
            var journalAssets = [importAssetRecord(url: r.outcome.url, hash: r.xxh64, backup: backupURL,
                                                   main: r.outcome.url, item: item, kind: .original, sourceCompared: r.matchesSource, state, run)]
            var journalIssues: [String] = []
            if case .failed(let error) = r.backup { journalIssues.append("备份未完成：" + error) }
            checkpointImport(item, assets: journalAssets, message: isVideo ? "附属文件整理尚未完成" : journalIssues.first, state, run)
            if isVideo {
                // XML 和代理跟着片段走，一样校验、备份、写进 MHL。
                var proxy: URL?
                for c in await importer.importSidecars(of: localItem(item), clip: r.outcome.url, backupClip: backupURL,
                                                       proxies: run.proxies, stage: { self.progress?.current = $0 }, issue: { journalIssues.append($0) }) {
                    state.mhlVideo[importVideoFolder(item, state, run), default: []].append(.init(url: c.url, xxh64: c.xxh64,
                                                                                             action: c.alreadyThere ? .verified : .original))
                        journalAssets.append(importAssetRecord(url: c.url, hash: c.xxh64, backup: c.backup,
                        main: r.outcome.url, item: item, kind: c.url.pathExtension.lowercased() == "xml" ? .metadata : .proxy, state, run))
                    if c.url.deletingLastPathComponent().lastPathComponent == "Proxy" { proxy = c.url }
                }
                // 已经在电脑上的（之前导过）不再交给 FCP，免得事件里出现重复的片段。
                if !there { state.fcpClips[importVideoFolder(item, state, run), default: []].append(.init(url: r.outcome.url, proxy: proxy, roll: run.rolls[item.id])) }
            }
            if Task.isCancelled, isVideo { journalIssues.append("附属文件整理已中断，部分文件可能尚未保存。") }
            checkpointImport(item, assets: journalAssets, message: journalIssues.isEmpty ? nil : journalIssues.joined(separator: "；"), state, run)
            await backupImportedFile(batchID: run.token, fileID: run.fileID(job, item), run: run.plan.runBackups)
            let fileID = run.fileID(job, item)
            if let file = run.journal.batches.first(where: { $0.id == run.token })?.files.first(where: { $0.id == fileID }),
               let original = file.assets.first(where: { $0.kind == .original }),
               let index = run.done.lastIndex(where: { $0.item.id == item.id }) {
                let copies = original.copies.filter { $0.role == .backup && $0.verifiedAt != nil }
                run.done[index].backup = copies.first.map { URL(filePath: $0.path) }
                run.done[index].backups = copies.map { URL(filePath: $0.path) }
            }
            if run.mode == .lightroom, !isVideo {
                let url = r.outcome.url
                let key = lightroomPairKey(item, state, run)
                if item.kind == .raw {
                    state.rawByKey[key] = url
                    if applyCreativeLook, let note = ensureLookPack(forRaw: url) { run.lookNotes.append(note) }
                    let look = applyCreativeLook ? LightroomLooks.profile(for: url) : nil
                    sendImportToLightroom([.init(url: url, look: look)] + (state.waiting.removeValue(forKey: key) ?? []).map { .init(url: $0, stackWith: url) }, state, run)
                } else if let raw = state.rawByKey[key] {
                    sendImportToLightroom([.init(url: url, stackWith: raw)], state, run)
                } else if state.rawKeys.contains(key) {
                    state.waiting[key, default: []].append(url)
                } else {
                    sendImportToLightroom([.init(url: url)], state, run)
                }
            }
        } catch is CancellationError {
            return .stop
        } catch {
            let id = run.fileID(job, item)
            _ = run.journal.update(run.token) { b in
                if let i = b.files.firstIndex(where: { $0.id == id }) { b.files[i].state = .failed; b.files[i].message = error.localizedDescription }
            }
            if error is PTPIPTransportError { progress?.failed.append(item.filename); lostDuringImport = true; run.stop = true; return .stop }
            log.add("导入失败 \(item.filename)：\(error.localizedDescription)")
            progress?.failed.append(item.filename)
            // 连着几个文件都失败，多半是相机在关机 / 断开（关机前会先对所有请求回「不支持」），
            // 当作中断处理：停下来，等重连后继续，而不是把剩下的全标成失败。
            run.consecutiveFailures += 1
            if run.consecutiveFailures >= 3 {
                log.add("连续 \(run.consecutiveFailures) 个文件失败，当作中断处理")
                lostDuringImport = true
                run.stop = true
                return .stop
            }
            return .next
        }
        run.consecutiveFailures = 0
        return .next
    }

    // MARK: 工具

    /// 每个文件交给自己的来源；默认备份镜像实际目录，并按照片、视频分开。
    private func makeImporter(for item: CameraContentItem, _ state: ImportJobState, _ run: ImportRun) -> FileImporter? {
        guard let lib = route(item.id)?.library else { return nil }
        let layout = state.layout
        let backupDirectory = run.backupRoot.flatMap { backup in
            layout.mirrorBackup ? ImportOrganization.mirroredBackup(root: backup, primaryFolder: importDestination(item, state, run),
                primaryRoot: item.kind == .video ? run.videoRoot : (state.captureDir == nil ? run.root : run.sessionsFolder),
                video: item.kind == .video) : nil
        }
        return FileImporter(library: lib, root: run.root, camera: camera(of: item.id), backupRoot: nil,
                            event: state.event, scene: state.job.scene, sourceFolder: sourceFolder(for: item, in: run.folders),
                            backupSubfolder: item.kind == .video ? "视频" : nil,
                            backupDirectory: backupDirectory, checkSource: run.deleteRequested)
    }

    /// 导入记录里的一个实体文件：工作副本，以及备份（还没备份时记下计划中的备份位置）。
    private func importAssetRecord(url: URL, hash: UInt64, backup: URL?, main: URL,
                                   item: CameraContentItem, kind: ImportedAssetRecord.Kind,
                                   sourceCompared: Bool = false, _ state: ImportJobState, _ run: ImportRun) -> ImportedAssetRecord {
        let layout = state.layout
        let backupBase = run.requestedBackupRoot ?? URL(filePath: "/__minidit_backup__")
        var planned: URL
        if layout.mirrorBackup {
            planned = ImportOrganization.mirroredBackup(root: backupBase, primaryFolder: importDestination(item, state, run),
                primaryRoot: item.kind == .video ? run.videoRoot : (state.captureDir == nil ? run.root : run.sessionsFolder), video: item.kind == .video)
        } else {
            let relative = NameTemplate.render(layout.backupTemplate, allowsFolders: false, day: Self.dayKey(item), event: state.event, scene: state.job.scene)
            planned = backupBase.appending(path: relative, directoryHint: .isDirectory)
            if item.kind == .video { planned.append(path: "视频") }
            if let name = sourceFolder(for: item, in: run.folders) { planned.append(path: name) }
        }
        let mainDirectory = main.deletingLastPathComponent().path + "/"
        let relativeAsset = url.path.hasPrefix(mainDirectory) ? String(url.path.dropFirst(mainDirectory.count)) : url.lastPathComponent
        let target = backup ?? planned.appending(path: relativeAsset)
        let prefix = backupBase.standardizedFileURL.path + "/"
        let relative = target.path.hasPrefix(prefix) ? String(target.path.dropFirst(prefix.count))
            : "\(run.token.uuidString)/\(item.id)/\(relativeAsset)"
        var copies = [ImportedCopyRecord(role: .working, path: url.path, verifiedAt: Date(),
                                         evidence: sourceCompared ? .sourceComparison : .localReadback)]
        if let backup { copies.append(.init(role: .backup, path: backup.path, verifiedAt: Date(), evidence: .localReadback)) }
        return .init(kind: kind, size: FileImporter.fileSize(url) ?? 0, xxh64: XXH64.hex(hash),
                     backupRelativePath: relative, copies: copies)
    }

    /// 文件已存下：立即写进导入记录。写不进去就取消整次导入。
    private func checkpointImport(_ item: CameraContentItem, assets: [ImportedAssetRecord], proxyOnly: Bool = false,
                                  message: String? = nil, _ state: ImportJobState, _ run: ImportRun) {
        let id = run.fileID(state.job, item)
        if !run.journal.update(run.token, { batch in
            if let i = batch.files.firstIndex(where: { $0.id == id }) {
                batch.files[i].state = .saved
                if batch.files[i].importedAt == nil { batch.files[i].importedAt = Date() }
                batch.files[i].assets = assets
                batch.files[i].proxyOnly = proxyOnly
                batch.files[i].message = message
            }
        }) {
            errorMessage = run.journal.persistenceError
            importTask?.cancel()
        }
    }
}
