import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

struct AgentPreparedImport {
    var expires: Date
    var fingerprint: AgentJSON
    var job: AppModel.ImportJob
    var batchID: UUID?
}

extension AppModel {
    func startAgentControl(path: String = AgentSocket.path) {
        guard agentServer == nil else { return }
        do {
            agentServer = try AgentSocketServer(path: path) { [weak self] request in
                guard let self else { return .init(id: request.id, error: .init("app_closed", String(localized: "MiniDiT 已关闭。"))) }
                let started = Date()
                let response: AgentControlResponse
                do {
                    guard request.version == 1 else { throw AgentControlError("unsupported_version", String(localized: "不支持的本地接口版本。")) }
                    response = .init(id: request.id, result: try await self.agentCallAsync(request.method, params: request.params))
                } catch let error as AgentControlError { response = .init(id: request.id, error: error) }
                catch { response = .init(id: request.id, error: .init("operation_failed", error.localizedDescription)) }
                // 联机拍摄的每条命令和结果写一行 JSONL（CLI 和 MCP 都经过这里）。
                if let method = AgentTools.find(request.method)?.method, method.hasPrefix("tether.") {
                    TetherCommandLog.append(method: method, params: request.params, response: response, started: started)
                }
                return response
            }
            log.add("Agent 本地接口已启用（仅当前用户）")
        } catch { log.add("Agent 本地接口未启动：\(error.localizedDescription)") }
    }

    /// 需要等相机回应的操作（回读确认、拍完等文件）走这里，其余照旧同步处理。
    func agentCallAsync(_ method: String, params p: AgentJSON = .object([:])) async throws -> AgentJSON {
        guard let tool = AgentTools.find(method) else { throw AgentControlError("unknown_method", String(localized: "未知操作：\(method)")) }
        guard ["tether.properties", "tether.get", "tether.set_properties", "tether.capture",
               "tether.files", "tether.download", "tether.record_clip", "tether.stop", "tether.mode", "tether.custom_wb", "tether.touch", "tether.focus_position", "tether.magnifier", "tether.lens_info"].contains(tool.method) else {
            return try agentCall(method, params: p)
        }
        try tool.validate(p)
        if !tool.readOnly { log.add("Agent 操作：\(tool.method)") }
        return try await agentTetherAsync(tool.method, p)
    }

