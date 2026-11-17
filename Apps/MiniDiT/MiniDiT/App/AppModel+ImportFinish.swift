import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

// 导入收尾：记导入历史、写备份校验清单、按条件从卡上删除、汇总结果、交给后期软件、写完导入记录。

extension AppModel {

    func finishImport(_ run: ImportRun) async {
        let picked = run.picked
        let mode = run.mode
        recordImportHistory(run)
        writeBackupTargetReports(run)
        for r in run.reports { log.add("校验清单：\(r.path)") }
        let finishedIDs = Set(run.done.map(\.item.id))
        let savedBytes = partialBytes(run, finished: finishedIDs)
        let deletion = await deleteImportedFromCards(run)
        updateBackupProgress(run.token, final: true)
        let wasLost = lostDuringImport || (progress.map { !$0.failed.isEmpty } ?? false) && offline
        let done = run.done
        var summary = done.isEmpty && run.proxyOnlyDone > 0 ? String(localized: "导入 \(run.proxyOnlyDone) 个片段的代理")
            : run.proxyOnlyDone > 0 ? String(localized: "导入 \(done.count) 个文件、\(run.proxyOnlyDone) 个片段的代理")
            : String(localized: "导入 \(done.count) 个文件")
        if let p = progress, p.reused > 0 { summary += String(localized: "，其中 \(p.reused) 个使用本地已有文件") }
        if let p = progress, p.skipped > 0 { summary += String(localized: "，\(p.skipped) 个已存在于目标文件夹") }
        if let p = progress, !p.failed.isEmpty { summary += String(localized: "，\(p.failed.count) 个失败") }
        if let deleted = deletion.deleted { summary += String(localized: "，已从存储卡删除 \(deleted) 个") }
        if !importBackupProgress.isEmpty {
            let backups = importBackupProgress.map { String(localized: "\($0.target.name)：\($0.verified)/\($0.total) 个文件已校验") }
            summary += String(localized: "，\(backups.joined(separator: String(localized: "；")))")
        } else {
            summary += String(localized: "，未备份")
        }
        for note in run.lookNotes { summary += String(localized: "，\(note)") }
        if Task.isCancelled { summary += String(localized: "（已取消）") }
        lastBatch = run.saved
        lastFolders = Self.importFolders(photos: done.filter { $0.item.kind != .video }.map(\.url),
                                         videos: done.filter { $0.item.kind == .video }.map(\.url))
        let sessionNames = Set(run.captureOneFiles.keys.map(\.name)).sorted()
        let sessionText = sessionNames.isEmpty ? nil : sessionNames.joined(separator: String(localized: "”“"))
        let lightroomText = run.lightroomCollections.isEmpty ? nil : run.lightroomCollections.joined(separator: String(localized: "”“"))
        var openedText: String?
        var c1Failed = false
        if mode == .newSession {
            if let sessionText { summary += String(localized: "，已存入会话“\(sessionText)”的 Capture 文件夹") }
            if !Task.isCancelled, !wasLost, !run.captureOneFiles.isEmpty {
                let handoff = await finishCaptureOneSessions(run.captureOneFiles)
                summary += handoff.message
                pendingCaptureOneSessions = handoff.failed
                c1Failed = !handoff.failed.isEmpty
            }
        } else if mode == .lightroom {
            if !run.lightroomJobs.isEmpty {
                summary += lightroomText.map { String(localized: "，已交由 Lightroom Classic 导入（收藏夹“\($0)”）") }
                    ?? String(localized: "，已交由 Lightroom Classic 导入")
                watchLightroom(run.lightroomJobs)
            }
        } else if mode != .off && !run.saved.isEmpty {
            summary += await sendToCaptureOne(run.saved, inPlace: mode == .inPlace)
        } else if mode == .off && !Task.isCancelled && !lastFolders.isEmpty {
            // DxO 打开文件夹时读 RAW 旁边的 .dop，所以先写好再打开。
            if openAfterImport == .dxo && applyCreativeLook { summary += applyDxOLooks(done.map(\.url)) }
            openedText = openFolders(lastFolders, in: openAfterImport)
            if let openedText { summary += openedText }
        }
        if mode != .newSession && mode != .off && mode != .lightroom && !run.saved.isEmpty { c1Failed = summary.contains(Self.captureOneImportFailedText) }
        lastSummary = summary
        if wasLost {
            interrupted = Interrupted(done: done.count, total: picked.count, sessions: mode.namesGroups ? run.opened : [:],
                                      grouping: run.grouping, savedBytes: savedBytes,
                                      jobs: run.jobs.compactMap { original in
                                          var job = original
                                          job.files.removeAll { finishedIDs.contains($0.id) }
                                          if let resumed = run.opened[job.key] { job.session = resumed.session }
                                          return job.files.isEmpty ? nil : job
                                      }, captureOneFiles: run.captureOneFiles)
        } else {
            lastResult = ImportResult(files: done.count, reused: progress?.reused ?? 0, failed: progress?.failed.count ?? 0,
                                      session: mode == .newSession ? sessionText : nil,
                                      c1Failed: c1Failed, cancelled: Task.isCancelled,
                                      backedUp: run.backupRoot == nil ? nil : progress?.backedUp ?? 0,
                                      backupFailed: progress?.backupFailed.count ?? 0,
                                      deleted: deletion.deleted, keptOnCard: deletion.deleted.map { deletion.cardFiles - $0 } ?? 0,
                                      deleteFailed: deletion.failed, cardReadOnly: deletion.cardReadOnly,
                                      resumed: progress?.resumedFiles ?? 0, savedBytes: savedBytes, reports: run.reports,
                                      lightroom: mode == .lightroom ? lightroomText : nil, opened: openedText,
                                      proxyOnly: run.proxyOnlyDone, hasWiFiSource: run.hasWiFiSource)
        }
        log.add("导入结束：\(summary)")
        // 全部文件都导好的拍摄取消选中。
        let doneIDs = Set(done.map(\.item.id))
        grid.remove(run.pickedShots.filter { id in shots[id].map { importFiles(of: $0).allSatisfy(doneIDs.contains) } ?? false })
        let finalized = await finalizeImportJournal(run, wasLost: wasLost, c1Failed: c1Failed)
        if let error = run.journal.persistenceError { errorMessage = error }
        updateBackupProgress(run.token)
        if lastResult != nil { lastResult?.backupTargets = importBackupProgress }
        progress = nil
        refreshCopies()
        rebuild()
        importTask = nil
        if finalized { queueVideoDeliveries(batchID: run.token) }
        if autoRunning { autoImportFinished() }
        // 删了卡上的文件：重新列一遍卡。
        if let deleted = deletion.deleted, deleted > 0 { await loadAll(restoring: selectedKeys(), days: shownDays) }
    }

