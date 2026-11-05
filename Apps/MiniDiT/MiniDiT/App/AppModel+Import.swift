import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {

    // MARK: 导入

    func refreshCaptureOne() {
        captureOneDocument = CaptureOneBridge.currentDocument()
    }

    /// 点「导入」：没有备份盘先提醒；新建会话模式先问会话名，其他模式直接开始。
    func beginImport(checkBackup: Bool = true) {
        guard progress == nil, !grid.selected.isEmpty else { return }
        if checkBackup, !backupAvailable {
            backupMissingPrompt = true
            return
        }
        if captureOneMode == .newSession {
            refreshCaptureOne()
            sessionRequest = SessionRequest(suggestedName: suggestedSessionName(),
                                            existing: Array(CaptureOneBridge.sessions(in: sessionsFolder).prefix(15)))
        } else {
            startImport(session: nil)
        }
    }

    func startImport(session: SessionChoice?) {
        sessionRequest = nil
        interrupted = nil
        lastResult = nil
        lostDuringImport = false
        guard let library, progress == nil else { return }
        let picked = Array(selectedFiles().reversed())  // 旧的先导
        guard !picked.isEmpty else { return }
        let pickedShots = grid.selected
        let root = destination
        let mode = captureOneMode
        let camera = cameraID
        let backupRoot = backupAvailable ? backupFolder : nil
        let weight: UInt64 = backupRoot == nil ? 1 : 2
        progress = ImportProgress(total: picked.count, bytesTotal: picked.reduce(0) { $0 + $1.size } * weight)
        lastSummary = nil
        log.add("开始导入 \(picked.count) 个文件到 \(root.path)，Capture One：\(mode.title)，"
                + (backupRoot.map { "备份到 \($0.path)" } ?? "没有备份"))
        let sessionsFolder = self.sessionsFolder
        importTask = Task {
            // 新建 / 打开会话，文件直接下载到它的 Capture 文件夹（C1 会自动显示，不用再导入）。
            var captureDir: URL?
            var sessionName = ""
            if mode == .newSession, let session {
                status = "正在准备 Capture One 会话…"
                do {
                    switch session {
                    case .new(let name):
                        sessionName = name
                        rememberContent(of: name)
                        captureDir = try await CaptureOneBridge.createSession(name: name, in: sessionsFolder)
                    case .existing(let file):
                        sessionName = file.deletingPathExtension().lastPathComponent
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
                    errorMessage = "Capture One 新建会话失败：\(error.localizedDescription)\n照片会先存到 \(dir.path)。"
                }
                status = ""
                refreshCaptureOne()
            }
            var saved: [URL] = []
            var done: [ImportHistory.Entry] = []
            let event = sessionName.isEmpty ? nil : Self.eventName(of: sessionName)
            let importer = FileImporter(library: library, root: root, camera: camera, backupRoot: backupRoot, event: event)
            for item in picked {
                if Task.isCancelled { break }
                progress?.current = "导入 \(item.filename)"
                let dir = captureDir ?? FileImporter.folder(for: item, root: root)
                let base = progress?.bytesDone ?? 0
                do {
                    let r = try await importer.importItem(item, into: dir, progress: { d in
                        Task { @MainActor in
                            if let cur = self.progress?.bytesDone, base + d > cur { self.progress?.bytesDone = base + d }
                        }
                    }, stage: { self.progress?.current = $0 })
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
                    done.append(.init(item: item, url: r.outcome.url, xxh64: r.xxh64, backup: backupURL))
                } catch is CancellationError {
                    break
                } catch {
                    if error is PTPIPTransportError { progress?.failed.append(item.filename); lostDuringImport = true; break }
                    log.add("导入失败 \(item.filename)：\(error.localizedDescription)")
                    progress?.failed.append(item.filename)
                }
            }
            ImportHistory.shared.record(done, camera: camera)
            let wasLost = lostDuringImport || (progress.map { !$0.failed.isEmpty } ?? false) && offline
            var summary = "导入 \(done.count) 个文件"
            if let p = progress, p.reused > 0 { summary += "，其中 \(p.reused) 个用了本地已有的" }
            if let p = progress, p.skipped > 0 { summary += "，\(p.skipped) 个目标文件夹里已有" }
            if let p = progress, !p.failed.isEmpty { summary += "，\(p.failed.count) 个失败" }
            if let p = progress, backupRoot != nil {
                summary += "，备份 \(p.backedUp) 个" + (p.backupFailed.isEmpty ? "" : "（\(p.backupFailed.count) 个备份失败）")
            } else {
                summary += "，没有备份"
            }
            if Task.isCancelled { summary += "（已取消）" }
            lastBatch = saved
            if mode == .newSession {
                if !sessionName.isEmpty { summary += "，已存入会话「\(sessionName)」" }
            } else if mode != .off && !saved.isEmpty {
                summary += await sendToCaptureOne(saved, inPlace: mode == .inPlace)
            }
            var c1Failed = false
            if mode != .newSession && mode != .off && !saved.isEmpty { c1Failed = summary.contains("Capture One 导入失败") }
            lastSummary = summary
            if wasLost {
                let resume: SessionChoice? = captureDir.map { .resolved(captureDir: $0, name: sessionName) }
                interrupted = Interrupted(done: done.count, total: picked.count, session: mode == .newSession ? resume : nil)
            } else {
                lastResult = ImportResult(files: done.count, reused: progress?.reused ?? 0, failed: progress?.failed.count ?? 0,
                                          session: mode == .newSession && !sessionName.isEmpty ? sessionName : nil,
                                          c1Failed: c1Failed, cancelled: Task.isCancelled,
                                          backedUp: backupRoot == nil ? nil : progress?.backedUp ?? 0,
                                          backupFailed: progress?.backupFailed.count ?? 0)
            }
            log.add("导入结束：\(summary)")
            // 全部文件都导好的拍摄取消选中。
            let doneIDs = Set(done.map(\.item.id))
            grid.remove(pickedShots.filter { id in shots[id].map { importFiles(of: $0).allSatisfy(doneIDs.contains) } ?? false })
            progress = nil
            rebuild()
            importTask = nil
        }
    }

    func cancelImport() { importTask?.cancel() }

    /// 会话名「3.15-公园」里的「公园」；没有「-」就用整个名字。
    static func eventName(of sessionName: String) -> String? {
        let s = sessionName.firstIndex(of: "-").map { String(sessionName[sessionName.index(after: $0)...]) } ?? sessionName
        let t = s.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// 中断后继续：导到同一个会话，不再问名字。
    func continueImport() {
        guard !offline, let i = interrupted else { return }
        if i.session == nil, captureOneMode == .newSession { beginImport(); return }
        startImport(session: i.session)
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
            let target = captureOneDocument.map { "\($0.kind)「\($0.name)」" } ?? "Capture One"
            log.add("已交给 \(target) 导入 \(urls.count) 个文件")
            return "，已交给 \(target) 导入"
        } catch {
            log.add("Capture One 导入失败：\(error.localizedDescription)")
            errorMessage = "文件已下载到文件夹，但交给 Capture One 失败：\(error.localizedDescription)"
            return "，Capture One 导入失败"
        }
    }
}
