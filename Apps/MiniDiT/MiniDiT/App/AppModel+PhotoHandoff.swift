import AppKit
import Dispatch
import Foundation
import MiniDiTCore
import SonyRemoteKit


// 照片交给后期：Capture One 会话、星级和创意外观，Lightroom Classic 插件回执。

extension AppModel {
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

    func finishCaptureOneSessions(_ files: [CaptureOneBridge.SessionTarget: [URL]]) async
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

    func sendToCaptureOne(_ urls: [URL], inPlace: Bool) async -> String {
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
