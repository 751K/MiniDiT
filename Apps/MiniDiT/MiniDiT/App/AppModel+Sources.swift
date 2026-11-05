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

    /// 来源显示的名字：Wi-Fi 相机用相机名；存储卡用卡上照片的机型，读不到时用卷名。
    func sourceName(_ id: Int) -> String {
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
                return
            }
        }
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
