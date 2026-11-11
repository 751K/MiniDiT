import AppKit
import MiniDiTCore

@MainActor struct VideoDeliveryServices {
    var identifyResolve: () async throws -> ResolveBridge.Project = { try await ResolveBridge.identifyProject() }
    var sendResolve: (Data, ResolveBridge.Project) async throws -> ResolveBridge.Result = { try await ResolveBridge.send($0, project: $1) }
    var openFCP: (URL) async throws -> Void = { try await FCPXMLWriter.open($0) }
    var confirmResolve: (ResolveBridge.Project) -> Bool = { project in
        let alert = NSAlert(); alert.messageText = "将视频加入“\(project.name)”？"
        alert.informativeText = "上次未能连接 Resolve，尚未确定目标项目。将使用已保存的文件重试。"
        alert.addButton(withTitle: "加入此项目"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    var identifyPremiere: () async throws -> PremiereBridge.Project = { try await PremiereBridge.identifyProject() }
    var sendPremiere: (Data, PremiereBridge.Project) async throws -> PremiereBridge.Result = { try await PremiereBridge.send($0, project: $1) }
    var confirmPremiere: (PremiereBridge.Project) -> Bool = { project in
        let alert = NSAlert(); alert.messageText = "将视频加入“\(project.name)”？"
        alert.informativeText = "上次尚未确定 Premiere Pro 的目标项目。将使用已保存的文件重试。"
        alert.addButton(withTitle: "加入此项目"); alert.addButton(withTitle: "取消")
        return alert.runModal() == .alertFirstButtonReturn
    }
    var fcpDirectory: URL?
}

@MainActor struct VideoDeliveryJob { let batch: UUID, delivery: UUID; let retry: Bool }

extension AppModel {
    func makeVideoDeliveries(events: [FCPXMLWriter.Event], batchID: UUID, plan: ImportPlan) async throws -> [VideoDelivery] {
        guard (plan.sendToFCP || plan.sendToResolve || plan.sendToPremiere), !events.isEmpty, let batch = importJournal.batches.first(where: { $0.id == batchID }) else { return [] }
        let sendFCP = plan.sendToFCP, sendResolve = plan.sendToResolve, sendPremiere = plan.sendToPremiere
        let projectNames = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let logProcessing = plan.fcpLogProcessing, colorSpace = plan.resolveColorSpace
        return try await Task.detached(priority: .utility) {
            let clips = events.flatMap(\.clips)
            let paths = Set(clips.flatMap { [$0.url.path] + ($0.proxy.map { [$0.path] } ?? []) })
            let assets = batch.files.flatMap(\.assets)
            let sizes = Dictionary(assets.flatMap { asset in asset.copies.filter { $0.role == .working }.map { ($0.path, asset.size) } }, uniquingKeysWith: { a, _ in a })
            let baselines = Dictionary(assets.flatMap { asset in asset.copies.filter { $0.role == .working }.map { ($0.path, asset.xxh64 ?? "") } }, uniquingKeysWith: { a, _ in a })
            let refs = try paths.sorted().map { path -> VideoDelivery.File in
                guard let size = sizes[path] else { throw VideoDelivery.Failure("缺少已保存文件的记录：" + URL(filePath: path).lastPathComponent) }
                return .init(path: path, size: size, volumeID: BackupRepair.volumeID(at: URL(filePath: path)))
            }
            let projects = Set(batch.files.filter { file in file.assets.contains { $0.copies.contains { paths.contains($0.path) } } }.compactMap(\.projectID)).sorted { $0.uuidString < $1.uuidString }
            let frozen = events.map { event in
                FCPXMLWriter.Event(name: event.name, clips: event.clips.map { clip in
                    var c = clip
                    c.uid = FCPXMLWriter.stableUID(c.url.standardizedFileURL.path + "|" + (baselines[c.url.path] ?? ""))
                    return c
                }, uid: event.uid)
            }
            var result: [VideoDelivery] = []
            if sendFCP { result.append(.init(software: .finalCutPro, projectIDs: projects, payload: Data(FCPXMLWriter.xml(frozen, logProcessing: logProcessing).utf8), files: refs, mediaPaths: clips.map { $0.url.path })) }
            if sendResolve { result.append(.init(software: .resolve, projectIDs: projects, payload: try ResolveBridge.payload(frozen, setColorSpace: colorSpace), files: refs, mediaPaths: clips.map { $0.url.path })) }
            if sendPremiere { result.append(.init(software: .premiere, projectIDs: projects, payload: try PremiereBridge.payload(events: frozen, batch: batch, projectNames: projectNames), files: refs, mediaPaths: clips.map { $0.url.path })) }
            return result
        }.value
    }

    func videoDeliveries(in batchID: UUID) -> [VideoDelivery] {
        importJournal.batches.first { $0.id == batchID }?.videoDeliveries ?? []
    }
    func retryVideoDelivery(batchID: UUID, id: UUID) {
        guard progress == nil, importJournal.repairTask == nil,
              let record = videoDeliveries(in: batchID).first(where: { $0.id == id }), record.canRetry else { return }
        enqueueVideoDelivery(batchID: batchID, record: record, retry: true)
    }
    func queueVideoDeliveries(batchID: UUID) {
        for record in videoDeliveries(in: batchID) where record.state == .queued { enqueueVideoDelivery(batchID: batchID, record: record, retry: false) }
    }
    private func enqueueVideoDelivery(batchID: UUID, record: VideoDelivery, retry: Bool) {
        guard importJournal.persistenceError == nil, videoDeliveryRunning != record.id,
              !videoDeliveryQueue.contains(where: { $0.delivery == record.id }) else { return }
        videoDeliveryQueue.append(.init(batch: batchID, delivery: record.id, retry: retry))
        guard videoDeliveryTask == nil else { return }
        videoDeliveryTask = Task {
            while !videoDeliveryQueue.isEmpty {
                let job = videoDeliveryQueue.removeFirst()
                await performVideoDelivery(job)
            }
            videoDeliveryRunning = nil; videoDeliveryTask = nil
        }
    }
    @discardableResult private func saveVideoDelivery(_ record: VideoDelivery, batchID: UUID, expectedAttempt: UUID? = nil) -> Bool {
        guard let current = videoDeliveries(in: batchID).first(where: { $0.id == record.id }),
              expectedAttempt == nil || current.attemptID == expectedAttempt else { return false }
        let saved = importJournal.update(batchID) { batch in
            var records = batch.videoDeliveries ?? []
            guard let index = records.firstIndex(where: { $0.id == record.id }) else { return }
            records[index] = record; batch.videoDeliveries = records; batch.delivery[record.software.name] = record.message
        }
        guard saved else { errorMessage = importJournal.persistenceError; return false }
        if batchID == deliveryID {
            deliveryMessages[record.software.name] = record.message
            if [.failed, .needsAttention, .interrupted, .uncertain].contains(record.state) { deliveryFailures.insert(record.software.name) }
            else { deliveryFailures.remove(record.software.name) }
        }
        return true
    }
    private func performVideoDelivery(_ job: VideoDeliveryJob) async {
        guard let batch = importJournal.batches.first(where: { $0.id == job.batch }), batch.state != .running,
              var record = batch.videoDeliveries?.first(where: { $0.id == job.delivery }),
              job.retry ? record.canRetry : record.state == .queued else { return }
        videoDeliveryRunning = record.id
        record.state = .sending; record.attempts += 1; record.attemptID = UUID(); record.attemptedAt = Date()
        record.message = "正在发送至 " + record.software.name
        record.failedPaths = []; record.warnings = []
        let attempt = record.attemptID!
        guard saveVideoDelivery(record, batchID: job.batch) else { return }
        do {
            let snapshot = record
            try await Task.detached(priority: .utility) { try snapshot.checkFiles() }.value
            if record.software == .finalCutPro {
                let document = try FCPXMLWriter.prepare(id: record.id, payload: record.payload, directory: videoDeliveryServices.fcpDirectory)
                record.documentPath = document.path
                guard saveVideoDelivery(record, batchID: job.batch, expectedAttempt: attempt) else { return }
                try await videoDeliveryServices.openFCP(document)
                record.state = .awaitingConfirmation
                record.message = "已发送，请在 Final Cut Pro 中确认导入。"
            } else if record.software == .premiere {
                let project = try await videoDeliveryServices.identifyPremiere()
                if let expected = record.premiereProjectID {
                    guard expected == project.id else { throw VideoDelivery.Failure("请在 Premiere Pro 中打开原项目“\(record.premiereProjectName ?? "")”后重试；当前项目为“\(project.name)”。") }
                } else {
                    if job.retry && !videoDeliveryServices.confirmPremiere(project) { throw VideoDelivery.Failure("已取消选择目标项目，可稍后重试。") }
                    record.premiereProjectID = project.id; record.premiereProjectName = project.name
                    guard saveVideoDelivery(record, batchID: job.batch, expectedAttempt: attempt) else { return }
                }
                let result = try await videoDeliveryServices.sendPremiere(record.payload, project)
                guard result.projectID == record.premiereProjectID else { throw VideoDelivery.Failure("Premiere Pro 返回的项目与原目标不符，请检查原项目后重试。") }
                let received = Set(result.receivedPaths)
                record.failedPaths = Set(result.failedPaths + record.mediaPaths.filter { !received.contains($0) }).sorted()
                record.warnings = result.warnings
                record.state = !record.failedPaths.isEmpty ? .failed : record.warnings.isEmpty ? .completed : .needsAttention
                record.message = "“\(result.project)”：已加入 \(result.imported) 个，已存在 \(result.skipped) 个"
                    + (record.failedPaths.isEmpty ? "" : "；\(record.failedPaths.count) 个未加入")
                    + (record.warnings.isEmpty ? "" : "；代理或标记需检查")
            } else {
                let project = try await videoDeliveryServices.identifyResolve()
                if let expected = record.resolveProjectID {
                    guard expected == project.id else { throw VideoDelivery.Failure("请在 Resolve 中打开原项目“\(record.resolveProjectName ?? "")”后重试；当前项目为“\(project.name)”。") }
                } else {
                    if job.retry && !videoDeliveryServices.confirmResolve(project) { throw VideoDelivery.Failure("已取消选择目标项目，可稍后重试。") }
                    record.resolveProjectID = project.id; record.resolveProjectName = project.name
                    guard saveVideoDelivery(record, batchID: job.batch, expectedAttempt: attempt) else { return }
                }
                let result = try await videoDeliveryServices.sendResolve(record.payload, project)
                guard result.projectID == record.resolveProjectID else { throw VideoDelivery.Failure("Resolve 返回的项目与原目标不符，请检查原项目后重试。") }
                let received = Set(result.receivedPaths)
                record.failedPaths = Set(result.failedPaths + record.mediaPaths.filter { !received.contains($0) }).sorted()
                record.warnings = result.timecodeWarnings + result.metadataWarnings
                if result.unmanaged > 0 { record.warnings.append("项目未启用色彩管理，\(result.unmanaged) 个片段的输入色彩空间尚未设置。") }
                record.state = !record.failedPaths.isEmpty ? .failed : record.warnings.isEmpty ? .completed : .needsAttention
                record.message = "“\(result.project)”：已加入 \(result.imported) 个，已存在 \(result.skipped) 个"
                    + (record.failedPaths.isEmpty ? "" : "；\(record.failedPaths.count) 个未加入")
                    + (record.warnings.isEmpty ? "" : "；拍摄信息需检查")
            }
        } catch is CancellationError {
            record.state = record.software == .finalCutPro ? .uncertain : .interrupted
            record.message = "发送已中断，请检查软件中的接收结果。"
        } catch {
            record.state = .failed; record.message = error.localizedDescription + "（本地文件已保留）"
        }
        record.finishedAt = Date()
        if saveVideoDelivery(record, batchID: job.batch, expectedAttempt: attempt) {
            log.add(record.software.name + "：" + record.message)
            if record.state == .failed, Bundle.main.bundleIdentifier != nil { Notifier.shared.post(id: record.id.uuidString, title: "未能发送至 " + record.software.name, body: record.message, info: [:]) }
        }
    }
}
