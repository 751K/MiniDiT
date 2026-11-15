import Foundation
import MiniDiTCore
import SonyRemoteKit

/// 把一个文件从相机 / 存储卡导到本地：第一份 + 备份盘上的第二份，两份都用 xxHash64 校验。不碰界面状态。
///
/// 第一份：目标位置已有同样的文件 → 用它；本地别处有（上次下载过）→ 复制过来；
/// 都没有 → 先下载成 `.文件名.part`，校验通过再改名。
/// 第二份：「备份位置/年-月-日-事件/文件名」，复制后从盘上读回来比对哈希。
///
/// 读卡器来源会在复制时同时算卡上数据的哈希，和写好的文件比对，是真正的端到端校验；
/// Wi-Fi 下载拿不到相机那边的哈希，第一份只能核对大小，哈希从写好的文件算出来，用来校验第二份。
@MainActor
struct FileImporter {
    enum Outcome {
        /// 目标位置已经有同样大小的同名文件：不重复下载，也不再交给 C1。
        case alreadyThere(URL)
        /// 用了本地已有的那份。
        case reused(URL)
        case downloaded(URL)

        var url: URL {
            switch self {
            case .alreadyThere(let u), .reused(let u), .downloaded(let u): u
            }
        }
    }

    enum Backup {
        /// 没有设置备份位置，或备份盘没接上。
        case none
        case done(URL)
        case failed(String)
    }

    struct Result {
        var outcome: Outcome
        var xxh64: UInt64
        var backup: Backup
        /// 确认过第一份和存储卡上的数据一致（只有读卡器来源能确认）。
        var matchesSource: Bool
    }

    enum ImportError: LocalizedError {
        case verifyFailed(String)
        var errorDescription: String? {
            switch self {
            case .verifyFailed(let name): "\(name) 校验未通过（写入磁盘的数据与读取的数据不一致）"
            }
        }
    }

    let library: any CameraLibrary
    /// 「保存位置」，按日期分文件夹的根目录。
    let root: URL
    let camera: String?
    /// 备份盘上的根目录；nil = 这次不备份。
    var backupRoot: URL?
    /// 事件名（会话「3.15-公园」里的「公园」）和场次号，用在备份文件夹名里。
    var event: String?
    var scene: Int?
    /// 几个来源一起导时，备份盘上日期文件夹里再按来源分的子文件夹（「2026-11-04-公园/α7 V/」）。
    var sourceFolder: String?
    /// 备份盘上日期文件夹里再分的一层：视频放「视频/」，和照片分开。
    var backupSubfolder: String?
    /// 要删卡上的文件时，对没有重新复制的文件（目标已有 / 用了本地的）也读卡比对一遍。
    /// 指定时镜像主副本的目录；nil 时沿用旧版自定义备份规则。
    var backupDirectory: URL?
    var checkSource = false
    var log: AppLog = .shared

    /// 一个文件要计入进度的字节数（有备份时算两遍）。
    /// 一个文件在总进度里的权重；大小未知时优先用实际写好的文件，其次按 4 GiB 估算。
    func weight(of item: CameraContentItem, at url: URL? = nil) -> UInt64 {
        (url.flatMap(Self.fileSize) ?? item.sizeEstimate) * (backupRoot == nil ? 1 : 2)
    }

    /// 文件实际大小（导入完成后的文件可能和 ObjectInfo 里的未知大小不同）。
    static func fileSize(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64
    }

    /// `progress` 报告这个文件已经完成了多少字节（0…weight）；`stage` 报告正在做什么；
    /// `skipped` 报告不用传、直接算完成的字节（续传时已有的部分、本地已有的文件），算速度时不计入。
    func importItem(_ item: CameraContentItem, into dir: URL,
                    progress: @escaping @Sendable (UInt64) -> Void,
                    stage: (String) -> Void,
                    skipped: (UInt64) -> Void = { _ in },
                    resumed: (UInt64) -> Void = { _ in },
                    primarySaved: (URL, UInt64, Bool) -> Void = { _, _, _ in }) async throws -> Result {
        let (outcome, hash, fromCard) = try await primary(item, into: dir, progress: progress, stage: stage,
                                                          skipped: skipped, resumed: resumed)
        var matchesSource = fromCard
        if !matchesSource, checkSource, let card = library as? LocalCardLibrary, let src = await card.fileURL(item.id) {
            stage("核对 \(item.filename)")
            matchesSource = (try? await FileOps.hash(src)) == hash
        }
        primarySaved(outcome.url, hash, matchesSource)
        try Task.checkCancellation()
        // 大小未知（≥4GB）的视频以实际写好的文件为准，进度和备份进度才有正确的基准。
        let primarySize = Self.fileSize(outcome.url) ?? item.size
        progress(primarySize)
        var backup = Backup.none
        if let backupRoot {
            stage("备份 \(item.filename)")
            do {
                let u = try await copyToBackup(outcome.url, item: item, root: backupRoot, hash: hash) { d in progress(primarySize + d) }
                backup = .done(u)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                log.add("备份失败 \(item.filename)：\(error.localizedDescription)")
                backup = .failed(error.localizedDescription)
            }
        }
        return Result(outcome: outcome, xxh64: hash, backup: backup, matchesSource: matchesSource)
    }

