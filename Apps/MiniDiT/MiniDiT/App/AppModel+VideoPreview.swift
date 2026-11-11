import AppKit
import MiniDiTCore
import SonyRemoteKit

extension AppModel {
    func openLivePhotoExport(_ id: UInt32) {
        guard shots[id]?.isVideo == true else { return }
        openPreview(id)
        previewLivePhotoShot = id
    }

    func prepareVideoPreview(_ id: UInt32, allowOriginal: Bool = false) async {
        let request = previewRequest
        guard let shot = shots[id], let item = items[shot.primary], let route = route(shot.primary) else { return }
        if clipInfos[shot.primary] == nil {
            let info = await route.library.clipInfo(route.local)
            guard !Task.isCancelled, previewShot == id, previewRequest == request else { return }
            clipInfos[shot.primary] = info
        }
        if let local = localFile(of: id) {
            previewVideoURL = local; return
        }
        if let card = route.library as? LocalCardLibrary, let local = await card.fileURL(route.local) {
            guard !Task.isCancelled, previewShot == id, previewRequest == request else { return }
            previewVideoURL = local; return
        }
        if let proxy = proxyOnlyCopy(shot: id) {
            previewVideoURL = proxy; previewIsProxy = true; return
        }
        guard progress == nil, !isRefreshingSources else {
            previewVideoMessage = "正在导入，完成后可加载 Wi-Fi 视频预览。"; return
        }
        let proxy = await route.library.proxy(of: route.local)
        guard !Task.isCancelled, previewShot == id, previewRequest == request else { return }
        guard let file = proxy ?? (allowOriginal ? localItem(item) : nil) else {
            previewVideoMessage = "相机未提供代理。可缓存原片后播放，原文件保留在相机上。"; return
        }
        previewIsProxy = proxy != nil
        let identity = stableKey(item) + "|\(file.filename)|\(file.size)"
        var hash = XXH64(); hash.update(Data(identity.utf8))
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "MiniDiT/VideoPreview", directoryHint: .isDirectory)
        let dir = root.appending(path: XXH64.hex(hash.digest()), directoryHint: .isDirectory)
        let url = dir.appending(path: file.filename)
        let part = dir.appending(path: ".preview.part")
        previewVideoMessage = nil; previewVideoProgress = 0
        defer { if previewShot == id, previewRequest == request { previewVideoProgress = nil } }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if !ImportHistory.matches(url, file) {
                if let space = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   space < Int64(clamping: file.sizeEstimate) + 256 * 1024 * 1024 {
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                defer { try? FileManager.default.removeItem(at: part) }
                try await route.library.download(file, to: part) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, self.previewShot == id, self.previewRequest == request, self.previewVideoURL == nil else { return }
                        self.previewVideoProgress = total > 0 ? min(1, Double(done) / Double(total)) : 0
                    }
                }
                try Task.checkCancellation()
                guard ImportHistory.matches(part, file) else { throw CocoaError(.fileReadCorruptFile) }
                // 临时文件成功后再发布，取消或断线不会留下可播放的半个文件。
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                try FileManager.default.moveItem(at: part, to: url)
            }
            guard !Task.isCancelled, previewShot == id, previewRequest == request else { return }
            previewVideoURL = url
            Task.detached(priority: .utility) { Self.trimVideoPreviewCache(root, keeping: url) }
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled, previewShot == id, previewRequest == request else { return }
            previewVideoMessage = "无法加载预览：\(error.localizedDescription)"
        }
    }

    func retryVideoPreview(allowOriginal: Bool) {
        guard let id = previewShot else { return }
        previewTask?.cancel()
        previewRequest = UUID()
        previewTask = Task { await prepareVideoPreview(id, allowOriginal: allowOriginal) }
    }

    nonisolated private static func trimVideoPreviewCache(_ root: URL, keeping current: URL) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        var files: [(URL, Int, Date)] = []
        for case let u as URL in enumerator {
            guard let v = try? u.resourceValues(forKeys: keys), v.isRegularFile == true else { continue }
            files.append((u, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast))
        }
        var bytes = files.reduce(0) { $0 + $1.1 }
        // 至多保留 2 GB；单个正在看的大原片可超过上限，关闭后供下次清理。
        for (file, size, _) in files.sorted(by: { $0.2 < $1.2 }) where file != current && bytes > 2 * 1024 * 1024 * 1024 {
            if (try? fm.removeItem(at: file)) != nil { bytes -= size }
        }
    }
}
