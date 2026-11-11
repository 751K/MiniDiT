import AppKit
import MiniDiTCore

@MainActor struct VideoDeliveryServices {
    /// 加入与 MiniDiT 项目同名的 Resolve 项目（没有就新建）。第二个参数是第一次发送时绑定的项目，重试时必须还是它。
    var sendResolve: (Data, ResolveBridge.Project?) async throws -> ResolveBridge.Result = { try await ResolveBridge.send($0, expected: $1) }
    var openFCP: (URL) async throws -> Void = { try await FCPXMLWriter.open($0) }
    /// 加入与 MiniDiT 项目同名的 Premiere 项目（没有就新建）。第二个参数是第一次发送时绑定的项目，重试时必须还是它。
    var sendPremiere: (Data, PremiereBridge.Project?) async throws -> PremiereBridge.Result = { try await PremiereBridge.send($0, expected: $1) }
    var fcpDirectory: URL?
    /// 剪映的草稿文件夹；检查时换成临时目录。
    var jianyingRoot: URL = JianyingDraft.defaultRoot
    var launchJianying: () -> Void = { JianyingBridge.launchIfNeeded() }
}

@MainActor struct VideoDeliveryJob { let batch: UUID, delivery: UUID; let retry: Bool }

extension AppModel {
    func makeVideoDeliveries(events: [FCPXMLWriter.Event], batchID: UUID, plan: ImportPlan) async throws -> [VideoDelivery] {
        guard (plan.sendToFCP || plan.sendToResolve || plan.sendToPremiere || plan.sendToJianying), !events.isEmpty, let batch = importJournal.batches.first(where: { $0.id == batchID }) else { return [] }
        let sendFCP = plan.sendToFCP, sendResolve = plan.sendToResolve, sendPremiere = plan.sendToPremiere, sendJianying = plan.sendToJianying
        let projectNames = Dictionary(sessions.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let logProcessing = plan.fcpLogProcessing, colorSpace = plan.resolveColorSpace
        let fcpProjectAs = plan.fcpProjectAs, fcpEventLibrary = plan.fcpEventLibrary
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
            // 各软件的目标都用 MiniDiT 项目名：FCP 资源库（或事件）、Resolve 项目、Premiere 项目、剪映草稿，已有就加入，没有就新建。
            // 一批跨了几个项目时用「、」连起来。工程文件的位置在这里定下来，重试时不变。
            let joined = projects.compactMap { projectNames[$0] }.joined(separator: "、")
            let targetName = joined.isEmpty ? (events.first?.name ?? "MiniDiT") : joined
            if sendFCP {
                // 作为资源库：同名资源库，每个视频文件夹一个事件；作为事件：用户选的资源库里一个同名事件。
                let library = fcpProjectAs == .library ? EditorDocumentLocator.locate(name: targetName, extension: "fcpbundle") : fcpEventLibrary
                let fcpEvents = fcpProjectAs == .library ? frozen : await FCPXMLWriter.withMediaDurations(FCPXMLWriter.projectEvent(frozen, name: targetName))
                result.append(.init(software: .finalCutPro, projectIDs: projects, payload: Data(FCPXMLWriter.xml(fcpEvents, logProcessing: logProcessing, library: library).utf8), files: refs, mediaPaths: clips.map { $0.url.path }))
            }
            if sendResolve { result.append(.init(software: .resolve, projectIDs: projects, payload: try ResolveBridge.payload(frozen, setColorSpace: colorSpace, project: targetName), files: refs, mediaPaths: clips.map { $0.url.path })) }
            if sendPremiere {
                let target = PremiereHandoff.Target(name: targetName, path: EditorDocumentLocator.locate(name: targetName, extension: "prproj").path)
                result.append(.init(software: .premiere, projectIDs: projects, payload: try PremiereBridge.payload(events: frozen, batch: batch, projectNames: projectNames, target: target), files: refs, mediaPaths: clips.map { $0.url.path }))
            }
            if sendJianying {
                let payload = try await JianyingBridge.payload(name: targetName, clips: clips.map(\.url))
                result.append(.init(software: .jianying, projectIDs: projects, payload: payload, files: refs, mediaPaths: clips.map { $0.url.path }))
            }
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
                record.message = FCPXMLWriter.libraryName(record.payload).map { "已发送至资源库“\($0)”，请在 Final Cut Pro 中查看导入结果。" } ?? "已发送，请在 Final Cut Pro 中确认导入。"
            } else if record.software == .jianying {
                // 按草稿名找：没有就新建，有就加进素材区；重试时已有的片段不会重复加入。
                let snapshot = record, root = videoDeliveryServices.jianyingRoot
                let (folder, outcome) = try await Task.detached(priority: .utility) { try JianyingBridge.deliver(snapshot.payload, id: snapshot.id, root: root) }.value
                record.documentPath = folder.path
                let name = folder.lastPathComponent
                switch outcome {
                case .created:
                    record.state = .completed
                    record.message = "已在剪映中新建草稿“\(name)”，\(record.mediaPaths.count) 个片段已加入素材区。"
                case .added(let new, let existing):
                    record.state = .completed
                    record.message = "剪映草稿“\(name)”：已加入 \(new) 个，已存在 \(existing) 个。"
                case .locked:
                    record.state = .needsAttention
                    record.message = "剪映草稿“\(name)”已在剪映中打开并被加密，MiniDiT 无法向其中加入素材。请在剪映中手动导入这 \(record.mediaPaths.count) 个片段。"
                }
                if outcome != .locked { videoDeliveryServices.launchJianying() }
            } else if record.software == .premiere {
                // 插件按项目名打开或新建 Premiere 项目；第一次发送后记下它，重试只认这个项目。
                let expected = record.premiereProjectID.map { PremiereBridge.Project(id: $0, name: record.premiereProjectName ?? "", path: "") }
                let result = try await videoDeliveryServices.sendPremiere(record.payload, expected)
                if let expected, result.projectID != expected.id { throw VideoDelivery.Failure("Premiere Pro 返回的项目与原项目不符，未记录本次结果。") }
                record.premiereProjectID = result.projectID; record.premiereProjectName = result.project
                let received = Set(result.receivedPaths)
                record.failedPaths = Set(result.failedPaths + record.mediaPaths.filter { !received.contains($0) }).sorted()
                record.warnings = result.warnings
                record.state = !record.failedPaths.isEmpty ? .failed : record.warnings.isEmpty ? .completed : .needsAttention
                record.message = "“\(result.project)”：" + (result.created == true ? "已新建项目，" : "")
                    + "已加入 \(result.imported) 个，已存在 \(result.skipped) 个"
                    + (record.failedPaths.isEmpty ? "" : "；\(record.failedPaths.count) 个未加入")
                    + (record.warnings.isEmpty ? "" : "；代理或标记需检查")
            } else {
                // 脚本按项目名找到或新建 Resolve 项目；第一次发送后记下它，重试只认这个项目。
                let expected = record.resolveProjectID.map { ResolveBridge.Project(id: $0, name: record.resolveProjectName ?? "") }
                let result = try await videoDeliveryServices.sendResolve(record.payload, expected)
                if let expected, result.projectID != expected.id { throw VideoDelivery.Failure("Resolve 返回的项目与原项目不符，未记录本次结果。") }
                record.resolveProjectID = result.projectID; record.resolveProjectName = result.project
                let received = Set(result.receivedPaths)
                record.failedPaths = Set(result.failedPaths + record.mediaPaths.filter { !received.contains($0) }).sorted()
                record.warnings = result.timecodeWarnings + result.metadataWarnings
                if result.unmanaged > 0 { record.warnings.append("项目未启用色彩管理，\(result.unmanaged) 个片段的输入色彩空间尚未设置。") }
                record.state = !record.failedPaths.isEmpty ? .failed : record.warnings.isEmpty ? .completed : .needsAttention
                record.message = "“\(result.project)”：" + (result.created == true ? "已新建项目，" : "")
                    + "已加入 \(result.imported) 个，已存在 \(result.skipped) 个"
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
