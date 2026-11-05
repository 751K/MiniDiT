import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

/// 同时打开的另一张存储卡。
struct ExtraSource: Identifiable {
    let id: Int
    let root: URL
    let library: LocalCardLibrary
}

/// 一个文件在它的来源里的位置。
struct Origin: Hashable {
    let source: Int
    let local: UInt32
}

/// 侧栏和筛选条上显示的一个来源。
struct SourceSummary: Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String
    let isCard: Bool
}

/// 一台机身的档案。
struct CameraProfile: Codable, Equatable {
    /// 自己起的名字（「主机」「副机」）；nil = 用机型名。
    var nickname: String?
    /// 只导这个卡槽（Wi-Fi 相机有两个卡槽时）；nil = 两个都导。
    var onlySlot: UInt32?
    /// 时钟校正（秒）：这台相机记录的时间加上它，才和其他相机对得上。
    var clockOffset: Double?

    private static let key = "cameraProfiles"

    static func loadAll() -> [String: CameraProfile] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode([String: CameraProfile].self, from: d) else { return [:] }
        return p
    }

    static func saveAll(_ p: [String: CameraProfile]) {
        if let d = try? JSONEncoder().encode(p) { UserDefaults.standard.set(d, forKey: key) }
    }

    /// 「型号#序列号」，序列号去掉前导 0（PTP 给的序列号前面补了一串 0，EXIF 里的没有）。
    static func bodyKey(model: String, serial: String) -> String? {
        let m = model.trimmingCharacters(in: .whitespaces).uppercased()
        let s = serial.trimmingCharacters(in: .whitespaces).drop { $0 == "0" }
        return m.isEmpty || s.isEmpty ? nil : "\(m)#\(s)"
    }

    /// 「+2 分 30 秒」「−45 秒」。
    static func offsetText(_ t: Double) -> String {
        let n = Int(abs(t).rounded())
        let sign = t >= 0 ? "+" : "−"
        if n < 60 { return "\(sign)\(n) 秒" }
        if n < 3600 { return "\(sign)\(n / 60) 分" + (n % 60 > 0 ? " \(n % 60) 秒" : "") }
        return "\(sign)\(n / 3600) 小时" + (n % 3600 / 60 > 0 ? " \(n % 3600 / 60) 分" : "")
    }
}

extension CameraContentItem {
    /// 换一个句柄的同一个文件（来源里的句柄 ↔ 界面上的全局句柄）。
    func withID(_ id: UInt32) -> CameraContentItem {
        CameraContentItem(id: id, storageID: storageID, filename: filename, format: format, size: size, sizeKnown: sizeKnown,
                          captureDate: captureDate, captureDateRaw: captureDateRaw, width: width, height: height)
    }
}

extension AppModel {
    /// 主来源的 id。
    static let primarySource = 0

    /// 同时打开了不止一个来源。
    var isMultiSource: Bool { !extraSources.isEmpty }

    /// 所有打开的来源（主来源在前）。
    var openSources: [(id: Int, library: any CameraLibrary)] {
        (library.map { [(Self.primarySource, $0)] } ?? []) + extraSources.map { ($0.id, $0.library as any CameraLibrary) }
    }

    func library(of source: Int) -> (any CameraLibrary)? {
        source == Self.primarySource ? library : extraSources.first { $0.id == source }?.library
    }

    /// 全局句柄 → 来源的接口和来源里的句柄。
    func route(_ h: UInt32) -> (library: any CameraLibrary, local: UInt32)? {
        guard let o = origins[h], let lib = library(of: o.source) else { return nil }
        return (lib, o.local)
    }

    func source(of h: UInt32) -> Int { origins[h]?.source ?? Self.primarySource }

    /// 这个文件所在机身的 ID（导入记录用）。读卡器没有。
    func camera(of h: UInt32) -> String? { source(of: h) == Self.primarySource ? cameraID : nil }