    // MARK: 第一份

    private func primary(_ item: CameraContentItem, into dir: URL,
                         progress: @escaping @Sendable (UInt64) -> Void,
                         stage: (String) -> Void,
                         skipped: (UInt64) -> Void,
                         resumed: (UInt64) -> Void) async throws -> (Outcome, UInt64, fromCard: Bool) {
        let fm = FileManager.default
        let target = dir.appending(path: item.filename)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if ImportHistory.matches(target, item) {
            stage("校验 \(item.filename)")
            let hash = try await FileOps.hash(target)
            var same = false
            var fromCard = false
            if let card = library as? LocalCardLibrary, let source = await card.fileURL(item.id) {
                same = try await FileOps.hash(source) == hash
                fromCard = same
            } else if let record = ImportHistory.shared.record(for: item, camera: camera), let path = record.path {
                same = URL(filePath: path).standardizedFileURL == target.standardizedFileURL
                    && record.xxh64 == XXH64.hex(hash)
            }
            if same {
                skipped(Self.fileSize(target) ?? item.size)
                return (.alreadyThere(target), hash, fromCard)
            }
        }

        let final = fm.fileExists(atPath: target.path) ? Self.uniqueURL(target) : target
        var local = ImportHistory.shared.localFile(item, camera: camera)
        if local == nil, library is LocalCardLibrary { local = Self.localCopy(of: item, root: root, camera: camera) }
        if let candidate = local, let card = library as? LocalCardLibrary, let source = await card.fileURL(item.id),
           try await FileOps.hash(candidate) != FileOps.hash(source) {
            local = nil
        }
        if let local, local.standardizedFileURL != final.standardizedFileURL {
            skipped(Self.fileSize(local) ?? item.size)
            // 同一文件可能属于已有会话，改变整理偏好时保留原来的那份。
            stage("复制 \(item.filename)")
            let h = try await verifiedCopy(from: local, to: final, name: item.filename, progress: progress)
            log.add("用本地文件（复制）\(local.path) → \(final.path)")
            return (.reused(final), h, false)
        }

        let part = dir.appending(path: Self.partName(item))
        let hash: UInt64
        var fromCard = false
        if let card = library as? LocalCardLibrary, let src = await card.fileURL(item.id) {
            // 读卡器：自己复制，边读卡边算哈希，再和写好的文件比对。
            hash = try await verifiedCopy(from: src, to: part, name: item.filename, progress: progress)
            fromCard = true
            guard ImportHistory.matches(part, item) else { try? fm.removeItem(at: part); throw CocoaError(.fileReadCorruptFile) }
        } else {
            // 断点续传：上次没传完的 .part 还在，就从它的末尾接着读。
            let have = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? UInt64 ?? 0
            // 大小未知（≥4GB）时 item.size 是 0，不能拿来判断进度；从 0 开始流式下载。
            let resume = item.sizeKnown && have <= item.size ? have : 0
            if resume > 0 {
                log.add("续传 \(item.filename)：已有 \(resume)/\(item.size) 字节")
                stage("续传 \(item.filename)")
                resumed(resume)
                skipped(resume)
            }
            if !item.sizeKnown || resume < item.size {
                do {
                    try await library.download(item, to: part, from: resume) { done, _ in progress(done) }
                    if let rt = library as? SonyRemoteTransferLibrary, let note = await rt.lastDownloadNote { log.add(note) }
                } catch {
                    // 一个字节都没收到的 .part 没有续传价值，删掉，免得文件夹里留一堆空文件。
                    if ((try? fm.attributesOfItem(atPath: part.path))?[.size] as? UInt64 ?? 0) == 0 { try? fm.removeItem(at: part) }
                    throw error
                }
            }
            guard ImportHistory.matches(part, item) else { try? fm.removeItem(at: part); throw CocoaError(.fileReadCorruptFile) }
            stage("校验 \(item.filename)")
            hash = try await FileOps.hash(part)
        }
        try fm.moveItem(at: part, to: final)
        if let date = item.captureDate {
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: final.path)
        }
        return (.downloaded(final), hash, fromCard)
    }

    /// 复制并读回来比对；返回源数据的哈希。不一致时删掉目标。
    private func verifiedCopy(from src: URL, to dst: URL, name: String,
                              progress: @escaping @Sendable (UInt64) -> Void) async throws -> UInt64 {
        let h = try await FileOps.copy(from: src, to: dst, progress: progress)
        guard try await FileOps.hash(dst) == h else {
            try? FileManager.default.removeItem(at: dst)
            throw ImportError.verifyFailed(name)
        }
        return h
    }

    // MARK: 第二份

    private func copyToBackup(_ file: URL, item: CameraContentItem, root: URL, hash: UInt64,
                              progress: @escaping @Sendable (UInt64) -> Void) async throws -> URL {
        let fm = FileManager.default
        let dir = backupDir(for: item, root: root)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir.appending(path: item.filename)
        if fm.fileExists(atPath: target.path) {
            // 已经备份过同一个文件：哈希一致就不再复制。
            if ImportHistory.matches(target, item), try await FileOps.hash(target) == hash { return target }
            target = Self.uniqueURL(target)
        }
        let part = dir.appending(path: Self.partName(item))
        let read = try await FileOps.copy(from: file, to: part, progress: progress)
        let written = try await FileOps.hash(part)
        guard read == hash, written == hash else {
            try? fm.removeItem(at: part)
            throw ImportError.verifyFailed(item.filename)
        }
        try fm.moveItem(at: part, to: target)
        if let date = item.captureDate {
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: target.path)
        }
        return target
    }

    /// 备份盘上这个文件所在的文件夹：「年-月-日-事件/[视频/][来源/]」。
    private func backupDir(for item: CameraContentItem, root: URL) -> URL {
        if let backupDirectory { return backupDirectory }
        var dir = Self.backupFolder(for: item, root: root, event: event, scene: scene)
        if let backupSubfolder { dir = dir.appending(path: backupSubfolder, directoryHint: .isDirectory) }
        if let sourceFolder { dir = dir.appending(path: sourceFolder, directoryHint: .isDirectory) }
        return dir
    }

    // MARK: 只导代理

    struct ProxyOnlyResult {
        var proxy: SidecarCopy
        var xml: SidecarCopy?
    }

    /// Wi-Fi「视频只导代理」：原片留在卡上，只下载代理（Proxy/C0001.MP4）和 XML（读原片末尾内嵌的那份）。
    /// 放的位置和完整导入时一样，之后用读卡器导原片时，这两个文件核对一致就不再复制。
    /// 相机上这段没有代理时返回 nil。
    func importProxyOnly(_ item: CameraContentItem, into dir: URL,
                         progress: @escaping @Sendable (UInt64) -> Void,
                         stage: (String) -> Void, issue: (String) -> Void = { _ in }) async throws -> ProxyOnlyResult? {
        guard let p = await library.proxy(of: item.id) else { return nil }
        let rel = "Proxy/" + item.baseName + "." + (p.filename as NSString).pathExtension
        stage("下载代理 \(item.filename)")
        let dst = dir.appending(path: rel)
        let (h, there) = try await downloadSidecar(p, to: dst, progress: progress)
        let bdir = backupRoot.map { backupDir(for: item, root: $0) }
        @MainActor func backup(_ file: URL, rel: String, hash: UInt64) async -> URL? {
            guard let bdir else { return nil }
            let b = bdir.appending(path: rel)
            do { _ = try await copySidecar(file, to: b, expect: hash); return b }
            catch { let message = "备份失败 \(rel)：\(error.localizedDescription)"; log.add(message); issue(message); return nil }
        }
        if bdir != nil { stage("备份代理 \(item.filename)") }
        var result = ProxyOnlyResult(proxy: SidecarCopy(url: dst, xxh64: h, backup: await backup(dst, rel: rel, hash: h), alreadyThere: there))
        if let xml = await library.clipXML(item.id) {
            let xrel = item.baseName + "M01.XML"
            let x = dir.appending(path: xrel)
            do {
                let same = (try? Data(contentsOf: x)) == xml
                if !same { try xml.write(to: x, options: .atomic) }
                if let d = item.captureDate { try? FileManager.default.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: x.path) }
                let xh = try await FileOps.hash(x)
                result.xml = SidecarCopy(url: x, xxh64: xh, backup: await backup(x, rel: xrel, hash: xh), alreadyThere: same)
            } catch {
                log.add("写入 \(xrel) 失败：\(error.localizedDescription)")
                issue("写入 \(xrel) 失败：\(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: 视频的附属文件

    struct SidecarCopy {
        var url: URL
        var xxh64: UInt64
        var backup: URL?
        /// 目标位置已经有同样的文件，没有重新复制。
        var alreadyThere: Bool
    }

    /// 视频片段的附属文件，跟着片段放：XML 放在片段旁边（C0001M01.XML），
    /// 代理放进旁边的 Proxy/ 并改成和片段同名（Proxy/C0001.MP4，Resolve 导入片段时会自动链接）。
    /// 片段因为重名改成了「C0001-2.MP4」时，附属文件跟着改。`clip` / `backupClip` 是片段最终的位置。
    /// 读卡器：从卡上复制 XML 和 SUB 里的代理。Wi-Fi：相机列表里有代理就下载；XML 相机不给，
    /// 从下载好的 MP4 末尾切出内嵌的那份（和卡上的 M01.XML 一字不差）。
    func importSidecars(of item: CameraContentItem, clip: URL, backupClip: URL?, proxies: Bool,
                        stage: (String) -> Void, issue: (String) -> Void = { _ in }) async -> [SidecarCopy] {
        let base = clip.deletingPathExtension().lastPathComponent
        let dir = clip.deletingLastPathComponent()
        var out: [SidecarCopy] = []
        var haveXML = false
        @MainActor func backup(_ file: URL, rel: String, hash: UInt64) async -> URL? {
            guard let backupClip else { return nil }
            let b = backupClip.deletingLastPathComponent().appending(path: rel)
            do { _ = try await copySidecar(file, to: b, expect: hash); return b }
            catch { let message = "备份失败 \(rel)：\(error.localizedDescription)"; log.add(message); issue(message); return nil }
        }
        if let card = library as? LocalCardLibrary {
            for s in await card.sidecars(item.id) where s.kind == .metadata || proxies {
                let name = s.url.lastPathComponent
                // 「C0001M01.XML」去掉原来的「C0001」，换成片段最终的名字。
                // 大疆的 .LRF 其实是 MP4，改成 .MP4 才能被 Resolve 认成代理。
                let ext = s.url.pathExtension.uppercased() == "LRF" ? "MP4" : s.url.pathExtension
                let rel = s.kind == .proxy ? "Proxy/" + base + "." + ext
                    : base + String(name.dropFirst(item.baseName.count))
                stage(s.kind == .proxy ? "复制代理 \(name)" : "复制 \(name)")
                do {
                    let dst = dir.appending(path: rel)
                    let (h, there) = try await copySidecar(s.url, to: dst)
                    out.append(SidecarCopy(url: dst, xxh64: h, backup: await backup(dst, rel: rel, hash: h), alreadyThere: there))
                    if s.kind == .metadata { haveXML = true }
                } catch is CancellationError {
                    return out
                } catch {
                    log.add("复制失败 \(name)：\(error.localizedDescription)")
                issue("复制失败 \(name)：\(error.localizedDescription)")
                }
            }
        } else if proxies, let p = await library.proxy(of: item.id) {
            let rel = "Proxy/" + base + "." + (p.filename as NSString).pathExtension
            stage("下载代理 \(p.filename)")
            do {
                let dst = dir.appending(path: rel)
                let (h, there) = try await downloadSidecar(p, to: dst)
                out.append(SidecarCopy(url: dst, xxh64: h, backup: await backup(dst, rel: rel, hash: h), alreadyThere: there))
            } catch is CancellationError {
                return out
            } catch {
                log.add("下载代理失败 \(p.filename)：\(error.localizedDescription)")
                issue("下载代理失败 \(p.filename)：\(error.localizedDescription)")
            }
        }
        if !haveXML, let xml = ClipInfo.embeddedXML(inFile: clip) {
            let rel = base + "M01.XML"
            let dst = dir.appending(path: rel)
            do {
                let there = (try? Data(contentsOf: dst)) == xml
                if !there { try xml.write(to: dst, options: .atomic) }
                if let d = item.captureDate { try? FileManager.default.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: dst.path) }
                let h = try await FileOps.hash(dst)
                out.append(SidecarCopy(url: dst, xxh64: h, backup: await backup(dst, rel: rel, hash: h), alreadyThere: there))
            } catch {
                log.add("写入 \(rel) 失败：\(error.localizedDescription)")
                issue("写入 \(rel) 失败：\(error.localizedDescription)")
            }
        }
        return out
    }

    /// Wi-Fi 下载代理：目标已有同样大小的文件就不再下载（相机给不出哈希，只能比大小）。
    private func downloadSidecar(_ p: CameraContentItem, to dst: URL,
                                 progress: @escaping @Sendable (UInt64) -> Void = { _ in }) async throws -> (UInt64, Bool) {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if ImportHistory.matches(dst, p) { return (try await FileOps.hash(dst), true) }
        let part = dst.deletingLastPathComponent().appending(path: Self.partName(p))
        let have = (try? fm.attributesOfItem(atPath: part.path))?[.size] as? UInt64 ?? 0
        try await library.download(p, to: part, from: have <= p.size ? have : 0) { done, _ in progress(done) }
        guard ImportHistory.matches(part, p) else { try? fm.removeItem(at: part); throw CocoaError(.fileReadCorruptFile) }
        let h = try await FileOps.hash(part)
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: part, to: dst)
        if let d = p.captureDate { try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: dst.path) }
        return (h, false)
    }

    /// 复制并校验一个附属文件；目标已有且哈希一致就不再复制。返回哈希和「是不是已经有了」。
    private func copySidecar(_ src: URL, to dst: URL, expect: UInt64? = nil) async throws -> (UInt64, Bool) {
        let fm = FileManager.default
        try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        let want: UInt64
        if let expect { want = expect } else { want = try await FileOps.hash(src) }
        if fm.fileExists(atPath: dst.path), try await FileOps.hash(dst) == want { return (want, true) }
        let part = dst.deletingLastPathComponent().appending(path: "." + dst.lastPathComponent + ".part")
        let read = try await FileOps.copy(from: src, to: part)
        guard read == want, try await FileOps.hash(part) == want else {
            try? fm.removeItem(at: part)
            throw ImportError.verifyFailed(src.lastPathComponent)
        }
        if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
        try fm.moveItem(at: part, to: dst)
        if let d = (try? fm.attributesOfItem(atPath: src.path))?[.modificationDate] as? Date {
            try? fm.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: dst.path)
        }
        return (want, false)
    }

    // MARK: 路径

    /// 这个文件没传完、留着等续传的字节数。
    static func savedPartBytes(_ item: CameraContentItem, in dir: URL) -> UInt64 {
        let part = dir.appending(path: partName(item))
        return (try? FileManager.default.attributesOfItem(atPath: part.path))?[.size] as? UInt64 ?? 0
    }

    /// 没传完的文件：「.文件名.大小.拍摄时间.part」。名字里带上大小和时间，换了一张同名的照片不会接错。
    static func partName(_ item: CameraContentItem) -> String {
        ".\(item.filename).\(item.size).\(item.captureDateRaw).part"
    }

    /// 下载文件夹：「保存位置/」+ 模板（默认「年/年-月-日」）。
    static func folder(for item: CameraContentItem, root: URL, event: String? = nil, scene: Int? = nil) -> URL {
        NameTemplate.folder(.folder, root: root, day: AppModel.dayKey(item), event: event, scene: scene)
    }

    /// 视频文件夹：「视频保存位置/」+ 模板（默认「{M}.{D}-{事件}」）。
    static func videoFolder(for item: CameraContentItem, root: URL, event: String?, scene: Int? = nil, roll: String? = nil) -> URL {
        NameTemplate.folder(.video, root: root, day: AppModel.dayKey(item), event: event, scene: scene, roll: roll)
    }

    /// 备份盘上：「备份位置/」+ 模板（默认「年-月-日-事件」，没有事件名就是「年-月-日」）。
    static func backupFolder(for item: CameraContentItem, root: URL, event: String?, scene: Int? = nil) -> URL {
        NameTemplate.folder(.backup, root: root, day: AppModel.dayKey(item), event: event, scene: scene)
    }

    /// 本地已有的同一个文件：先看导入记录里的位置，再看「保存位置/年/年-月-日/」（旧版记录没有位置）。
    static func localCopy(of item: CameraContentItem, root: URL, camera: String?) -> URL? {
        if let u = ImportHistory.shared.localFile(item, camera: camera) { return u }
        let guess = folder(for: item, root: root).appending(path: item.filename)
        return ImportHistory.matches(guess, item) ? guess : nil
    }

    /// 重名时加「-2」「-3」…
    static func uniqueURL(_ url: URL) -> URL {
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        let dir = url.deletingLastPathComponent()
        for n in 2...999 {
            let u = dir.appending(path: "\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)"))
            if !FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return dir.appending(path: "\(base)-\(UUID().uuidString.prefix(6)).\(ext)")
    }
}