    /// 导入记录按机身分开记（读卡器的没有机身 ID），并记进软件会话，之后在侧栏点开会话能看到。
    private func recordImportHistory(_ run: ImportRun) {
        for (cam, entries) in Dictionary(grouping: run.done, by: { camera(of: $0.item.id) }) {
            ImportHistory.shared.record(entries, camera: cam)
        }
        for job in run.jobs {
            guard let sid = job.appSession else { continue }
            let ids = Set(job.files.map(\.id))
            recordSessionFiles(run.done.filter { ids.contains($0.item.id) }.map(\.url), in: sid)
        }
    }

    /// 每个备份目标各写一份 MHL，只列已在该目标上校验过的副本。
    private func writeBackupTargetReports(_ run: ImportRun) {
        guard let batch = run.journal.batches.first(where: { $0.id == run.token }) else { return }
        for target in batch.targets {
            let entries = batch.files.flatMap(\.assets).compactMap { asset -> MHLWriter.Entry? in
                guard let hash = asset.xxh64.flatMap({ UInt64($0, radix: 16) }),
                      let copy = asset.copies.last(where: { $0.role == .backup && $0.targetID == target.id && $0.verifiedAt != nil }) else { return nil }
                return .init(url: URL(filePath: copy.path), xxh64: hash, action: .verified)
            }
            guard !entries.isEmpty else { continue }
            do {
                guard target.availability == .available else { throw BackupRepair.Failure.targetUnavailable }
                run.reports.append(try MHLWriter.append(root: target.root, entries: entries))
            } catch {
                progress?.backupFailed.append(String(localized: "\(target.name)（校验清单）"))
                log.add("写备份清单失败 \(target.name)：\(error.localizedDescription)")
                _ = run.journal.update(run.token) { b in
                    if b.backupReportErrors == nil { b.backupReportErrors = [:] }
                    b.backupReportErrors?[target.id.uuidString] = error.localizedDescription
                }
            }
        }
    }

    /// 没导完的文件里，已经传了一部分、留着续传的有多少字节。
    private func partialBytes(_ run: ImportRun, finished: Set<UInt32>) -> UInt64 {
        var savedBytes: UInt64 = 0
        for job in run.jobs {
            var dir = run.opened[job.key]?.captureOneTarget?.captureDir
            if dir == nil, case .resolved(let target) = job.session { dir = target.captureDir }
            for f in job.files where !finished.contains(f.id) {
                let layout = job.plan?.organization ?? run.plan.organization
                let planned = layout.folder(for: f, root: f.kind == .video ? run.videoRoot : run.root,
                                            sessionName: job.folder, event: job.event, scene: job.scene,
                                            roll: RollStore.shared.roll(of: f))
                let folder = f.kind == .video ? planned : dir ?? planned
                savedBytes += FileImporter.savedPartBytes(f, in: importSubfolder(folder, f, run))
            }
        }
        return savedBytes
    }