    /// 交给来源去下载 / 读取时用的那份（句柄换回来源里的）。
    func localItem(_ item: CameraContentItem) -> CameraContentItem {
        origins[item.id].map { item.withID($0.local) } ?? item
    }

    // MARK: 相机档案

    /// 这个来源的机身（找档案用）。Wi-Fi 相机用机身 ID，存储卡用照片 EXIF 里的型号和序列号。
    func profileKey(_ id: Int) -> String? {
        if id == Self.primarySource, sourceKind == .camera, let c = cameraID {
            let parts = c.split(separator: "#", maxSplits: 1).map(String.init)
            return parts.count == 2 ? CameraProfile.bodyKey(model: parts[0], serial: parts[1]) : nil
        }
        return cardCameraKeys[id]
    }

    func profile(_ id: Int) -> CameraProfile? { profileKey(id).flatMap { cameraProfiles[$0] } }

    func updateProfile(_ id: Int, _ change: (inout CameraProfile) -> Void) {
        guard let k = profileKey(id) else { return }
        var p = cameraProfiles[k] ?? CameraProfile()
        change(&p)
        cameraProfiles[k] = p
    }

    /// 改名：名字也用在多来源导入的子文件夹上。空 = 恢复机型名。
    func rename(_ id: Int, to name: String) {
        let n = NameTemplate.sanitize(name.trimmingCharacters(in: .whitespaces))
        updateProfile(id) { $0.nickname = n.isEmpty ? nil : n }
        log.add("来源 \(id) 改名为「\(n.isEmpty ? "（机型名）" : n)」")
    }

    /// 只导某个卡槽（nil = 都导）。
    func setOnlySlot(_ id: Int, _ slot: UInt32?) {
        updateProfile(id) { $0.onlySlot = slot }
        if slot != nil { slotFilter = nil } else { rebuild() }
    }

    /// 只对 Wi-Fi 相机生效：读卡器上的卡总是「卡槽 1」，同一台机身的设置不能把它整张筛掉。
    func onlySlot(_ id: Int) -> UInt32? {
        guard id == Self.primarySource, sourceKind == .camera else { return nil }
        return profile(id)?.onlySlot
    }

    func clockOffset(_ id: Int) -> Double { profile(id)?.clockOffset ?? 0 }

    /// 拍摄时间加上这台相机的时钟校正（多来源合并排序用）。
    func correctedDate(_ item: CameraContentItem) -> Date? {
        item.captureDate.map { $0.addingTimeInterval(clockOffset(source(of: item.id))) }
    }

    /// 打开的来源里有几台不同的机身（读不出机身的卡不算）。
    var distinctBodies: Int { Set(sources.compactMap { profileKey($0.id) }).count }

    /// 有两台以上的相机，还没对过时间。
    var clocksUnaligned: Bool {
        distinctBodies > 1 && sources.allSatisfy { profile($0.id)?.clockOffset == nil }
    }

    /// 选中了两台不同相机的各一张照片：可以按它们对齐时间。返回（参照来源，要校正的来源，要校正的秒数）。
    var alignCandidate: (reference: Int, adjust: Int, offset: Double)? {
        let sel = Array(grid.selected)
        guard sel.count == 2, let a = shots[sel[0]], let b = shots[sel[1]],
              let ia = items[a.primary], let ib = items[b.primary],
              let ta = ia.captureDate, let tb = ib.captureDate else { return nil }
        let sa = source(of: a.id), sb = source(of: b.id)
        guard sa != sb, let ka = profileKey(sa), let kb = profileKey(sb), ka != kb else { return nil }
        // 以 id 小的（先打开的）为准，校正另一台。
        let (ref, adj, tr, tj) = sa < sb ? (sa, sb, ta, tb) : (sb, sa, tb, ta)
        let corrected = tr.addingTimeInterval(clockOffset(ref))
        return (ref, adj, corrected.timeIntervalSince(tj))
    }

