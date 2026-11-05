import Foundation
import SonyRemoteKit

/// 把一个文件从相机 / 存储卡导到本地文件夹。不碰界面状态，只管文件。
///
/// 顺序：目标位置已有同样的文件 → 跳过；本地别处有（上次下载过）→ 移动或复制过来；
/// 都没有 → 先下载成 `.文件名.part`，大小对了再改名。
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

    let library: any CameraLibrary
    /// 「保存位置」，按日期分文件夹的根目录。
    let root: URL
    let camera: String?
    var log: AppLog = .shared

    /// `progress` 报告这个文件已经传了多少字节。
    func importItem(_ item: CameraContentItem, into dir: URL,
                    progress: @escaping @Sendable (UInt64) -> Void) async throws -> Outcome {
        let fm = FileManager.default
        let target = dir.appending(path: item.filename)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if ImportHistory.matches(target, item) { return .alreadyThere(target) }

        let final = fm.fileExists(atPath: target.path) ? Self.uniqueURL(target) : target
        if let local = Self.localCopy(of: item, root: root, camera: camera), local.standardizedFileURL != final.standardizedFileURL {
            // 在下载文件夹里的就移过去，在别处（比如别的会话）的就复制。
            if local.path.hasPrefix(root.path + "/") {
                try fm.moveItem(at: local, to: final)
                log.add("用本地文件（移动）\(local.path) → \(final.path)")
            } else {
                try fm.copyItem(at: local, to: final)
                log.add("用本地文件（复制）\(local.path) → \(final.path)")
            }
            return .reused(final)
        }

        let part = dir.appending(path: ".\(item.filename).part")
        try await library.download(item, to: part) { done, _ in progress(done) }
        guard ImportHistory.matches(part, item) else {
            try? fm.removeItem(at: part)
            throw CocoaError(.fileReadCorruptFile)
        }
        try fm.moveItem(at: part, to: final)
        if let date = item.captureDate {
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: final.path)
        }
        return .downloaded(final)
    }

    // MARK: 路径

    /// 「保存位置/年/年-月-日/」。
    static func folder(for item: CameraContentItem, root: URL) -> URL {
        let key = AppModel.dayKey(item)
        guard key != "unknown" else { return root.appending(path: "没有日期", directoryHint: .isDirectory) }
        let y = String(key.prefix(4)), m = String(key.dropFirst(4).prefix(2)), d = String(key.suffix(2))
        return root.appending(path: y, directoryHint: .isDirectory).appending(path: "\(y)-\(m)-\(d)", directoryHint: .isDirectory)
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
