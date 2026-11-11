import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

/// 和主来源同时打开的另一个来源：一张存储卡，或另一台 Wi-Fi 相机。
struct ExtraSource: Identifiable {
    let id: Int
    var connectionID = UUID()
    /// 存储卡的卷（读卡器来源）。
    var root: URL?
    /// Wi-Fi 相机（地址、连接方式）。
    var camera: FoundCamera?
    /// 连接中或掉线时为 nil。
    var library: (any CameraLibrary)?
    var name: String = ""
    var cameraID: String?
    var deviceInfo: CameraDeviceInfo?
    var usesRemoteTransfer = false
    /// 掉线了，正在自动重连（照片和选择保留）。
    var offline = false
    var connecting = false
    var isCard: Bool { root != nil }
}

/// 一个文件在它的来源里的位置。
struct Origin: Hashable {
    let source: Int
    let local: UInt32
    var connectionID: UUID? = nil
}

/// 侧栏和筛选条上显示的一个来源。
struct SourceSummary: Identifiable, Hashable {
    let id: Int
    let name: String
    let detail: String
    let isCard: Bool
    var offline = false
    var connecting = false
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
        ImportSourceIdentity.bodyKey(model: model, serial: serial)
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
        (library.map { [(Self.primarySource, $0)] } ?? []) + extraSources.compactMap { e in e.library.map { (e.id, $0) } }
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
    func camera(of h: UInt32) -> String? {
        let id = source(of: h)
        if cardRoot(for: id) != nil {
            if let body = fileCameraKeys[h] { return body }
        } else if let body = bodyIdentity(for: id) { return body }
        if let card = sourceIdentitySnapshot(id).cardID { return "CARD:" + card.uuidString }
        return "CONNECTION:" + connectionID(for: id).uuidString
    }

    func extra(_ id: Int) -> ExtraSource? { extraSources.first { $0.id == id } }
    func extraIndex(_ id: Int) -> Int? { extraSources.firstIndex { $0.id == id } }

    /// 有来源掉线了（主来源或同时连接的相机）。掉线时不能继续导入。
    var sourcesOffline: Bool { offline || extraSources.contains { $0.offline } }

    /// 已经连着的相机地址。同一台相机开不开访问身份验证，指纹不一样（「直连」和 SSH），按地址也要排除。
    var openHosts: Set<String> {
        Set((sourceKind == .camera ? [connectedHost] : []).compactMap { $0 } + extraSources.compactMap { $0.camera?.host })
    }

    /// 已经打开的 Wi-Fi 相机的指纹（同一台不重复连）。
    var openFingerprints: Set<String> {
        Set([currentFingerprint].compactMap { $0 } + extraSources.compactMap { $0.camera?.fingerprint })
    }

    /// 交给来源去下载 / 读取时用的那份（句柄换回来源里的）。
    func localItem(_ item: CameraContentItem) -> CameraContentItem {
        origins[item.id].map { item.withID($0.local) } ?? item
    }

    // MARK: 相机档案

    /// 这个来源的机身（找档案用）。Wi-Fi 相机用机身 ID，存储卡用照片 EXIF 里的型号和序列号。
    func profileKey(_ id: Int) -> String? {
        bodyIdentity(for: id)
    }

    func profile(_ id: Int) -> CameraProfile? { profileKey(id).flatMap { cameraProfiles[$0] } ?? sessionCameraProfiles[id] }

    func updateProfile(_ id: Int, _ change: (inout CameraProfile) -> Void) {
        guard let k = profileKey(id) else {
            var p = sessionCameraProfiles[id] ?? CameraProfile(); change(&p); sessionCameraProfiles[id] = p; return
        }
        var p = cameraProfiles[k] ?? CameraProfile()
        change(&p)
        cameraProfiles[k] = p
    }

    /// 改名：名字也用在多来源导入的子文件夹上。空 = 恢复机型名。
    func rename(_ id: Int, to name: String) {
        let n = NameTemplate.sanitize(name.trimmingCharacters(in: .whitespaces))
        if let root = cardRoot(for: id) { sourceIdentities.rename(root: root, to: n) }
        else { updateProfile(id) { $0.nickname = n.isEmpty ? nil : n } }
        log.add("来源 \(id) 改名为「\(n.isEmpty ? "（机型名）" : n)」")
    }