    private struct CardDeletion {
        /// nil = 没有要求删除。
        var deleted: Int?
        var failed = 0
        var cardReadOnly = false
        /// 读卡器来源上的文件数（算「留在卡上」用）。
        var cardFiles: Int
    }

    /// 导入后从存储卡删除：只删读卡器来源上的（Wi-Fi 相机不能删），并且要和卡上数据核对过；
    /// 要求备份时，每个必需的备份目标都已校验成功。
    private func deleteImportedFromCards(_ run: ImportRun) async -> CardDeletion {
        let picked = run.picked
        var result = CardDeletion(cardFiles: picked.count)
        guard run.deleteRequested else { return result }
        var n = 0
        for h in run.deletable {
            if Task.isCancelled { break }
            if run.wantsBackup {
                guard run.plan.runBackups,
                      let batch = run.journal.batches.first(where: { $0.id == run.token }), !batch.targets.isEmpty,
                      let file = batch.files.first(where: { $0.id.hasSuffix("|\(h)") }) else { continue }
                let required = batch.targets.filter(\.required)
                let needed = required.isEmpty ? batch.targets : required
                guard file.assets.allSatisfy({ asset in needed.allSatisfy { asset.hasBackup(at: $0) && asset.error(for: $0) == nil } }) else { continue }
            }
            guard let r = route(h), let card = r.library as? LocalCardLibrary else { continue }
            if (try? card.root.resourceValues(forKeys: [.volumeIsReadOnlyKey]).volumeIsReadOnly) ?? false {
                result.cardReadOnly = true
                continue
            }
            let filename = items[h]?.filename ?? ""
            progress?.current = String(localized: "删除存储卡上的 \(filename)")
            do { try await card.delete(r.local); n += 1 }
            catch { result.failed += 1; log.add("删除失败 \(items[h]?.filename ?? "\(h)")：\(error.localizedDescription)") }
        }
        if result.cardReadOnly { log.add("存储卡是只读的，有文件没有删除") }
        log.add("从存储卡删除了 \(n) 个文件；\(picked.count - n) 个保留")
        result.deleted = n
        result.cardFiles = picked.filter { route($0.id)?.library is LocalCardLibrary }.count
        return result
    }

    /// 保存后期发送计划，写完这批导入的最终状态。没导成的文件标为失败并写明原因。
    private func finalizeImportJournal(_ run: ImportRun, wasLost: Bool, c1Failed: Bool) async -> Bool {
        let mode = run.mode
        var videoDeliveries: [VideoDelivery] = []
        do { videoDeliveries = try await makeVideoDeliveries(events: run.videoEvents, batchID: run.token, plan: run.plan) }
        catch { log.add("保存后期发送计划失败：" + error.localizedDescription); errorMessage = error.localizedDescription }
        if Task.isCancelled {
            videoDeliveries = videoDeliveries.map { var record = $0; record.state = .failed; record.message = "导入已取消，未向后期软件发送；可使用已保存的文件重试。"; return record }
        }
        let journal = run.journal
        let hasCaptureOneFiles = !run.captureOneFiles.isEmpty
        let hasSaved = !run.saved.isEmpty
        let cancelled = Task.isCancelled
        let reportPaths = run.reports.map(\.path)
        return journal.update(run.token) { batch in
            batch.videoDeliveries = videoDeliveries.isEmpty ? nil : videoDeliveries
            for record in videoDeliveries { batch.delivery[record.software.name] = record.message }
            batch.finishedAt = Date()
            batch.state = wasLost || journal.persistenceError != nil ? .interrupted : cancelled ? .cancelled : .completed
            batch.reports = reportPaths
            if mode == .newSession, hasCaptureOneFiles {
                if c1Failed { batch.delivery["Capture One"] = "部分会话未能打开。照片已保存至本地。" }
                else if wasLost || cancelled { batch.delivery["Capture One"] = "照片已保存至本地，等待整批下载完成。" }
                else { batch.delivery["Capture One"] = "下载完成后已打开会话。" }
            } else if mode != .off && mode != .lightroom && hasSaved {
                batch.delivery["Capture One"] = c1Failed ? "软件接收失败。文件已保存在本地。" : "文件已发送，请在 Capture One 中确认接收。"
            }
            for i in batch.files.indices where batch.files[i].state == .pending {
                batch.files[i].state = .failed
                batch.files[i].message = batch.files[i].message ?? (wasLost ? "来源连接中断，文件未保存" : cancelled ? "导入已取消，文件未保存" : "文件未完成导入")
            }
        }
    }
}
