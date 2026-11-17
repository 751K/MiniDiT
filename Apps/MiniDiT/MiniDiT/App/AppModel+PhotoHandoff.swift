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
        lightroomStatus = String(localized: "等待 Lightroom Classic 添加 \(total) 个文件…")
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
                    lightroomStatus = String(localized: "Lightroom Classic 无响应（已添加 \(done)/\(total)）。请打开 Lightroom Classic 并确认 MiniDiT 插件已启用，其余照片将继续添加")
                } else {
                    lightroomStatus = String(localized: "Lightroom Classic 已添加 \(done)/\(total)")
                }
            }
            guard !Task.isCancelled else { return }
            let added = sum.added + sum.skipped
            var s = String(localized: "Lightroom Classic 已添加 \(added) 个文件")
            if sum.skipped > 0 { s += String(localized: "（其中 \(sum.skipped) 个已在目录中）") }
            if sum.failed > 0 {
                s += String(localized: "，\(sum.failed) 个失败")
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
                lastSummary = String(localized: "Capture One\(handoff.message)")
                lastResult?.c1Failed = !handoff.failed.isEmpty
                updateDelivery("Capture One", message: lastSummary ?? "", failed: !handoff.failed.isEmpty, id: deliveryID)
            } else {
                let r = await sendToCaptureOne(lastBatch, inPlace: captureOneMode == .inPlace)
                lastSummary = String(localized: "重新导入 \(lastBatch.count) 个文件\(r)")
                lastResult?.c1Failed = r == Self.captureOneImportFailedText
            }
        }
    }

    func finishCaptureOneSessions(_ files: [CaptureOneBridge.SessionTarget: [URL]]) async
        -> (message: String, failed: [CaptureOneBridge.SessionTarget: [URL]]) {
        var message = ""
        var failed: [CaptureOneBridge.SessionTarget: [URL]] = [:]
        for target in files.keys.sorted(by: { $0.database.path < $1.database.path }) {
            let photos = files[target, default: []]
            progress?.current = String(localized: "正在打开 Capture One 会话…")
            do {
                try await CaptureOneBridge.openCompletedSession(target)
                message += String(localized: "，已打开 Capture One 会话“\(target.name)”")
                if applyCreativeLook, !photos.isEmpty {
                    progress?.current = String(localized: "正在套用 Capture One 创意外观…")
                    if let look = await applyLooks(photos, target: target) { message += look }
                }
                if let ratings = await applyRatings(photos, target: target) { message += ratings }
            } catch {
                failed[target] = photos
                message += String(localized: "，Capture One 会话“\(target.name)”未打开")
                log.add("打开 Capture One 会话失败：\(error.localizedDescription)")
                if !Task.isCancelled { errorMessage = String(localized: "照片已保存至 \(target.captureDir.path)。\n\(error.localizedDescription)") }
            }
        }
        refreshCaptureOne()
        return (message, failed)
    }

    /// 交由 Capture One 导入失败时返回的说明；导入结果据此判断是否失败。
    static var captureOneImportFailedText: String { String(localized: "，Capture One 导入失败") }

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
            let target = captureOneDocument.map { String(localized: "\($0.kindTitle)“\($0.name)”") } ?? "Capture One"
            log.add("已交给 \(target) 导入 \(urls.count) 个文件")
            return String(localized: "，已交由 \(target) 导入")
        } catch {
            log.add("Capture One 导入失败：\(error.localizedDescription)")
            errorMessage = String(localized: "文件已下载至文件夹，但交由 Capture One 导入失败：\(error.localizedDescription)")
            return Self.captureOneImportFailedText
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
        return String(localized: "，已设置星级 \(applied) 张")
    }

    /// 打开「对 RAW 自动加载创意外观」时，RAW 所属机型还没装 Lightroom / Capture One 的 Look 配置文件，就在后台下载安装。
    /// 不等下载完成：Lightroom Classic 和 Capture One 要重新启动才会读到新配置文件，本次导入用不上；装好后另行通知。
    /// 返回加在导入结果后面的说明；已经装好、正在安装或机型不支持时为 nil。
    func ensureLookPack(forRaw url: URL) -> String? {
        guard let model = LookPacks.model(ofRaw: url), let camera = LookPacks.camera(model: model) else { return nil }
        return startLookPackInstall(camera, parts: .lightroomAndCaptureOne,
                                    after: String(localized: "重新启动 Lightroom Classic 或 Capture One 后，此后导入的 RAW 将自动加载创意外观。"))
    }

    /// 本次运行中第一次遇到这台机型、这些软件的配置文件没装时，开始后台下载，返回说明；其余情况为 nil。
    func startLookPackInstall(_ camera: LookPacks.Camera, parts: LookPacks.Parts, after: String) -> String? {
        let tracker = LookPackTracker.shared, key = "\(camera.model)#\(parts.rawValue)"
        guard !tracker.known.contains(key) else { return nil }
        tracker.known.insert(key)
        guard !LookPacks.shared.isInstalled(camera, parts: parts) else { return nil }
        log.add("创意外观：开始在后台下载 \(camera.name) 的配置文件")
        Task { [weak self] in
            let outcome = await LookPacks.shared.ensure(model: camera.model, parts: parts)
            guard let self else { return }
            let notify = Bundle.main.bundleIdentifier != nil
            switch outcome {
            case .installed, .present:
                _ = LightroomLooks.installed(fresh: true)
                log.add("创意外观：已安装 \(camera.name) 的配置文件")
                if notify { Notifier.shared.post(id: "look-" + key, title: String(localized: "创意外观配置文件已安装"),
                    body: String(localized: "\(camera.name) 的创意外观配置文件已安装。\(after)"), info: [:]) }
            case .failed(let message):
                tracker.known.remove(key)
                log.add("创意外观：未能安装 \(camera.name) 的配置文件：\(message)")
                if notify { Notifier.shared.post(id: "look-" + key, title: String(localized: "未能安装创意外观配置文件"), body: message, info: [:]) }
            case .unsupported:
                break
            }
        }
        return String(localized: "正在后台下载 \(camera.name) 的创意外观配置文件，安装完成后将另行通知")
    }

    /// 用 DxO PhotoLab 打开前，给每张 RAW 写一份套好创意外观的 .dop。已有 .dop 的不动；
    /// 配置文件还没装的机型开始后台下载，这批照片不写，下次导入时生效。返回加在导入结果后面的说明。
    func applyDxOLooks(_ files: [URL]) -> String {
        let raws = files.filter { ["ARW", "SR2", "SRF"].contains($0.pathExtension.uppercased()) }.sorted { $0.path < $1.path }
        guard !raws.isEmpty else { return "" }
        guard let template = DxOLooks.template else { log.add("创意外观：缺少 DxO 模板文件"); return "" }
        var written = 0, kept = 0, unknown = 0, unsupported = 0, pending = 0, notes: [String] = []
        for raw in raws {
            guard let model = LookPacks.model(ofRaw: raw), let camera = LookPacks.camera(model: model) else { unsupported += 1; continue }
            guard let code = CreativeLook.code(ofRaw: raw) else {
                unknown += 1; log.add("创意外观：\(raw.lastPathComponent) 读到「\(CreativeLook.raw(raw) ?? "无")」，不认识，保持原样"); continue
            }
            let packs = LookPacks.shared, lut = packs.dxoLook(camera, code: code)
            guard packs.isInstalled(camera, parts: .dxo), FileManager.default.fileExists(atPath: lut.path) else {
                pending += 1
                if let note = startLookPackInstall(camera, parts: .dxo, after: String(localized: "此后导入并在 DxO PhotoLab 中打开的 RAW 将自动加载创意外观。")) { notes.append(note) }
                continue
            }
            do {
                switch try DxOLooks.writeSidecar(raw: raw, dcp: packs.dxoBase(camera), lut: lut, template: template) {
                case .written: written += 1
                case .kept: kept += 1
                }
            } catch {
                log.add("创意外观：未能写入 \(raw.lastPathComponent).dop：\(error.localizedDescription)")
            }
        }
        log.add("创意外观（DxO）：已写入 \(written) 张" + (kept > 0 ? "，\(kept) 张已有 DxO 设置" : "")
                + (unknown > 0 ? "，\(unknown) 张不认识" : "") + (unsupported > 0 ? "，\(unsupported) 张机型暂不支持" : "")
                + (pending > 0 ? "，\(pending) 张等待配置文件" : ""))
        var summary = written > 0 ? String(localized: "，DxO 创意外观已设置 \(written) 张") : ""
        if kept > 0 { summary += String(localized: "，\(kept) 张已有 DxO 设置，未更改") }
        for note in notes { summary += String(localized: "，\(note)") }
        return summary
    }

    /// 按创意外观设 C1 的 ICC 配置文件和曲线（只看 RAW：HIF / JPG 已经带着相机的外观）。
    /// C1 刚收到文件时可能还没建好变体，找不到的隔一会儿再试几次。返回加在导入结果后面的说明。
    func applyLooks(_ saved: [URL], target: CaptureOneBridge.SessionTarget) async -> String? {
        let raws = Set(saved.filter { ["ARW", "SR2", "SRF"].contains($0.pathExtension.uppercased()) })
        guard !raws.isEmpty else { return nil }
        var applied = 0, unknown = 0, missingProfiles = Set<String>(), notFound = 0
        let mine = raws.sorted { $0.path < $1.path }
        var notes: [String] = []
        for u in mine { if let note = ensureLookPack(forRaw: u) { notes.append(note) } }
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
        var summary = applied > 0 ? String(localized: "，Capture One 已套用创意外观 \(applied) 张") : ""
        if unapplied > 0 { summary += String(localized: "，\(unapplied) 张 RAW 未套用创意外观") }
        if !missingProfiles.isEmpty {
            let missing = missingProfiles.sorted().joined(separator: String(localized: "、"))
            summary += String(localized: "（缺少：\(missing)）")
        }
        for note in notes { summary += String(localized: "，\(note)") }
        return summary
    }
}

/// 本次运行中已经检查过（已安装或已开始下载）的机型，避免每张 RAW 都去扫配置文件夹。
@MainActor final class LookPackTracker {
    static let shared = LookPackTracker()
    var known: Set<String> = []
}