    /// 只导某个卡槽（nil = 都导）。
    func setOnlySlot(_ id: Int, _ slot: UInt32?) {
        updateProfile(id) { $0.onlySlot = slot }
        if slot != nil { slotFilter = nil } else { rebuild() }
    }

    /// 只对 Wi-Fi 相机生效：读卡器上的卡总是「卡槽 1」，同一台机身的设置不能把它整张筛掉。
    func onlySlot(_ id: Int) -> UInt32? {
        guard isWiFiCamera(id) else { return nil }
        return profile(id)?.onlySlot
    }

    func isWiFiCamera(_ id: Int) -> Bool {
        id == Self.primarySource ? sourceKind == .camera : extra(id).map { !$0.isCard } ?? false
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
        if let root = cardRoot(for: id) { return sourceIdentities.name(for: root) }
        if let n = profile(id)?.nickname { return n }
        if id == Self.primarySource {
            if sourceKind == .card, let n = cardCameraNames[id] { return n }
            return connectedName ?? ""
        }
        guard let e = extra(id) else { return "" }
        if !e.isCard { return e.name }
        return cardCameraNames[id] ?? e.root?.lastPathComponent ?? ""
    }

    /// 界面上区分来源用的短名字：和别的来源重名时，存储卡改用卷名（两张卡都是 α7 V 拍的）。
    func sourceLabel(_ id: Int) -> String {
        let name = sourceName(id)
        let clash = sources.filter { $0.name == name }.count > 1
        guard clash else { return name }
        let identity = sourceIdentitySnapshot(id)
        if let card = identity.cardID { return name + " · " + card.uuidString.prefix(4) }
        if let serial = identity.cameraSerial { return name + " · " + serial.suffix(4) }
        return name + " · " + String(id + 1)
    }

    /// 卷名（存储卡来源）。
    func volumeName(_ id: Int) -> String? {
        if id == Self.primarySource { return sourceKind == .card ? cardRoot?.lastPathComponent : nil }
        return extra(id)?.root?.lastPathComponent
    }

    var sources: [SourceSummary] {
        var out: [SourceSummary] = []
        if library != nil || offline {
            let isCard = sourceKind == .card
            out.append(SourceSummary(id: Self.primarySource, name: sourceName(Self.primarySource),
                                     detail: identityDetail(Self.primarySource),
                                     isCard: isCard))
        }
        for e in extraSources {
            let detail = identityDetail(e.id)
            out.append(SourceSummary(id: e.id, name: sourceName(e.id), detail: detail, isCard: e.isCard,
                                     offline: e.offline, connecting: e.connecting))
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
            let tag = volumeName(s.id) ?? (isWiFiCamera(s.id) ? (s.id == Self.primarySource ? connectedHost : extra(s.id)?.camera?.host) : nil)
            var name = clash ? base + "-" + NameTemplate.sanitize(tag ?? "\(s.id + 1)") : base
            if name.isEmpty { name = "来源 \(s.id + 1)" }
            out[s.id] = name
        }
        return out
    }

    /// 有没有能按卡槽分的来源（多来源里至少一台 Wi-Fi 相机；读卡器上的卡没有卡槽之分）。
    var canSplitBySlot: Bool { isMultiSource && openSources.contains { isWiFiCamera($0.id) } }

    /// 一个文件在多来源导入时放进的子文件夹：来源名，打开「按卡槽」时 Wi-Fi 相机再加一层「卡 N」。
    func sourceFolder(for item: CameraContentItem, in folders: [Int: String]) -> String? {
        let src = source(of: item.id)
        guard let name = folders[src] else { return nil }
        guard splitBySlot, isWiFiCamera(src) else { return name }
        return name + "/卡 \(item.storageID >> 16)"
    }

    /// 某台 Wi-Fi 相机上有照片的卡槽（来源行里的卡槽切换条用）。设了只导的卡槽即使现在没照片也列上，好改回来。
    func sourceSlots(_ id: Int) -> [UInt32] {
        guard isWiFiCamera(id) else { return [] }
        var set = Set(items.compactMap { h, i in source(of: h) == id ? i.storageID >> 16 : nil })
        if let only = onlySlot(id) { set.insert(only) }
        return set.sorted()
    }