    func agentCall(_ method: String, params p: AgentJSON = .object([:])) throws -> AgentJSON {
        guard let tool = AgentTools.find(method) else { throw AgentControlError("unknown_method", String(localized: "未知操作：\(method)")) }
        try tool.validate(p)
        if !tool.readOnly { log.add("Agent 操作：\(tool.method)") }
        switch tool.method {
        case "app.status": return agentStatus()
        case "projects.list":
            return .object(["selectedProjectId": .optional(currentSession?.id.uuidString), "projects": try .encoded(sortedSessions)])
        case "projects.create":
            try agentIdle()
            let raw = p["date"].string!, day = raw.replacingOccurrences(of: "-", with: "")
            guard raw.count == 10, raw[raw.index(raw.startIndex, offsetBy: 4)] == "-", raw[raw.index(raw.startIndex, offsetBy: 7)] == "-",
                  day.count == 8, day.allSatisfy(\.isNumber), let date = ShootSession.date(day), ShootSession.dayKey(date) == day else {
                throw AgentControlError("invalid_params", String(localized: "日期格式应为有效的 YYYY-MM-DD。"))
            }
            let photoRoot = try p["photoRoot"].string.map(agentDirectory)
            let videoRoot = try p["videoRoot"].string.map(agentDirectory)
            if let photoRoot {
                if captureOneMode == .newSession { sessionsFolder = photoRoot } else { destination = photoRoot }
            }
            if let videoRoot { videoDestination = videoRoot }
            let project = createSession(day: day, event: p["event"].string.map(NameTemplate.sanitize),
                                        content: p["content"].string.flatMap(ImportContent.init(rawValue:)) ?? .all)
            return try .encoded(project)
        case "projects.select":
            try agentIdle()
            let id = try agentUUID(p["id"])
            guard sessions.contains(where: { $0.id == id }) else { throw AgentControlError("not_found", String(localized: "项目不存在。")) }
            selectSession(id)
            return agentStatus()
        case "sources.list":
            return .object(["sources": .array(sources.map { source in .object([
                "id": .integer(source.id), "name": .string(source.name), "detail": .string(source.detail),
                "kind": .string(source.isCard ? "card" : "camera"), "offline": .bool(source.offline),
                "connectionId": .string(connectionID(for: source.id).uuidString)
            ]) }), "availableCards": .array(cards.map { .string($0.path) })])
        case "sources.connect":
            try agentIdle()
            let host = p["host"].string!
            guard !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }), host.utf8.count <= 253 else { throw AgentControlError("invalid_params", String(localized: "请输入不含凭据的主机名或 IP。")) }
            guard phase == .idle || phase == .ready else { throw AgentControlError("busy", String(localized: "设备正在连接或读取。")) }
            if phase == .idle { connect(host: host) } else { addCamera(host: host) }
            return agentStatus()
        case "sources.open_card":
            try agentIdle()
            let root = try agentDirectory(p["path"].string!)
            guard LocalCardLibrary.looksLikeCard(root) else { throw AgentControlError("invalid_source", String(localized: "目录中未发现相机存储卡结构。")) }
            guard phase == .idle || phase == .ready else { throw AgentControlError("busy", String(localized: "设备正在连接或读取。")) }
            if phase == .idle { openCard(root) } else { addCard(root) }
            return agentStatus()
        case "sources.refresh":
            try agentReady()
            guard previewShot == nil else { throw AgentControlError("busy", String(localized: "请先关闭素材预览。")) }
            refreshSources()
            return agentStatus()
        case "sources.disconnect":
            try agentIdle()
            guard interrupted == nil else { throw AgentControlError("pending_import", String(localized: "请先继续或取消待续传任务。")) }
            disconnect()
            return agentStatus()
        case "assets.filter":
            try agentReady()
            // Validate the whole request before changing any settings or selection.
            let requestedDays = p["days"].array?.compactMap(\.string)
            if let requestedDays {
                let known = Set(allShots.compactMap { items[$0.primary].map(Self.dayKey) })
                guard Set(requestedDays).isSubset(of: known) else { throw AgentControlError("invalid_params", String(localized: "日期不在当前来源中；请使用 YYYYMMDD。")) }
            }
            if let value = p["onlyNew"].bool { onlyNew = value }
            if let value = p["query"].string { mediaFilter.query = value }
            if let value = p["mark"].string { mediaFilter.mark = MediaFilter.Mark(rawValue: value)! }
            if let requestedDays { shownDays = requestedDays.isEmpty ? Set(days.map(\.id)) : Set(requestedDays) }
            return agentAssets(offset: 0, limit: 50)
        case "assets.list": return agentAssets(offset: p["offset"].int ?? 0, limit: p["limit"].int ?? 50)
        case "assets.select":
            try agentReady()
            var ids = Set<UInt32>()
            for element in p["ids"].array! {
                guard let number = element.int, let id = UInt32(exactly: number) else { throw AgentControlError("invalid_params", String(localized: "素材 ID 超出范围。")) }
                ids.insert(id)
            }
            let mode = p["mode"].string ?? "replace"
            let allowed = mode == "remove" ? Set(allShots.map(\.id)) : Set(grid.order)
            guard ids.isSubset(of: allowed) else { throw AgentControlError("invalid_selection", String(localized: "素材不在当前筛选范围，请先调用 assets.filter 调整范围。")) }
            switch mode {
            case "add": grid.set(ids, selected: true)
            case "remove": grid.set(ids, selected: false)
            default: grid.replace(with: ids)
            }
            return agentStatus()
        case "import.preview":
            try agentPreflight(allowDelete: p["allowDeleteOriginals"].bool == true)
            guard var job = currentSessionJob() else { throw AgentControlError("project_required", String(localized: "请先选择或新建项目。")) }
            job.plan = importPlan
            let token = UUID().uuidString
            agentPlans = agentPlans.filter { $0.value.expires > .now }
            guard agentPlans.count < 16 else { throw AgentControlError("too_many_plans", String(localized: "预览过多，请执行已有计划或稍后重试。")) }
            let expires = Date().addingTimeInterval(300)
            agentPlans[token] = .init(expires: expires, fingerprint: agentImportFingerprint(), job: job)
            var paths: [String: AgentJSON] = [:]
            for file in job.files {
                let roll = file.kind == .video ? (RollStore.shared.roll(of: file) ?? "〈卷号〉") : nil
                let folder = plannedFolder(for: file, roll: roll).path
                paths[(file.kind == .video ? "video:" : "photo:") + folder] = .string(folder)
            }
            return .object(["planId": .string(token), "expiresAt": try .encoded(expires),
                "project": try .encoded(currentSession!), "shots": .integer(grid.selected.count), "files": .integer(job.files.count),
                "bytes": .integer(selectionBytes(of: job.files)), "destinations": .array(paths.sorted { $0.key < $1.key }.map(\.value)),
                "backupRoot": .optional(job.plan?.backupRoot?.path), "backupTargets": try .encoded(job.plan?.backupTargets ?? []), "photoSoftware": .string(captureOneMode.rawValue),
                "proxyOnlyWiFi": .bool(proxyOnlyWiFi), "deleteOriginals": .bool(willDeleteFromSource)])
        case "import.start":
            let token = p["planId"].string!
            guard var prepared = agentPlans[token] else { throw AgentControlError("plan_not_found", String(localized: "计划不存在，请先预览导入。")) }
            if let id = prepared.batchID { return .object(["batchId": .string(id.uuidString), "alreadyStarted": .bool(true)]) }
            guard prepared.expires > .now else { throw AgentControlError("plan_expired", String(localized: "计划已过期，请重新预览。")) }
            guard prepared.fingerprint == agentImportFingerprint() else { throw AgentControlError("plan_changed", String(localized: "项目、选择、设备或设置已变化，请重新预览。")) }
            try agentPreflight(allowDelete: true) // Deletion preference was explicitly acknowledged by this frozen preview.
            errorMessage = nil
            startImport(jobs: [prepared.job], grouping: .single)
            guard progress != nil else { throw AgentControlError("import_not_started", errorMessage ?? String(localized: "导入未开始。")) }
            prepared.batchID = deliveryID; agentPlans[token] = prepared
            return .object(["batchId": .string(deliveryID.uuidString), "alreadyStarted": .bool(false)])
        case "import.cancel":
            if progress != nil { cancelImport() } else if interrupted != nil { dismissInterrupted() }
            return agentStatus()
        case "import.resume":
            try agentReady()
            guard let pending = interrupted, !pending.jobs.isEmpty else { throw AgentControlError("no_interrupted_import", String(localized: "没有待续传任务。")) }
            if willDeleteFromSource, p["allowDeleteOriginals"].bool != true { throw AgentControlError("deletion_acknowledgement_required", String(localized: "当前开启删除原片，请明确指定 allowDeleteOriginals。")) }
            continueImport()
            guard progress != nil else { throw AgentControlError("import_not_started", errorMessage ?? String(localized: "无法继续导入。")) }
            return .object(["batchId": .string(deliveryID.uuidString)])
        case "imports.list":
            let project = try p["projectId"].string.map { _ in try agentUUID(p["projectId"]) }
            let batches = importJournal.batches.filter { project == nil || $0.files.contains { $0.projectID == project } }.sorted { $0.startedAt > $1.startedAt }
            let offset = p["offset"].int ?? 0, limit = p["limit"].int ?? 20
            return .object(["total": .integer(batches.count), "offset": .integer(offset),
                "batches": .array(try batches.dropFirst(offset).prefix(limit).map(agentBatchSummary))])
        case "imports.get":
            let id = try agentUUID(p["id"])
            guard let batch = importJournal.batches.first(where: { $0.id == id }) else { throw AgentControlError("not_found", String(localized: "导入批次不存在。")) }
            var summary = try agentBatchSummary(batch).object!
            let offset = p["offset"].int ?? 0, limit = p["limit"].int ?? 50
            summary["offset"] = .integer(offset)
            summary["files"] = try .encoded(Array(batch.files.dropFirst(offset).prefix(limit)))
            return .object(summary)
        case let m where m.hasPrefix("tether."): return try agentTether(m, p)
        default: throw AgentControlError("unknown_method", String(localized: "此操作由 CLI 客户端处理。"))
        }
    }

    private func agentStatus() -> AgentJSON {
        var pending: [AgentJSON] = []
        if credentialRequest != nil { pending.append(.string("camera_credentials_in_app")) }
        if fingerprintRequest != nil { pending.append(.string("camera_fingerprint_in_app")) }
        if newSessionPrompt != nil { pending.append(.string("new_project_in_app")) }
        if backupMissingPrompt { pending.append(.string("backup_unavailable")) }
        if spaceProblem != nil { pending.append(.string("insufficient_space")) }
        if lightroomPrompt != nil { pending.append(.string("lightroom_setup_in_app")) }
        var info: [String: AgentJSON] = ["phase": .string(String(describing: phase)), "refreshing": .bool(isRefreshingSources),
            "projectId": .optional(currentSession?.id.uuidString), "projectName": .optional(currentSession?.name),
            "selectedShots": .integer(grid.selected.count), "selectedFiles": .integer(selectedFiles().count),
            "sourceCount": .integer(openSources.count), "pendingInteraction": .array(pending), "metadataLoading": .bool(metadataLoading),
            "filters": .object(["content": .string(importContent.rawValue), "onlyNew": .bool(onlyNew), "query": .string(mediaFilter.query),
                "mark": .string(mediaFilter.mark.rawValue), "raw": .bool(showRaw), "jpeg": .bool(showPhotos), "days": .array(shownDays.sorted().map(AgentJSON.string))]),
            "error": .optional(errorMessage), "hasInterruptedImport": .bool(interrupted != nil),
            "repairingBackup": .bool(importJournal.repairTask != nil), "sendingVideo": .bool(videoDeliveryTask != nil), "backupTargets": (try? .encoded(enabledBackupTargets)) ?? .null,
            "repairProgress": .string(importJournal.repairProgress), "delivery": .object(deliveryMessages.mapValues(AgentJSON.string))]
        if let p = progress {
            info["progress"] = .object(["batchId": .string(deliveryID.uuidString), "total": .integer(p.total),
                "done": .integer(p.done + p.skipped + p.reused), "failed": .integer(p.failed.count),
                "bytesDone": .integer(p.bytesDone), "bytesTotal": .integer(p.bytesTotal), "current": .string(p.current),
                "backups": .array(importBackupProgress.map { .object(["id": .string($0.id.uuidString), "name": .string($0.target.name),
                    "verified": .integer($0.verified), "failed": .integer($0.failed), "total": .integer($0.total)]) })])
        } else { info["progress"] = .null }
        if let r = lastResult {
            info["lastResult"] = .object(["batchId": .string(deliveryID.uuidString), "saved": .integer(r.files),
                "failed": .integer(r.failed), "cancelled": .bool(r.cancelled), "backupFailed": .integer(r.backupFailed),
                "needsAttention": .bool(r.needsAttention)])
        }
        return .object(info)
    }

    private func agentAssets(offset: Int, limit: Int) -> AgentJSON {
        let visible = grid.order.compactMap { shots[$0] }
        return .object(["total": .integer(visible.count), "offset": .integer(offset), "days": .array(days.map { .string($0.id) }),
            "assets": .array(visible.dropFirst(offset).prefix(limit).map { shot in
                .object(["id": .integer(shot.id), "selected": .bool(grid.contains(shot.id)),
                    "kind": .string(shot.isVideo ? "video" : "photo"), "imported": .bool(isImported(shot: shot.id)),
                    "files": .array(importFiles(of: shot).compactMap { items[$0] }.map { item in
                        .object(["id": .integer(item.id), "filename": .string(item.filename), "bytes": .integer(item.size),
                            "sizeKnown": .bool(item.sizeKnown), "date": .string(Self.dayKey(item)), "sourceId": .integer(source(of: item.id))])
                    })])
            })])
    }

    private func agentBatchSummary(_ batch: ImportBatchRecord) throws -> AgentJSON {
        .object(["id": .string(batch.id.uuidString), "state": .string(batch.state.rawValue), "startedAt": try .encoded(batch.startedAt),
            "finishedAt": try .encoded(batch.finishedAt), "totalFiles": .integer(batch.files.count), "saved": .integer(batch.savedCount),
            "pendingBackup": .integer(batch.pendingBackupCount), "requiredBackupsComplete": .bool(batch.requiredBackupsComplete), "backupRoot": .optional(batch.backupRoot), "backupTargets": try .encoded(batch.targets),
            "backupStatus": .array(batch.targets.map { .object(["id": .string($0.id.uuidString), "verified": .integer(batch.verifiedCount(for: $0)),
                "pending": .integer(batch.pendingCount(for: $0)), "availability": .string($0.availability.rawValue)]) }),
            "projectIds": .array(Set(batch.files.compactMap(\.projectID)).map { .string($0.uuidString) }),
            "reports": .array(batch.reports.map(AgentJSON.string)), "delivery": .object(batch.delivery.mapValues(AgentJSON.string))])
    }
    func agentIdle() throws {
        guard progress == nil, importJournal.repairTask == nil, !isRefreshingSources, autoCountdown == nil else { throw AgentControlError("busy", String(localized: "正在传输、刷新、补备份或等待自动导入。")) }
    }
    private func agentReady() throws {
        try agentIdle()
        guard phase == .ready, !sourcesOffline, !openSources.isEmpty else { throw AgentControlError("source_not_ready", String(localized: "来源未就绪，请查询 app.status。")) }
    }
    private func agentPreflight(allowDelete: Bool) throws {
        try agentReady()
        guard currentSession != nil else { throw AgentControlError("project_required", String(localized: "请先选择或新建项目。")) }
        guard !selectedFiles().isEmpty else { throw AgentControlError("selection_required", String(localized: "请先选择素材。")) }
        guard credentialRequest == nil, fingerprintRequest == nil, newSessionPrompt == nil,
              !backupMissingPrompt, spaceProblem == nil, lightroomPrompt == nil else { throw AgentControlError("interaction_required", String(localized: "应用中有待处理提示，请先处理后重试。")) }
        if backupEnabled, !backupAvailable { throw AgentControlError("backup_unavailable", String(localized: "已启用备份，但备份位置不可用。")) }
        if let shortage = spaceShortage() { throw AgentControlError("insufficient_space", String(localized: "存储空间不足：\(shortage.folder.path)")) }
        if selectedFiles().contains(where: { $0.kind != .video }), captureOneMode == .lightroom,
           !LightroomBridge.status().canImport { throw AgentControlError("interaction_required", String(localized: "请先在应用中完成 Lightroom Classic 插件配置。")) }
        if willDeleteFromSource, !allowDelete { throw AgentControlError("deletion_acknowledgement_required", String(localized: "当前开启导入后删除原片；如需沿用，请明确指定 allowDeleteOriginals=true。")) }
    }
    private func agentUUID(_ value: AgentJSON) throws -> UUID {
        guard let text = value.string, let id = UUID(uuidString: text) else { throw AgentControlError("invalid_params", String(localized: "需要有效的 UUID。")) }
        return id
    }
    private func agentDirectory(_ text: String) throws -> URL {
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw AgentControlError("invalid_params", String(localized: "目录需要绝对路径。")) }
        let url = URL(filePath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { throw AgentControlError("invalid_path", String(localized: "目录不存在：\(path)")) }
        return url
    }
    private func agentImportFingerprint() -> AgentJSON {
        let plan = importPlan, rules = plan.organization
        return .object(["project": (try? .encoded(currentSession)) ?? .null,
            "files": .array(selectedFiles().map { item in .object(["id": .integer(item.id), "storage": .integer(item.storageID),
                "size": .integer(item.size), "name": .string(item.filename), "connection": .string(connectionID(for: source(of: item.id)).uuidString)]) }),
            "selection": .array(grid.selected.sorted().map(AgentJSON.integer)), "generation": .integer(libraryGeneration),
            "photoRoot": .string(plan.photoRoot.path), "videoRoot": .string(plan.videoRoot.path), "captureRoot": .string(plan.captureRoot.path),
            "backupRoot": .optional(plan.backupRoot?.path), "backupTargets": (try? .encoded(plan.backupTargets)) ?? .null, "runBackups": .bool(plan.runBackups), "backupEnabled": .bool(backupEnabled), "backupFollows": .bool(backupFollowsOrganization),
            "photoLayout": .string(rules.photos.rawValue), "videoLayout": .string(rules.videos.rawValue), "roll": .bool(rules.splitVideoByRoll),
            "backupTemplate": .string(rules.backupTemplate), "photoTemplate": .string(rules.photoTemplate), "videoTemplate": .string(rules.videoTemplate), "sessionTemplate": .string(rules.sessionTemplate),
            "captureOne": .string(captureOneMode.rawValue), "delete": .bool(willDeleteFromSource), "proxies": .bool(importProxies),
            "proxyOnly": .bool(proxyOnlyWiFi), "resolve": .bool(sendToResolve), "fcp": .bool(sendToFCP), "jianying": .bool(sendToJianying), "resolveColor": .bool(resolveColorSpace),
            "fcpLog": .bool(fcpLogProcessing), "fcpProjectAs": .string(fcpProjectAs.rawValue), "fcpEventLibrary": .string(fcpEventLibrary.path), "creativeLook": .bool(applyCreativeLook), "openAfter": .string(openAfterImport.rawValue),
            "splitBySlot": .bool(splitBySlot), "sourceFolders": .object(sourceFolders().reduce(into: [:]) { $0[String($1.key)] = .string($1.value) })])
    }
}
