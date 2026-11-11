import Foundation
import SonyRemoteKit

/// 一次拖出中的原文件快照。与正式导入分开：不移动已有副本、不修改导入记录。
public struct FileExport: Sendable {
    public let item: CameraContentItem
    public let library: (any CameraLibrary)?
    public let localCopy: URL?

    public init(item: CameraContentItem, library: (any CameraLibrary)?, localCopy: URL? = nil) {
        self.item = item
        self.library = library
        self.localCopy = localCopy
    }

    /// 同一次拖出的不同机身可能有同名文件；预留原名，避免自动编号占用另一张照片的原名。
    public static func filenames(_ names: [String]) -> [String] {
        func key(_ name: String) -> String {
            name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        let reserved = Set(names.map(key))
        var used = Set<String>()
        return names.map { name in
            if used.insert(key(name)).inserted { return name }
            let ext = (name as NSString).pathExtension
            let stem = (name as NSString).deletingPathExtension
            var n = 2
            while true {
                let candidate = "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
                if !reserved.contains(key(candidate)), used.insert(key(candidate)).inserted { return candidate }
                n += 1
            }
        }
    }

    /// 文件承诺给出的 URL 是最终路径。先写同目录临时文件，成功才发布；已有文件绝不覆盖。
    public func write(to destination: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let part = destination.deletingLastPathComponent().appendingPathComponent(".minidit-\(UUID().uuidString).part")
        defer { try? fm.removeItem(at: part) }
        try Task.checkCancellation()
        if let localCopy, fm.fileExists(atPath: localCopy.path) {
            // 不在主线程复制几 GB 的视频；原文件（包括已导入的那份）始终保留。
            try await Task.detached {
                try FileManager.default.copyItem(at: localCopy, to: part)
            }.value
        } else if let library {
            try await library.download(item, to: part) { _, _ in }
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        try Task.checkCancellation()
        let size = try fm.attributesOfItem(atPath: part.path)[.size] as? UInt64
        guard let size, item.sizeKnown ? size == item.size : size > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let date = item.captureDate {
            try? fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: part.path)
        }
        // moveItem 在目标已存在时会失败；也保护下载期间才出现的同名文件。
        try fm.moveItem(at: part, to: destination)
    }
}

/// 文件承诺可能同时回调；按顺序兑现，避免同一台相机同时下载多个文件。
public actor FileExportQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func write(_ file: FileExport, to destination: URL) async throws {
        let previous = tail
        let task = Task {
            await previous?.value
            try await file.write(to: destination)
        }
        tail = Task { _ = try? await task.value }
        try await task.value
    }
}