    func alignClocks() {
        guard let c = alignCandidate else { return }
        updateProfile(c.adjust) { $0.clockOffset = abs(c.offset) < 0.5 ? 0 : c.offset }
        log.add("时钟对齐：\(sourceName(c.adjust)) 校正 \(CameraProfile.offsetText(c.offset))，以 \(sourceName(c.reference)) 为准")
        resortShots()
    }

    func clearClockOffset(_ id: Int) {
        updateProfile(id) { $0.clockOffset = nil }
        resortShots()
    }

    /// 时钟校正变了：重新按校正后的时间排一遍，不用重新读卡。
    func resortShots() {
        guard isMultiSource else { return }
        let key: (Shot) -> Date = { self.items[$0.primary].flatMap(self.correctedDate) ?? .distantPast }
        allShots.sort { key($0) > key($1) }
        rebuild()
    }

    /// 来源显示的名字：自己起的名字优先；Wi-Fi 相机用相机名；存储卡用卡上照片的机型，读不到时用卷名。
    func sourceName(_ id: Int) -> String {
        if let n = profile(id)?.nickname { return n }
        if id == Self.primarySource {
            if sourceKind == .card, let n = cardCameraNames[id] { return n }
            return connectedName ?? ""
        }
        guard let e = extraSources.first(where: { $0.id == id }) else { return "" }
        return cardCameraNames[id] ?? e.root.lastPathComponent
    }

    /// 界面上区分来源用的短名字：和别的来源重名时，存储卡改用卷名（两张卡都是 α7 V 拍的）。
    func sourceLabel(_ id: Int) -> String {
        let name = sourceName(id)
        let clash = sources.filter { $0.name == name }.count > 1
        guard clash, let vol = volumeName(id) else { return name }
        return vol
    }

    /// 卷名（存储卡来源）。
    func volumeName(_ id: Int) -> String? {
        if id == Self.primarySource { return sourceKind == .card ? cardRoot?.lastPathComponent : nil }
        return extraSources.first { $0.id == id }?.root.lastPathComponent
    }

    var sources: [SourceSummary] {
        var out: [SourceSummary] = []
        if library != nil || offline {
            let isCard = sourceKind == .card
            out.append(SourceSummary(id: Self.primarySource, name: sourceName(Self.primarySource),
                                     detail: isCard ? "读卡器 · \(cardRoot?.lastPathComponent ?? "")" : "Wi-Fi · \(connectedHost ?? "")",
                                     isCard: isCard))
        }
        for e in extraSources {
            out.append(SourceSummary(id: e.id, name: sourceName(e.id), detail: "读卡器 · \(e.root.lastPathComponent)", isCard: true))
        }
        return out
    }

    /// 导入时每个来源的子文件夹名：来源名，重名时加卷名区分。只有一个来源时不分子文件夹。
    func sourceFolders() -> [Int: String] {
        guard isMultiSource else { return [:] }
        let list = sources
        var out: [Int: String] = [:]
        for s in list {
            let base = NameTemplate.sanitize(s.name)
            let clash = list.filter { NameTemplate.sanitize($0.name) == base }.count > 1
            var name = clash ? base + "-" + NameTemplate.sanitize(volumeName(s.id) ?? "\(s.id + 1)") : base
            if name.isEmpty { name = "来源 \(s.id + 1)" }
            out[s.id] = name
        }
        return out
    }

    /// 某个来源里的拍摄数（筛选条上显示）。
    func shotCount(source: Int) -> Int { allShots.filter { self.source(of: $0.id) == source }.count }

