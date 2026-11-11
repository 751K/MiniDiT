import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

// 导入的执行过程：登记来源 → 读代理大小 → 分卷号 → 逐组导入 → 收尾（见 AppModel+ImportFinish）。
// 每个文件怎么导见 AppModel+ImportFile。

extension AppModel {

    /// 在 importTask 里跑完一次导入。
    func runImport(_ run: ImportRun) async {
        guard await recordSourceAddresses(run) else { return }
        await loadProxySizes(run)
        guard await assignRolls(run) else { return }
        for job in run.jobs {
            if Task.isCancelled || run.stop { break }
            await importJob(job, run)
        }
        await finishImport(run)
    }

    // MARK: 准备

    /// 每个文件的来源地址和来源身份写进导入记录。读卡器上的照片顺便读出机身型号和序列号。
    /// 导入记录写不进去时停止导入，返回 false。
    private func recordSourceAddresses(_ run: ImportRun) async -> Bool {
        var addresses: [String: String] = [:]
        var identities: [String: ImportSourceIdentity] = [:]
        for job in run.jobs {
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
                addresses[run.fileID(job, item)] = address
                identities[run.fileID(job, item)] = identity
            }
        }
        guard run.journal.update(run.token, { b in
            for i in b.files.indices {
                b.files[i].sourceAddress = addresses[b.files[i].id]
                b.files[i].sourceIdentity = identities[b.files[i].id] ?? b.files[i].sourceIdentity
            }
        }) else {
            errorMessage = run.journal.persistenceError
            progress = nil
            importTask = nil
            return false
        }
        return true
    }

    /// 只导代理的视频：还没读到代理大小的先问一下，总进度才按代理算。
    private func loadProxySizes(_ run: ImportRun) async {
        let picked = run.picked
        guard picked.contains(where: { importsProxyOnly($0) && proxySizes[$0.id] == nil }) else { return }
        for item in picked where importsProxyOnly(item) && proxySizes[item.id] == nil {
            if let r = route(item.id), let p = await r.library.proxy(of: r.local) { proxySizes[item.id] = p.size }
        }
        progress?.bytesTotal = picked.reduce(0) { $0 + transferSize($1) } * run.weight
    }

    /// 卷号：这次导入的视频按机型各开一卷（之前分过卷的片段沿用原来的），连同时间码、格式写进导入记录。
    /// 导入记录写不进去时停止导入，返回 false。
    private func assignRolls(_ run: ImportRun) async -> Bool {
        var videoItems: [(item: CameraContentItem, model: String)] = []
        var reportClipInfo = clipInfos
        for item in run.picked where item.kind == .video {
            var model = clipInfos[item.id]?.model ?? ""
            if model.isEmpty, let r = route(item.id), let info = await r.library.clipInfo(r.local) {
                reportClipInfo[item.id] = info
                model = info.model
            }
            videoItems.append((item, model.isEmpty ? (camera(of: item.id) ?? "未知") : model))
        }
        let rolls = RollStore.shared.assign(videoItems)
        run.rolls = rolls
        let reportItems = Dictionary(uniqueKeysWithValues: run.picked.map { ($0.id, $0) })
        guard run.journal.update(run.token, { batch in
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
            errorMessage = run.journal.persistenceError; progress = nil; importTask = nil
            return false
        }
        for r in Set(rolls.values).sorted() {
            log.add("卷号 \(r)：\(rolls.filter { $0.value == r }.count) 个片段")
        }
        return true
    }

    // MARK: 一个分组

    /// 导入一个分组（一个会话）的全部文件，再写这一组的视频校验清单、整理交给后期的片段。
    private func importJob(_ job: ImportJob, _ run: ImportRun) async {
        let state = beginJob(job, run)
        for item in job.files {
            if Task.isCancelled || run.journal.persistenceError != nil { break }
            progress?.current = "导入 \(item.filename)"
            progress?.resumingFrom = nil
            if await importFile(item, state, run) == .stop { break }
        }
        // RAW 没导成（失败或取消）的 JPG/HIF：不叠了，单独交。
        for urls in state.waiting.values { sendImportToLightroom(urls.map { .init(url: $0) }, state, run) }
        // 视频文件夹各写一份 MHL（「10.21-Int/ascmhl/」）。
        for (folder, entries) in state.mhlVideo {
            do { run.reports.append(try MHLWriter.append(root: folder, entries: entries)) }
            catch { log.add("写视频校验清单失败：\(error.localizedDescription)") }
        }
        // 照片文件夹也各写一份。C1 会话写在 Capture 文件夹里，C1 自己的 CaptureOne/ 子文件夹不算。
        for (folder, entries) in state.mhlPhoto {
            do {
                run.reports.append(try MHLWriter.append(root: folder, entries: entries,
                                                        ignore: state.captureDir != nil ? ["CaptureOne", "CaptureOne/"] : []))
            } catch { log.add("写照片校验清单失败：\(error.localizedDescription)") }
        }
        let plan = run.plan
        if plan.sendToFCP || plan.sendToResolve || plan.sendToPremiere || plan.sendToJianying, !state.fcpClips.isEmpty {
            let base = run.videoRoot.standardizedFileURL.pathComponents
            run.videoEvents += state.fcpClips.sorted { $0.key.path < $1.key.path }.map { folder, clips in
                let parts = folder.standardizedFileURL.pathComponents
                let rel = parts.starts(with: base) ? Array(parts.dropFirst(base.count)) : [folder.lastPathComponent]
                return FCPXMLWriter.Event(name: rel.isEmpty ? folder.lastPathComponent : rel.joined(separator: " · "), clips: clips,
                    uid: FCPXMLWriter.stableUID((job.appSession?.uuidString ?? "") + "|" + folder.path))
            }
        }
    }

    /// 定下这一组的去处：C1 会话（只算出最终目录，Capture One 到交接时才打开）、LrC 收藏夹、照片和视频的整理规则。
    private func beginJob(_ job: ImportJob, _ run: ImportRun) -> ImportJobState {
        var target: CaptureOneBridge.SessionTarget?
        var event = job.event
        if run.mode == .newSession, job.files.contains(where: { $0.kind != .video }), let session = job.session {
            switch session {
            case .new(let name):
                rememberEvent(job.event)
                let database = run.sessionsFolder.appending(path: name, directoryHint: .isDirectory).appending(path: name + ".cosessiondb")
                target = .init(database: database)
            case .existing(let file):
                target = .init(database: file)
                event = event ?? Self.eventName(of: file.deletingPathExtension().lastPathComponent)
            case .resolved(let existing):
                target = existing
            }
            if let target {
                run.opened[job.key] = ResumeSession(captureOneTarget: target, name: target.name, event: event)
                log.add("会话「\(target.name)」，Capture 文件夹：\(target.captureDir.path)")
            }
        }
        let groupName: String? = job.folder ?? {
            switch job.session {
            case .new(let name): name
            case .resolved(let target): target.name
            case .existing(let url): url.deletingPathExtension().lastPathComponent
            case nil: nil
            }
        }()
        let state = ImportJobState(job: job, target: target, event: event,
                                   layout: job.plan?.organization ?? run.plan.organization, groupName: groupName)
        // 导入到 LrC：收藏夹名就是这一组的名字；RAW 先导，同名的 JPG/HIF 叠到它下面。
        if run.mode == .lightroom, case .new(let name) = job.session {
            state.collection = name
            run.lightroomCollections.append(name)
            rememberEvent(job.event)
            run.opened[job.key] = ResumeSession(captureOneTarget: nil, name: name, event: event)
        }
        state.rawKeys = run.mode == .lightroom ? Set(job.files.filter { $0.kind == .raw }.map { lightroomPairKey($0, state, run) }) : []
        return state
    }

    // MARK: 目录与交接

    /// 几个来源一起导：每个来源一个子文件夹（「Capture/α7 V/DSC00001.ARW」），文件名不改。
    func importSubfolder(_ dir: URL, _ item: CameraContentItem, _ run: ImportRun) -> URL {
        guard let name = sourceFolder(for: item, in: run.folders) else { return dir }
        return dir.appending(path: name, directoryHint: .isDirectory)
    }

    /// 照片、视频分别套用整理规则，会话只记录它们属于同一次拍摄。
    func importVideoFolder(_ item: CameraContentItem, _ state: ImportJobState, _ run: ImportRun) -> URL {
        state.layout.folder(for: item, root: run.videoRoot, sessionName: state.groupName,
                            event: state.event, scene: state.job.scene, roll: run.rolls[item.id])
    }

    /// 照片的文件夹（不含多来源时的子文件夹）：C1 会话模式是 Capture 文件夹，否则按照片整理规则。
    func importPhotoFolder(_ item: CameraContentItem, _ state: ImportJobState, _ run: ImportRun) -> URL {
        let photos = state.layout.folder(for: item, root: run.root, sessionName: state.groupName,
                                         event: state.event, scene: state.job.scene)
        return state.captureDir ?? photos
    }

    func importDestination(_ item: CameraContentItem, _ state: ImportJobState, _ run: ImportRun) -> URL {
        if item.kind == .video { return importSubfolder(importVideoFolder(item, state, run), item, run) }
        return importSubfolder(importPhotoFolder(item, state, run), item, run)
    }

    /// RAW 和同名 JPG/HIF 的配对键：目标目录 + 不带扩展名的小写文件名。
    func lightroomPairKey(_ item: CameraContentItem, _ state: ImportJobState, _ run: ImportRun) -> String {
        let dir = importDestination(item, state, run)
        return dir.path + "/" + (item.filename as NSString).deletingPathExtension.lowercased()
    }

    func sendImportToLightroom(_ photos: [LightroomBridge.Photo], _ state: ImportJobState, _ run: ImportRun) {
        do {
            run.lightroomJobs.append(try LightroomBridge.enqueue(collection: state.collection, select: state.firstInCollection, photos: photos))
            state.firstInCollection = false
            if !run.wokeLightroom { LightroomBridge.wake(); run.wokeLightroom = true }
        } catch {
            updateDelivery("Lightroom Classic", message: "部分文件未能发送：" + error.localizedDescription, failed: true, id: run.token)
            log.add("交给 Lightroom Classic 失败 \(photos.map(\.url.lastPathComponent).joined(separator: "、"))：\(error.localizedDescription)")
        }
    }
}
