import Foundation
import MiniDiTCore
import SonyRemoteKit

/// 把一个文件从相机 / 存储卡导到本地：第一份 + 备份盘上的第二份，两份都用 xxHash64 校验。不碰界面状态。
///
/// 第一份：目标位置已有同样的文件 → 用它；本地别处有（上次下载过）→ 移动或复制过来；
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
            case .verifyFailed(let name): "\(name) 校验不通过（写到盘上的数据和读到的不一致）"
            }
        }
    }

    let library: any CameraLibrary
    /// 「保存位置」，按日期分文件夹的根目录。
    let root: URL
    let camera: String?
    /// 备份盘上的根目录；nil = 这次不备份。
    var backupRoot: URL?
    /// 事件名（会话「3.15-公园」里的「公园」），用在备份文件夹名里。
    var event: String?
    /// 要删卡上的文件时，对没有重新复制的文件（目标已有 / 用了本地的）也读卡比对一遍。
    var checkSource = false
    var log: AppLog = .shared

    /// 一个文件要计入进度的字节数（有备份时算两遍）。
    func weight(of item: CameraContentItem) -> UInt64 { item.size * (backupRoot == nil ? 1 : 2) }

    /// `progress` 报告这个文件已经完成了多少字节（0…weight）；`stage` 报告正在做什么；
    /// `skipped` 报告不用传、直接算完成的字节（续传时已有的部分、本地已有的文件），算速度时不计入。
    func importItem(_ item: CameraContentItem, into dir: URL,
                    progress: @escaping @Sendable (UInt64) -> Void,
                    stage: (String) -> Void,
                    skipped: (UInt64) -> Void = { _ in }) async throws -> Result {
        let (outcome, hash, fromCard) = try await primary(item, into: dir, progress: progress, stage: stage, skipped: skipped)
        var matchesSource = fromCard
        if !matchesSource, checkSource, let card = library as? LocalCardLibrary, let src = await card.fileURL(item.id) {
            stage("核对 \(item.filename)")
            matchesSource = (try? await FileOps.hash(src)) == hash
        }
        progress(item.size)
        var backup = Backup.none
        if let backupRoot {
            stage("备份 \(item.filename)")
            do {
                let u = try await copyToBackup(outcome.url, item: item, root: backupRoot, hash: hash) { d in progress(item.size + d) }
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
                         skipped: (UInt64) -> Void) async throws -> (Outcome, UInt64, fromCard: Bool) {
        let fm = FileManager.default
        let target = dir.appending(path: item.filename)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if ImportHistory.matches(target, item) {
            skipped(item.size)
            stage("校验 \(item.filename)")
            return (.alreadyThere(target), try await FileOps.hash(target), false)
        }

        let final = fm.fileExists(atPath: target.path) ? Self.uniqueURL(target) : target
        if let local = Self.localCopy(of: item, root: root, camera: camera), local.standardizedFileURL != final.standardizedFileURL {
            skipped(item.size)
            // 在下载文件夹里的就移过去，在别处（比如别的会话）的就复制。
            if local.path.hasPrefix(root.path + "/") {
                try fm.moveItem(at: local, to: final)
                log.add("用本地文件（移动）\(local.path) → \(final.path)")
                stage("校验 \(item.filename)")
                return (.reused(final), try await FileOps.hash(final), false)
            }
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
            let resume = have <= item.size ? have : 0
            if resume > 0 {
                log.add("续传 \(item.filename)：已有 \(resume)/\(item.size) 字节")
                stage("续传 \(item.filename)")
                skipped(resume)
            }
            if resume < item.size {
                do {
                    try await library.download(item, to: part, from: resume) { done, _ in progress(done) }
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
        let dir = Self.backupFolder(for: item, root: root, event: event)
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

    // MARK: 路径

    /// 没传完的文件：「.文件名.大小.拍摄时间.part」。名字里带上大小和时间，换了一张同名的照片不会接错。
    static func partName(_ item: CameraContentItem) -> String {
        ".\(item.filename).\(item.size).\(item.captureDateRaw).part"
    }

    /// 「保存位置/年/年-月-日/」。
    static func folder(for item: CameraContentItem, root: URL) -> URL {
        let key = AppModel.dayKey(item)
        guard key != "unknown" else { return root.appending(path: "没有日期", directoryHint: .isDirectory) }
        let y = String(key.prefix(4)), m = String(key.dropFirst(4).prefix(2)), d = String(key.suffix(2))
        return root.appending(path: y, directoryHint: .isDirectory).appending(path: "\(y)-\(m)-\(d)", directoryHint: .isDirectory)
    }

    /// 备份盘上：「备份位置/年-月-日-事件/」，没有事件名就是「年-月-日」。
    static func backupFolder(for item: CameraContentItem, root: URL, event: String?) -> URL {
        let key = AppModel.dayKey(item)
        var name = key == "unknown" ? "没有日期"
            : "\(key.prefix(4))-\(key.dropFirst(4).prefix(2))-\(key.suffix(2))"
        if let event, !event.isEmpty { name += "-" + event.replacingOccurrences(of: "/", with: "-") }
        return root.appending(path: name, directoryHint: .isDirectory)
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