    /// 存储卡来源：从卡上第一张照片的 EXIF 读出机型，当来源名字。
    func readCardCameraName(_ id: Int, library lib: LocalCardLibrary, handles: [UInt32]) async {
        for h in handles.prefix(40) {
            if let x = await lib.exif(h), let cam = x.camera, !cam.isEmpty {
                cardCameraNames[id] = CameraDeviceInfo.displayName(model: cam)
                if let serial = x.serial, let k = CameraProfile.bodyKey(model: cam, serial: serial) {
                    cardCameraKeys[id] = k
                } else {
                    // 索尼的 EXIF 里没有机身序列号（在加密的 MakerNote 里）：改为按这张卡记住（卷 UUID）。
                    cardCameraKeys[id] = Self.cardKey(model: cam, root: lib.root)
                }
                log.add("存储卡来源 \(id)：\(cam)，" + (x.serial != nil ? "按机身记住设置" : "没有机身序列号，按存储卡记住设置"))
                return
            }
        }
    }

    /// 没有机身序列号时，按存储卡认：「CARD:型号@卷 UUID」（没有 UUID 用卷名）。
    static func cardKey(model: String, root: URL) -> String {
        let v = try? root.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeNameKey])
        return "CARD:\(model.uppercased())@\(v?.volumeUUIDString ?? v?.volumeName ?? root.lastPathComponent)"
    }

    // MARK: 同时打开存储卡

    /// 在当前来源之外再打开一张卡（主来源可以是相机，也可以是另一张卡）。
    func addCard(_ url: URL) {
        guard progress == nil, library != nil else { openCard(url); return }
        let std = url.standardizedFileURL
        if cardRoot?.standardizedFileURL == std || extraSources.contains(where: { $0.root.standardizedFileURL == std }) { return }
        let src = ExtraSource(id: nextSourceID, root: url, library: LocalCardLibrary(root: url))
        nextSourceID += 1
        extraSources.append(src)
        log.add("同时打开存储卡 \(url.path)（来源 \(src.id)）")
        let keep = selectedKeys(), keepDays = shownDays
        Task { await loadAll(restoring: keep, days: keepDays) }
    }

    /// 关掉一个来源。关的是主来源时，第一张同时打开的卡顶上来当主来源。
    func removeSource(_ id: Int) {
        guard progress == nil else { return }
        if id == Self.primarySource {
            guard let next = extraSources.first else { disconnect(); return }
            extraSources.removeFirst()
            let keep = selectedKeys(), keepDays = shownDays
            let old = library
            Task { await old?.close() }
            promote(next)
            Task { await loadAll(restoring: keep, days: keepDays) }
            return
        }
        guard let i = extraSources.firstIndex(where: { $0.id == id }) else { return }
        let e = extraSources.remove(at: i)
        log.add("关闭存储卡 \(e.root.path)")
        if sourceFilter == id { sourceFilter = nil }
        cardCameraNames[id] = nil
        cardCameraKeys[id] = nil
        let keep = selectedKeys(), keepDays = shownDays
        Task { await loadAll(restoring: keep, days: keepDays) }
    }

    /// 同时打开的一张卡被拔掉了。
    func extraCardLost(_ root: URL) {
        guard let e = extraSources.first(where: { $0.root.standardizedFileURL == root.standardizedFileURL }) else { return }
        if progress != nil { importTask?.cancel() }
        log.add("同时打开的存储卡被移除了：\(root.path)")
        extraSources.removeAll { $0.id == e.id }
        if sourceFilter == e.id { sourceFilter = nil }
        cardCameraNames[e.id] = nil
        cardCameraKeys[e.id] = nil
        let keep = selectedKeys(), keepDays = shownDays
        Task { await loadAll(restoring: keep, days: keepDays) }
    }

    /// 推出一张同时打开的卡。
    func ejectExtra(_ id: Int) {
        guard let e = extraSources.first(where: { $0.id == id }) else { return }
        removeSource(id)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: e.root)
            notice = "已推出 \(e.root.lastPathComponent)，可安全取出存储卡"
        } catch {
            errorMessage = "推出存储卡失败：\(error.localizedDescription)"
        }
    }
}
