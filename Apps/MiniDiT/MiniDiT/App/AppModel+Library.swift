import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {

    // MARK: 读取存储卡

    func loadAll(restoring keep: Set<String>? = nil, days keepDays: Set<String> = []) async {
        guard let library else { return }
        phase = .loading
        thumbnails = [:]; thumbOrder = []; pendingThumbs = []   // 句柄会变，旧缩略图不能再用
        do {
            let folders = try await library.folders()
            var all: [UInt32: CameraContentItem] = [:]
            var ord: [UInt32] = []
            for f in folders {
                status = "正在读取\(f.name)…"
                let hs = try await library.handles(in: f)
                for (i, h) in hs.enumerated() {
                    if i % 200 == 0 && i > 0 { status = "正在读取\(f.name)：\(i)/\(hs.count)" }
                    guard let item = try? await library.item(h), item.kind != .other else { continue }
                    all[h] = item
                    ord.append(h)
                }
            }
            for n in await library.listingNotes { log.add("读卡：\(n)") }
            items = all
            ord.sort { (all[$0]?.captureDateRaw ?? "") > (all[$1]?.captureDateRaw ?? "") }
            allShots = ShotBuilder.group(ord.compactMap { all[$0] })
            shots = Dictionary(uniqueKeysWithValues: allShots.map { ($0.id, $0) })
            shotOfFile = [:]
            for s in allShots { for h in s.handles { shotOfFile[h] = s.id } }
            slots = Array(Set(all.values.map { $0.storageID >> 16 })).sorted()
            grid = GridSelection()
            rebuild()
            if let keep {
                // 重连后：按文件身份找回原来的选择和查看的日期。
                let ids = allShots.filter { s in s.handles.contains { items[$0].map { keep.contains(Self.stableKey($0)) } ?? false } }.map(\.id)
                grid.set(ids, selected: true)
                let valid = keepDays.intersection(Set(days.map(\.id)))
                if !valid.isEmpty { shownDays = valid }
            } else {
                selectDefault()
            }
            phase = .ready
            log.add("读卡完成：\(all.count) 个文件，\(allShots.count) 次拍摄，\(days.count) 天")
        } catch {
            log.add("读取存储卡失败：\(error.localizedDescription)")
            errorMessage = "读取存储卡失败：\(error.localizedDescription)"
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
        guard key != "unknown" else { return "没有日期" }
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: key) else { return key }
        let out = DateFormatter(); out.locale = Locale(identifier: "zh_CN"); out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = Calendar.current.component(.year, from: Date()) == Int(key.prefix(4)) ? "M月d日 EEE" : "yyyy年M月d日 EEE"
        return out.string(from: d)
    }

    /// 文件类型 / 卡槽筛选（不含「只看未导入」）。
    private func kindAccepted(_ item: CameraContentItem) -> Bool {
        if let slotFilter, item.storageID >> 16 != slotFilter { return false }
        switch item.kind {
        case .jpeg, .heif: return showPhotos
        case .raw: return showRaw
        case .video: return showVideo
        case .other: return false
        }
    }

    /// 一次拍摄里，按当前筛选和配对规则实际要导入的文件。
    func importFiles(of shot: Shot) -> [UInt32] {
        // 先按筛选（卡槽、类型）去掉，再去重：选了「卡 2」时就用卡 2 上的那份。
        ShotBuilder.files(of: shot, policy: pairPolicy, kindOf: { items[$0]?.kind },
                          identity: { items[$0].map { "\($0.filename)|\($0.size)" } },
                          include: { items[$0].map(kindAccepted) ?? false })
    }

    func isFileImported(_ h: UInt32) -> Bool { items[h].map { ImportHistory.shared.contains($0, camera: cameraID) } ?? false }

    /// 这次拍摄要导入的文件都导过了。
    func isImported(shot id: UInt32) -> Bool {
        guard let s = shots[id] else { return false }
        let files = importFiles(of: s)
        return !files.isEmpty && files.allSatisfy(isFileImported)
    }

    func rebuild() {
        var groups: [String: [UInt32]] = [:]
        var keys: [String] = []
        var importedCounts: [String: Int] = [:]
        for s in allShots {
            guard !importFiles(of: s).isEmpty, let first = items[s.primary] else { continue }
            let imported = isImported(shot: s.id)
            if onlyNew && imported { continue }
            let k = Self.dayKey(first)
            if groups[k] == nil { keys.append(k) }
            groups[k, default: []].append(s.id)
            if imported { importedCounts[k, default: 0] += 1 }
        }
        keys.sort { a, b in a == "unknown" ? false : b == "unknown" ? true : a > b }
        days = keys.map { k in
            ShootingDay(id: k, title: Self.dayTitle(k), shots: groups[k]!, importedCount: importedCounts[k] ?? 0)
        }
        // 被筛掉的内容不再算选中（否则会导入看不见的东西）。
        let visible = Set(days.flatMap(\.shots))
        grid.replace(with: grid.selected.intersection(visible))
        let validDays = Set(keys)
        if !shownDays.isSubset(of: validDays) { shownDays = shownDays.intersection(validDays) }
        if shownDays.isEmpty, let first = days.first { shownDays = [first.id] }
        updateGridOrder()
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

    var visibleDays: [ShootingDay] { days.filter { shownDays.contains($0.id) } }

    func item(_ h: UInt32) -> CameraContentItem? { items[h] }

    // MARK: 选择

    func checkState(_ day: ShootingDay) -> CheckState {
        let n = day.shots.filter(grid.contains).count
        if n == 0 { return .off }
        let target = day.newCount > 0 ? day.shots.filter { !isImported(shot: $0) } : day.shots
        return target.allSatisfy(grid.contains) ? .on : .mixed
    }

    /// 侧栏勾选框：勾上 = 这一天没导入过的全部选中（都导过了就全选）；再点一下取消这一天。
    func toggleDay(_ day: ShootingDay) {
        if checkState(day) == .on {
            grid.set(day.shots, selected: false)
        } else {
            let target = day.newCount > 0 ? day.shots.filter { !isImported(shot: $0) } : day.shots
            grid.set(target, selected: true)
            // 勾上的那天也显示在右边，选中的照片看得见。
            if !shownDays.contains(day.id) { shownDays.insert(day.id) }
        }
    }

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
    var selectionBytes: UInt64 { selectedFiles().reduce(0) { $0 + $1.size } }

    /// 这次拍摄的文件已经在本地的位置（用来「在访达中显示」）。
    func localFile(of shot: UInt32) -> URL? {
        guard let s = shots[shot] else { return nil }
        for h in s.handles { if let i = items[h], let u = ImportHistory.shared.localFile(i, camera: cameraID) { return u } }
        return nil
    }

    // MARK: 缩略图

    func requestThumbnail(_ h: UInt32) {
        guard thumbnails[h] == nil, !pendingThumbs.contains(h) else { return }
        pendingThumbs.append(h)
        if !thumbLoaderRunning { Task { await runThumbLoader() } }
    }

    func cancelThumbnail(_ h: UInt32) { pendingThumbs.removeAll { $0 == h } }

    private func runThumbLoader() async {
        thumbLoaderRunning = true
        defer { thumbLoaderRunning = false }
        while let library, let h = pendingThumbs.popLast() {
            // 下载时让出通道，优先传文件。
            if progress != nil { try? await Task.sleep(for: .milliseconds(300)) }
            guard let data = try? await library.thumbnail(h), let img = NSImage(data: data) else { continue }
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
        previewShot = id
        previewLoaded = false
        previewImage = shots[id].flatMap { thumbnails[$0.primary] }
        previewTask?.cancel()
        guard let library, let s = shots[id] else { return }
        previewTask = Task {
            guard let data = try? await library.preview(s.primary), !Task.isCancelled, let img = NSImage(data: data) else { return }
            if previewShot == id { previewImage = img; previewLoaded = true }
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
        previewTask?.cancel()
        previewShot = nil
        previewImage = nil
    }
}
