import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {

    // MARK: 读取存储卡

    func loadAll(restoring keep: Set<String>? = nil, days keepDays: Set<String> = [], quietly: Bool = false) async {
        let sources = openSources
        guard !sources.isEmpty else { return }
        prepareSourceIdentities()
        if !quietly { phase = .loading }
        libraryGeneration += 1
        let generation = libraryGeneration
        let previous = Dictionary(items.values.map { (stableKey($0) + "|\($0.size)", $0.id) }, uniquingKeysWith: { a, _ in a })
        let oldFocus = grid.focus
        metadataTask?.cancel(); metadataTask = nil; metadataLoading = false
        do {
            // 几个来源的句柄会重复：界面上统一重新编号（全局句柄），origins 记着它在哪个来源、原来是几号。
            var all: [UInt32: CameraContentItem] = [:]
            var map: [UInt32: Origin] = [:]
            var next = nextGlobalHandle
            var grouped: [Shot] = []
            var unread = 0
            var handleSets: [UUID: Set<UInt32>] = [:]
            for (sid, lib) in sources {
                let folders = try await lib.folders()
                var ord: [UInt32] = []
                var localHandles: [UInt32] = []
                for f in folders {
                    status = String(localized: "正在读取\(f.name)…")
                    let hs = try await lib.handles(in: f)
                    handleSets[connectionID(for: sid), default: []].formUnion(hs)
                    for (i, h) in hs.enumerated() {
                        if i % 200 == 0 && i > 0 { status = String(localized: "正在读取\(f.name)：\(i)/\(hs.count)") }
                        let item: CameraContentItem
                        do { item = try await lib.item(h) }
                        catch {
                            // 连接本身出了问题：后面的也读不到，整次读取按失败算，不能交出一份残缺的列表。
                            if error is PTPIPTransportError || error is PTPUSBError || error is SSHTunnelError || error is CancellationError { throw error }
                            unread += 1
                            if unread == 1 { log.add("读卡：有文件的信息读不出来（\(error.localizedDescription)）") }
                            continue
                        }
                        guard item.kind != .other else { continue }
                        guard generation == libraryGeneration, !Task.isCancelled else { return }
                        let key = "\(sourceIdentity(sid))|\(item.storageID >> 16)|\(item.filename)|\(item.captureDateRaw)|\(item.size)"
                        let g: UInt32
                        if let old = previous[key] { g = old } else { g = next; next += 1 }
                        all[g] = item.withID(g)
                        map[g] = Origin(source: sid, local: h, connectionID: connectionID(for: sid))
                        ord.append(g)
                        localHandles.append(h)
                    }
                }
                for n in await lib.listingNotes { log.add("读卡：\(n)") }
                if let card = lib as? LocalCardLibrary, cardCameraNames[sid] == nil {
                    await readCardCameraName(sid, library: card, handles: localHandles)
                }
                // RAW 和 JPG 只在同一个来源里配对：两台相机都有 DSC00001，不能合成一格。
                ord.sort { (all[$0]?.captureDateRaw ?? "") > (all[$1]?.captureDateRaw ?? "") }
                grouped += ShotBuilder.group(ord.compactMap { all[$0] })
            }
            while quietly && NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(100))
                guard generation == libraryGeneration, !Task.isCancelled else { return }
            }
            guard generation == libraryGeneration, !Task.isCancelled else { return }
            let preservedKeys = quietly ? selectedKeys() : keep
            let preservedDays = quietly ? shownDays : keepDays
            nextGlobalHandle = next
            let surviving = Set(all.keys)
            thumbnails = thumbnails.filter { surviving.contains($0.key) }
            clipInfos = clipInfos.filter { surviving.contains($0.key) }
            ratings = ratings.filter { surviving.contains($0.key) }
            fileCameraKeys = fileCameraKeys.filter { surviving.contains($0.key) }
            proxySizes = proxySizes.filter { surviving.contains($0.key) }
            metadataRead.formIntersection(surviving)
            pendingThumbs.removeAll { !surviving.contains($0) }
            thumbOrder.removeAll { !surviving.contains($0) }
            items = all
            origins = map
            // 有文件没读到时不记：下次自动刷新照常重读。
            listedHandles = unread == 0 ? handleSets : [:]
            // 几个来源的拍摄按时间合在一起排（新的在前）。
            if sources.count > 1 {
                // 按校正过的时间排：两台相机的钟不一样快时，对齐后才排得对。
                let key: (Shot) -> Date = { s in all[s.primary].flatMap { i in
                    i.captureDate.map { $0.addingTimeInterval(self.clockOffset(map[s.primary]?.source ?? 0)) } } ?? .distantPast }
                grouped.sort { key($0) > key($1) }
            }
            allShots = grouped
            shots = Dictionary(uniqueKeysWithValues: allShots.map { ($0.id, $0) })
            shotOfFile = [:]
            for s in allShots { for h in s.handles { shotOfFile[h] = s.id } }
            // 几个来源时按来源筛（卡槽号在不同相机之间没有意义）。
            slots = sources.count > 1 ? [] : Array(Set(all.values.map { $0.storageID >> 16 })).sorted()
            if sources.count > 1, slotFilter != nil { slotFilter = nil }
            if let f = sourceFilter, !sources.contains(where: { $0.id == f }) { sourceFilter = nil }
            if !quietly { grid = GridSelection() }
            refreshCopies()
            rebuild()
            if let keep = preservedKeys {
                // 重连后：按文件身份找回原来的选择和查看的日期。
                let ids = allShots.filter { s in s.handles.contains { items[$0].map { keep.contains(stableKey($0)) } ?? false } }.map(\.id)
                grid.replace(with: Set(ids).intersection(Set(days.flatMap(\.shots))))
                let valid = preservedDays.intersection(viewIDs)
                if !valid.isEmpty { shownDays = valid }
            } else {
                selectDefault()
            }
            if let oldFocus { grid.setFocus(oldFocus) }
            phase = .ready
            loadFilterMetadata()
            lastListed = Date()
            log.add("读卡完成：\(all.count) 个文件，\(allShots.count) 次拍摄，\(days.count) 天" + (sources.count > 1 ? "，\(sources.count) 个来源" : "")
                    + (unread > 0 ? "；\(unread) 个文件没读到" : ""))
            if unread > 0 { refreshMessage = String(localized: "有 \(unread) 个文件没读到，可点重新读取再试") }
        } catch {
            guard generation == libraryGeneration, !Task.isCancelled else { return }
            log.add("读取存储卡失败：\(error.localizedDescription)")
            if quietly { refreshMessage = String(localized: "自动刷新未完成，可点重新读取再试") }
            else { errorMessage = String(localized: "读取存储卡失败：\(error.localizedDescription)") }
            phase = .ready
        }
        status = ""
    }

    /// 打开后默认：显示并勾选最近一天里没导入过的。
    private func selectDefault() {
        if let day = days.first(where: { $0.newCount > 0 }) ?? days.first {
            shownDays = [day.id]
            grid.set(day.shots.filter { !isImported(shot: $0) }, selected: true)
        }
    }

    static func dayKey(_ item: CameraContentItem) -> String {
        let raw = item.captureDateRaw
        if raw.count >= 8, raw.prefix(8).allSatisfy(\.isNumber) { return String(raw.prefix(8)) }
        guard let d = item.captureDate else { return "unknown" }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }

    static func dayTitle(_ key: String) -> String {
        guard key != "unknown" else { return String(localized: "无日期") }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: key) else { return key }
        let out = DateFormatter(); out.timeZone = TimeZone(identifier: "UTC")
        let thisYear = Calendar.current.component(.year, from: Date()) == Int(key.prefix(4))
        // 中文界面保持原格式；其他语言按界面语言的习惯显示。
        let language = Bundle.main.preferredLocalizations.first ?? "zh-Hans"
        if language.hasPrefix("zh") {
            out.locale = Locale(identifier: "zh_CN")
            out.dateFormat = thisYear ? "M月d日 EEE" : "yyyy年M月d日 EEE"
        } else {
            // 星期放在最后，侧栏的 DayTitle 按最后一个空格拆开对齐。
            out.locale = Locale(identifier: language)
            out.dateFormat = thisYear ? "MMM d EEE" : "MMM d, yyyy EEE"
        }
        return out.string(from: d)
    }

    /// 文件类型 / 卡槽筛选（不含「只看未导入」）。
    private func kindAccepted(_ item: CameraContentItem) -> Bool {
        guard importContent.accepts(item.kind) else { return false }
        if let sourceFilter, source(of: item.id) != sourceFilter { return false }
        // 这台相机设了只导某个卡槽。
        if let only = onlySlot(source(of: item.id)), item.storageID >> 16 != only { return false }
        if let slotFilter, item.storageID >> 16 != slotFilter { return false }
        switch item.kind {
        case .jpeg, .heif: return showPhotos
        case .raw: return showRaw
        case .video: return showVideo
        case .other: return false
        }
    }

    /// 一次拍摄里，按当前筛选（含照片格式）实际要导入的文件。
    func importFiles(of shot: Shot) -> [UInt32] {
        // 缩略图、侧栏和 tooltip 会反复问同一个 shot；一次 rebuild 里只算一遍。
        if let cached = importFilesCache[shot.id] { return cached }
        // 先按筛选（卡槽、类型）去掉，再去重：选了「卡 2」时就用卡 2 上的那份；都显示时用卡 1 上的那份。
        // 导哪些格式只看主界面的「照片格式」（RAW、JPG/HIF），不再另有配对规则。
        let files = ShotBuilder.files(of: shot, policy: .both, kindOf: { items[$0]?.kind },
                                      identity: { items[$0].map { "\($0.filename)|\($0.size)" } },
                                      include: { items[$0].map(kindAccepted) ?? false },
                                      preference: { items[$0].map { $0.storageID >> 16 } ?? 0 })
        importFilesCache[shot.id] = files
        return files
    }

    /// 缩略图角标：只列筛选留下的文件类型（只看 RAW 时显示「RAW」，不是「RAW+HIF」）。
    func badge(of shot: Shot) -> String {
        if shot.isVideo, let d = clipInfos[shot.primary]?.durationText { return String(localized: "视频 \(d)") }
        return Shot.badge(importFiles(of: shot).compactMap { items[$0]?.kind })
    }

    func isFileImported(_ h: UInt32) -> Bool { items[h].map { ImportHistory.shared.contains($0, camera: camera(of: h)) } ?? false }

    /// 这次拍摄要导入的文件都导过了。
    func isImported(shot id: UInt32) -> Bool {
        if let cached = importedCache[id] { return cached }
        guard let s = shots[id] else { return false }
        let files = importFiles(of: s)
        let imported = !files.isEmpty && files.allSatisfy(isFileImported)
        importedCache[id] = imported
        return imported
    }

    func rebuild() {
        importFilesCache = [:]
        importedCache = [:]
        var groups: [String: [UInt32]] = [:]
        var keys: [String] = []
        var importedCounts: [String: Int] = [:]
        var newPhotoCounts: [String: Int] = [:]
        var newVideoCounts: [String: Int] = [:]
        var videoCounts: [String: Int] = [:]
        var importedShots: Set<UInt32> = []
        for s in allShots {
            guard !importFiles(of: s).isEmpty, let first = items[s.primary], acceptsFilter(s) else { continue }
            let imported = isImported(shot: s.id)
            if imported { importedShots.insert(s.id) }
            if onlyNew && imported { continue }
            let k = Self.dayKey(first)
            if groups[k] == nil { keys.append(k) }
            groups[k, default: []].append(s.id)
            if s.isVideo { videoCounts[k, default: 0] += 1 }
            if imported { importedCounts[k, default: 0] += 1 }
            else if s.isVideo { newVideoCounts[k, default: 0] += 1 }
            else { newPhotoCounts[k, default: 0] += 1 }
        }
        keys.sort { a, b in a == "unknown" ? false : b == "unknown" ? true : a > b }
        days = keys.map { k in
            ShootingDay(id: k, title: Self.dayTitle(k), shots: groups[k]!, importedCount: importedCounts[k] ?? 0,
                        newPhotos: newPhotoCounts[k] ?? 0, newVideos: newVideoCounts[k] ?? 0,
                        videos: videoCounts[k] ?? 0,
                        scenes: scenes(of: groups[k]!, day: k, imported: importedShots))
        }
        // 被筛掉的内容不再算选中（否则会导入看不见的东西）。
        let visible = Set(days.flatMap(\.shots))
        grid.replace(with: grid.selected.intersection(visible))
        let validIDs = viewIDs
        if !shownDays.isSubset(of: validIDs) { shownDays = shownDays.intersection(validIDs) }
        if shownDays.isEmpty, let first = days.first { shownDays = [first.id] }
        updateGridOrder()
    }

    /// 把一天的拍摄（新的在前）按时间间隔切成几场。没有拍摄时间的拍摄跟着前一张走。
    private func scenes(of shots: [UInt32], day: String, imported: Set<UInt32>) -> [ShootingScene] {
        let gap = TimeInterval(sceneGap * 60)
        var runs: [[UInt32]] = []
        var last: Date?
        for id in shots {
            let t = self.shots[id].flatMap { items[$0.primary]?.captureDate }
            if let t, let l = last, gap > 0, l.timeIntervalSince(t) > gap { runs.append([]) }
            if runs.isEmpty { runs.append([]) }
            runs[runs.count - 1].append(id)
            if let t { last = t }
        }
        return runs.enumerated().map { i, ids in
            // ids 是新的在前：最后一张最早。
            let times = ids.compactMap { self.shots[$0].flatMap { items[$0.primary] }.flatMap(Self.clockTime) }
            let range = times.isEmpty ? "" : times.first == times.last ? times[0] : "\(times.last!)–\(times.first!)"
            let number = runs.count - i
            let fresh = ids.filter { !imported.contains($0) }
            let videos = ids.filter { self.shots[$0]?.isVideo == true }.count
            let newVideos = fresh.filter { self.shots[$0]?.isVideo == true }.count
            return ShootingScene(id: "\(day)-\(number)", number: number, timeRange: range, shots: ids,
                                 importedCount: ids.count - fresh.count,
                                 newPhotos: fresh.count - newVideos, newVideos: newVideos, videos: videos)
        }
    }

    /// 拍摄时间的「时:分」：优先取相机记录的原始时间串。
    static func clockTime(_ item: CameraContentItem) -> String? {
        let raw = Array(item.captureDateRaw)
        if raw.count >= 13, raw[8] == "T", raw[9...12].allSatisfy(\.isNumber) {
            return "\(String(raw[9...10])):\(String(raw[11...12]))"
        }
        guard let d = item.captureDate else { return nil }
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    /// 场次的标题：「第 2 场 · 14:05–16:30」。
    static func sceneTitle(_ s: ShootingScene) -> String {
        s.timeRange.isEmpty ? String(localized: "第 \(s.number) 场") : String(localized: "第 \(s.number) 场 · \(s.timeRange)")
    }

    func updateGridOrder() {
        grid.setOrder(visibleDays.flatMap(\.shots))
    }

    /// 某个卡槽里的拍摄数（侧栏显示）。
    func shotCount(slot: UInt32) -> Int {
        allShots.filter { $0.handles.contains { items[$0].map { $0.storageID >> 16 == slot } ?? false } }.count
    }

    /// 当前来源上没导入过的拍摄数。
    var newShotCount: Int { days.reduce(0) { $0 + $1.newCount } }

    /// 标题里的数量：「12 张新照片」；有视频时分开说「12 张新照片 · 3 个新片段」。
    var countTitle: (new: String, total: String) {
        let all = days.flatMap(\.shots)
        let videos = Set(all.filter { shots[$0]?.isVideo == true })
        guard !videos.isEmpty else {
            return (newShotCount > 0 ? String(localized: "\(newShotCount.formatted()) 张新照片") : String(localized: "无新照片"),
                    String(localized: "共 \(all.count.formatted()) 张"))
        }
        let newVideos = videos.filter { !isImported(shot: $0) }.count
        let newPhotos = newShotCount - newVideos
        var parts: [String] = []
        if newPhotos > 0 { parts.append(String(localized: "\(newPhotos.formatted()) 张新照片")) }
        if newVideos > 0 { parts.append(String(localized: "\(newVideos.formatted()) 个新片段")) }
        let photos = all.count - videos.count
        let total = photos > 0 ? String(localized: "共 \(photos.formatted()) 张照片、\(videos.count.formatted()) 个片段")
            : String(localized: "共 \(videos.count.formatted()) 个片段")
        return (parts.isEmpty ? String(localized: "无新内容") : parts.joined(separator: " · "), total)
    }

    /// 右边显示的内容：点中的日期整天显示；只点中了某几场的，这一天只显示那几场。
    var visibleDays: [ShootingDay] {
        days.compactMap { d in
            if shownDays.contains(d.id) { return d }
            let picked = d.scenes.count > 1 ? d.scenes.filter { shownDays.contains($0.id) } : []
            guard !picked.isEmpty else { return nil }
            var part = d
            part.scenes = picked
            part.shots = picked.flatMap(\.shots)
            part.importedCount = picked.reduce(0) { $0 + $1.importedCount }
            part.newPhotos = picked.reduce(0) { $0 + $1.newPhotos }
            part.newVideos = picked.reduce(0) { $0 + $1.newVideos }
            part.videos = picked.reduce(0) { $0 + $1.videos }
            part.partial = true
            return part
        }
    }

    /// 侧栏里能点中的 id：日期，以及分了场次的日期里的每一场。
    var viewIDs: Set<String> {
        Set(days.flatMap { d in [d.id] + (d.scenes.count > 1 ? d.scenes.map(\.id) : []) })
    }

    func item(_ h: UInt32) -> CameraContentItem? { items[h] }

    // MARK: 备份状态

    /// 检查每个导入过的文件，第一份和备份盘上的那份还在不在（大小一致）。
    /// 磁盘检查放到后台：几千个文件、网络卷或休眠的外置盘时，主线程会卡住。
    func refreshCopies() {
        let history = ImportHistory.shared
        var probes: [(handle: UInt32, item: CameraContentItem, paths: [URL])] = []
        for (h, item) in items {
            guard let record = history.record(for: item, camera: camera(of: h)) else { continue }
            let paths = Set([record.path, record.backupPath].compactMap { $0 } + (record.backupPaths ?? []))
            probes.append((h, item, paths.map { URL(filePath: $0) }))
        }
        copiesGeneration += 1
        let generation = copiesGeneration
        let model = self
        Task.detached(priority: .utility) {
            var map: [UInt32: Int] = [:]
            map.reserveCapacity(probes.count)
            for p in probes {
                map[p.handle] = p.paths.filter { ImportHistory.matches($0, p.item) }.count
            }
            await MainActor.run {
                guard model.copiesGeneration == generation else { return }
                model.fileCopies = map
            }
        }
    }

    /// 一次拍摄有几份：取它要导入的文件里最少的那个（RAW 有两份、JPG 只有一份，就算一份）。
    func copyCount(shot id: UInt32) -> Int {
        guard let s = shots[id] else { return 0 }
        let files = importFiles(of: s)
        guard !files.isEmpty else { return 0 }
        return files.map { fileCopies[$0] ?? 0 }.min() ?? 0
    }

    // MARK: 选择

    func selectNew(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { grid.set(d.shots.filter { !isImported(shot: $0) }, selected: true) }
    }

    func selectAll(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { grid.set(d.shots, selected: true) }
    }

    func deselect(in dayIDs: Set<String>) {
        for d in days where dayIDs.contains(d.id) { grid.set(d.shots, selected: false) }
    }

    func day(of shot: UInt32) -> ShootingDay? { days.first { $0.shots.contains(shot) } }

    /// 要导入的文件（按显示顺序：新的在前）。
    func selectedFiles() -> [CameraContentItem] {
        allShots.filter { grid.contains($0.id) }.flatMap(importFiles).compactMap { items[$0] }
    }

    var selectedShotCount: Int { grid.selected.count }

    /// 「12 张」「3 个片段」「12 张照片、3 个片段」；fresh 时「12 张新照片」「3 个新片段」。
    /// noun：只有照片时也说「12 张照片」。
    func countText(_ ids: some Sequence<UInt32>, fresh: Bool = false, noun: Bool = false) -> String {
        var p = 0, v = 0
        for id in ids { if shots[id]?.isVideo == true { v += 1 } else { p += 1 } }
        return Self.countText(photos: p, videos: v, fresh: fresh, noun: noun)
    }

    static func countText(photos p: Int, videos v: Int, fresh: Bool = false, noun: Bool = false) -> String {
        let photo = fresh ? String(localized: "\(p.formatted()) 张新照片") : String(localized: "\(p.formatted()) 张照片")
        let clip = fresh ? String(localized: "\(v.formatted()) 个新片段") : String(localized: "\(v.formatted()) 个片段")
        if v == 0 { return fresh || noun ? photo : String(localized: "\(p.formatted()) 张") }
        if p == 0 { return clip }
        return String(localized: "\(photo)、\(clip)")
    }
    /// 这批文件要传的字节数。调用方先取一次 `selectedFiles()`，别在同一个 body 里反复取。
    func selectionBytes(of files: [CameraContentItem]) -> UInt64 {
        files.reduce(0) { $0 + transferSize($1) }
    }

    /// 这个文件这次会只导代理（Wi-Fi 相机上的视频，打开了「视频只导代理」）。
    func importsProxyOnly(_ item: CameraContentItem) -> Bool {
        proxyOnlyWiFi && item.kind == .video && !(route(item.id)?.library is LocalCardLibrary)
    }

    /// 这次要传的字节数：只导代理的视频按代理大小算（还没读到时按原片估算）。
    func transferSize(_ item: CameraContentItem) -> UInt64 {
        importsProxyOnly(item) ? proxySizes[item.id] ?? item.sizeEstimate : item.sizeEstimate
    }

    /// 选中的里面有 Wi-Fi 相机上的视频（「视频只导代理」只对它们有用）。
    var selectionHasWiFiVideo: Bool {
        selectedFiles().contains { $0.kind == .video && !(route($0.id)?.library is LocalCardLibrary) }
    }

    /// 这次拍摄之前只导了代理（原片还没导）。
    func proxyOnlyCopy(shot id: UInt32) -> URL? {
        guard let s = shots[id], s.isVideo, let item = items[s.primary] else { return nil }
        return ProxyOnlyStore.shared.proxy(of: item, camera: camera(of: s.primary))
    }

    /// 这次拍摄的文件已经在本地的位置（用来「在访达中显示」）。
    func localFile(of shot: UInt32) -> URL? {
        guard let s = shots[shot] else { return nil }
        for h in s.handles { if let i = items[h], let u = ImportHistory.shared.localFile(i, camera: camera(of: h)) { return u } }
        return nil
    }

    // MARK: 缩略图

    /// 这次拍摄的星级：RAW 和 JPG/HIF 里取打过的那个（两者都有时取大的）。
    func rating(of shot: Shot) -> Int? {
        let vs = shot.handles.compactMap { ratings[$0] }
        return vs.isEmpty ? nil : vs.max()
    }

    func requestThumbnail(_ h: UInt32) {
        guard thumbnails[h] == nil, !pendingThumbs.contains(h) else { return }
        pendingThumbs.append(h)
        // 先同步置位再 spawn。Task 要到下一轮才运行，同一轮渲染里的多个 onAppear
        // 否则都会看到 false，各自启动一个加载器，把相机命令队列打满。
        guard !thumbLoaderRunning else { return }
        thumbLoaderRunning = true
        Task { await runThumbLoader() }
    }

    func cancelThumbnail(_ h: UInt32) { pendingThumbs.removeAll { $0 == h } }

    private func runThumbLoader() async {
        thumbLoaderRunning = true
        defer { thumbLoaderRunning = false }
        while !openSources.isEmpty, let h = pendingThumbs.popLast() {
            while progress != nil || isRefreshingSources {
                try? await Task.sleep(for: .milliseconds(300))
                if Task.isCancelled { return }
            }
            let generation = libraryGeneration
            guard let r = route(h) else { continue }
            if items[h]?.kind == .video, clipInfos[h] == nil, let info = await r.library.clipInfo(r.local) {
                guard generation == libraryGeneration else { continue }
                clipInfos[h] = info
            }
            if items[h]?.kind != .video, ratings[h] == nil, let v = await r.library.rating(r.local) {
                guard generation == libraryGeneration else { continue }
                ratings[h] = v
            }
            if items[h]?.kind == .video, proxySizes[h] == nil, !(r.library is LocalCardLibrary),
               let p = await r.library.proxy(of: r.local) {
                proxySizes[h] = p.size
            }
            guard let data = try? await r.library.thumbnail(r.local), let img = NSImage(data: data) else { continue }
            guard generation == libraryGeneration, items[h] != nil else { continue }
            thumbnails[h] = img
            thumbOrder.append(h)
            if thumbOrder.count > 1500 {
                let drop = thumbOrder.prefix(300)
                thumbOrder.removeFirst(300)
                for d in drop { thumbnails[d] = nil }
            }
        }
    }

    // MARK: 预览

    func openPreview(_ shot: UInt32? = nil) {
        guard let id = shot ?? grid.focus ?? grid.order.first(where: grid.contains) ?? grid.order.first else { return }
        showPreview(id)
    }

    private func showPreview(_ id: UInt32) {
        previewLivePhotoShot = nil
        previewRequest = UUID()
        videoPlayback.stop()
        previewShot = id
        previewVideoURL = nil; previewVideoMessage = nil; previewVideoProgress = nil; previewIsProxy = false
        previewLoaded = shots[id]?.isVideo == true
        previewExif = nil
        previewImage = shots[id].flatMap { thumbnails[$0.primary] }
        previewTask?.cancel()
        guard let s = shots[id], let r = route(s.primary) else { return }
        previewTask = Task {
            if s.isVideo { await prepareVideoPreview(id); return }
            let fromFile = await r.library.exif(r.local)
            if previewShot == id, let fromFile { previewExif = fromFile }
            guard let data = try? await r.library.preview(r.local), !Task.isCancelled, let img = NSImage(data: data) else { return }
            guard previewShot == id else { return }
            previewImage = img; previewLoaded = true
            if fromFile == nil {
                // Wi-Fi：相机给的预览图（screennail）里带着 EXIF 时从这里读。
                previewExif = ShotExif(imageData: data)
                if !exifNoted { exifNoted = true; log.add("预览图 EXIF：\(previewExif == nil ? "没有" : "有")") }
            }
        }
    }

    func previewStep(_ delta: Int) {
        guard let cur = previewShot, let i = grid.order.firstIndex(of: cur) else { return }
        let j = i + delta
        guard grid.order.indices.contains(j) else { return }
        grid.setFocus(grid.order[j])     // 翻页只移动焦点，不改变选择
        showPreview(grid.order[j])
    }

    /// 预览里按 P：切换当前这张的选中状态。
    func togglePreviewSelection() {
        guard let id = previewShot else { return }
        grid.set([id], selected: !grid.contains(id))
    }

    func closePreview() {
        previewLivePhotoShot = nil
        previewRequest = UUID()
        previewTask?.cancel()
        videoPlayback.stop()
        previewVideoURL = nil; previewVideoMessage = nil; previewVideoProgress = nil
        previewShot = nil
        previewImage = nil
        previewExif = nil
    }
}