    /// 某个来源某个卡槽里的拍摄数（nil = 这个来源的全部）。不受「只导某个卡槽」影响，切换条上看得到另一张卡有多少。
    func shotCount(source id: Int, slot: UInt32?) -> Int {
        allShots.filter { s in
            source(of: s.id) == id && (slot == nil || s.handles.contains { items[$0].map { $0.storageID >> 16 == slot } ?? false })
        }.count
    }

    /// 某个来源里的拍摄数（筛选条上显示）。
    /// 设了只看某张卡时只数那张卡上的。
    func shotCount(source: Int) -> Int { shotCount(source: source, slot: onlySlot(source)) }

    /// 某个来源里还没导入的拍摄数。来源管理器直接显示这个数。
    func newShotCount(source id: Int) -> Int {
        allShots.filter {
            source(of: $0.id) == id && !importFiles(of: $0).isEmpty && !isImported(shot: $0.id)
        }.count
    }

    /// 所有已打开来源里未导入的拍摄数，不受当前来源筛选影响。
    var newShotCountAllSources: Int {
        allShots.filter { !importFiles(of: $0).isEmpty && !isImported(shot: $0.id) }.count
    }

    /// 存储卡来源：从卡上第一张照片的 EXIF 读出机型，当来源名字。
    func readCardCameraName(_ id: Int, library lib: LocalCardLibrary, handles: [UInt32]) async {
        for h in handles.prefix(40) {
            if let x = await lib.exif(h), let cam = x.camera, !cam.isEmpty {
                cardCameraNames[id] = CameraDeviceInfo.displayName(model: cam)
                if let serial = x.serial, let k = CameraProfile.bodyKey(model: cam, serial: serial) {
                    cardCameraKeys[id] = k
                } else {
                    cardCameraKeys[id] = nil
                }
                log.add("存储卡来源 \(id)：\(cam)，" + (x.serial != nil ? "已识别拍摄机身" : "机身序列号未知，卡身份单独记录"))
                return
            }
        }
    }

    // MARK: 同时打开存储卡

    /// 在当前来源之外再打开一张卡（主来源可以是相机，也可以是另一张卡）。
    func addCard(_ url: URL) {
        guard progress == nil, library != nil else { openCard(url); return }
        let std = url.resolvingSymlinksInPath().standardizedFileURL
        if cardRoot?.resolvingSymlinksInPath().standardizedFileURL == std || extraSources.contains(where: { $0.root?.resolvingSymlinksInPath().standardizedFileURL == std }) { return }
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
            guard let i = extraSources.firstIndex(where: { $0.library != nil }) else { disconnect(); return }
            let next = extraSources.remove(at: i)
            let keep = selectedKeys(), keepDays = shownDays
            let old = library
            Task { await old?.close() }
            promote(next)
            Task { await loadAll(restoring: keep, days: keepDays) }
            return
        }
        guard let i = extraIndex(id) else { return }
        let e = extraSources.remove(at: i)
        extraTasks.removeValue(forKey: id)?.cancel()
        if let lib = e.library, !e.isCard { Task { await lib.close() } }
        log.add(e.isCard ? "关闭存储卡 \(e.root?.path ?? "")" : "断开同时连接的相机 \(e.name)")
        if sourceFilter == id { sourceFilter = nil }
        cardCameraNames[id] = nil
        cardCameraKeys[id] = nil
        let keep = selectedKeys(), keepDays = shownDays
        Task { await loadAll(restoring: keep, days: keepDays) }
    }

    /// 同时打开的一张卡被拔掉了。
    func extraCardLost(_ root: URL) {
        guard let e = extraSources.first(where: { $0.root?.standardizedFileURL == root.standardizedFileURL }) else { return }
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
        guard let e = extra(id), let root = e.root else { return }
        removeSource(id)
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: root)
            notice = "已推出 \(root.lastPathComponent)，可安全取出存储卡"
        } catch {
            errorMessage = "推出存储卡失败：\(error.localizedDescription)"
        }
    }
}
