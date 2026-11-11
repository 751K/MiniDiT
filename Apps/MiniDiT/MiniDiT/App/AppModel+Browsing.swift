import AppKit
import MiniDiTCore
import SonyRemoteKit

extension AppModel {
    var photoFormatSummary: String {
        if !showRaw && !showPhotos { return "未选格式" }
        if !showRaw { return "JPG/HIF" }
        if !showPhotos { return "RAW" }
        switch pairPolicy {
        case .both: return "RAW + JPG/HIF"
        case .rawOnly: return "配对优先 RAW"
        case .jpegOnly: return "配对优先 JPG/HIF"
        }
    }

    var hasImportFilters: Bool {
        mediaFilter.isActive || onlyNew || sourceFilter != nil || slotFilter != nil || !showRaw || !showPhotos
    }

    var importScopeSummary: String {
        var parts = [importContent.title]
        if onlyNew { parts.append("未导入") }
        if sourceFilter != nil { parts.append("指定来源") }
        if slotFilter != nil { parts.append("指定卡槽") }
        if mediaFilter.isActive { parts.append("已筛选") }
        return parts.joined(separator: " · ")
    }

    /// 保留导入类型及配对偏好，只清除临时浏览筛选。
    func resetImportFilters() {
        mediaFilter = MediaFilter()
        onlyNew = false
        sourceFilter = nil
        slotFilter = nil
        showRaw = true
        showPhotos = true
    }

    func acceptsFilter(_ shot: Shot) -> Bool {
        let names = shot.handles.compactMap { items[$0]?.filename } + [sourceLabel(source(of: shot.id))]
        return mediaFilter.accepts(names: names, isVideo: shot.isVideo, rating: rating(of: shot),
                                   hasShotMark: !(clipInfos[shot.primary]?.shotMarks.isEmpty ?? true))
    }

    /// 筛选需要整张卡的标记，不能只读当前已经出现的缩略图。
    func loadFilterMetadata(force: Bool = false) {
        guard force || mediaFilter.needsMetadata, metadataTask == nil, !openSources.isEmpty, !isRefreshingSources else { return }
        let generation = libraryGeneration
        let work = allShots.flatMap { $0.isVideo ? [$0.primary] : $0.handles }.filter { !metadataRead.contains($0) }
        guard !work.isEmpty else { return }
        metadataLoading = true
        metadataTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == libraryGeneration { metadataTask = nil; metadataLoading = false; rebuild() }
            }
            for (index, h) in work.enumerated() {
                guard !Task.isCancelled, generation == libraryGeneration, force || mediaFilter.needsMetadata else { return }
                while progress != nil || previewVideoProgress != nil {
                    try? await Task.sleep(for: .milliseconds(300))
                    if Task.isCancelled { return }
                }
                guard let r = route(h) else { continue }
                if items[h]?.kind == .video {
                    let info = await r.library.clipInfo(r.local)
                    guard generation == libraryGeneration, !Task.isCancelled else { return }
                    clipInfos[h] = info
                } else {
                    let value = await r.library.rating(r.local)
                    guard generation == libraryGeneration, !Task.isCancelled else { return }
                    ratings[h] = value ?? 0
                }
                metadataRead.insert(h)
                if index % 20 == 19 { rebuild() }
            }
        }
    }

    func startLibraryWatch() {
        // 窗口显示时每 15 秒查一次，后台不扫卡、不争用传输通道。
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self else { return }
                if autoRefresh, mainWindowOpen, NSApp.isActive { refreshSources(automatically: true) }
            }
        }
    }

    func refreshSources(automatically: Bool = false) {
        guard progress == nil, phase == .ready, !sourcesOffline, !openSources.isEmpty,
              !isRefreshingSources, previewShot == nil, !grid.isBoxSelecting,
              NSEvent.pressedMouseButtons == 0 else { return }
        // 在第一次 await 之前加锁，防止两次刷新或导入抢进来。
        isRefreshingSources = true
        let request = UUID()
        refreshRequest = request
        metadataTask?.cancel(); metadataTask = nil; metadataLoading = false
        let keep = selectedKeys(), keepDays = shownDays, oldKeys = Set(items.values.map(stableKey))
        let sourceList = openSources
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if refreshRequest == request {
                    isRefreshingSources = false; refreshTask = nil
                    loadFilterMetadata(force: !automatically)
                    for h in grid.order.prefix(80) { if let p = shots[h]?.primary { requestThumbnail(p) } }
                }
            }
            for (_, lib) in sourceList {
                guard !Task.isCancelled else { return }
                await lib.refresh()
            }
            guard !Task.isCancelled else { return }
            if !automatically { metadataRead = [] }
            let listedBefore = lastListed
            await loadAll(restoring: keep, days: keepDays, quietly: true)
            guard !Task.isCancelled, lastListed != listedBefore else { return }
            let fresh = allShots.filter { s in s.handles.contains { items[$0].map { !oldKeys.contains(stableKey($0)) } ?? false } }
            if !fresh.isEmpty {
                let videos = fresh.filter(\.isVideo).count
                refreshMessage = "发现 " + Self.countText(photos: fresh.count - videos, videos: videos, fresh: true)
            } else if !automatically { refreshMessage = "已更新，暂无新增素材" }
        }
    }
}
