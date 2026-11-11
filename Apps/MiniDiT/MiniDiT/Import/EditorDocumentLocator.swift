import Foundation

/// 找与 MiniDiT 项目同名的剪辑工程文件（FCP 资源库、Premiere 项目）。
/// 先用 Spotlight 找已有的同名文件，找到几个时取最近修改的；没有就放在「影片」文件夹，交给软件新建。
enum EditorDocumentLocator {
    static var defaultFolder: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: "Movies", directoryHint: .isDirectory) }

    /// 文件名就是项目名：去掉路径分隔符和开头的点。
    static func fileName(_ name: String, extension ext: String) -> String {
        var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix(".") { base.removeFirst() }
        return (base.isEmpty ? "MiniDiT" : base) + "." + ext
    }

    static func locate(name: String, extension ext: String, defaultFolder: URL = defaultFolder) -> URL {
        let file = fileName(name, extension: ext)
        let fallback = defaultFolder.appending(path: file, directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: fallback.path) { return fallback }
        let found = spotlight(file).filter { url in
            !url.pathComponents.contains(".Trash") && !url.pathComponents.contains(".Trashes")
                && FileManager.default.fileExists(atPath: url.path)
        }
        let modified = { (url: URL) in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        return found.max { modified($0) < modified($1) } ?? fallback
    }

    /// Spotlight 精确匹配文件名；没有索引或查询失败时当作没找到。
    private static func spotlight(_ file: String) -> [URL] {
        let escaped = file.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "*", with: "\\*")
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/mdfind")
        process.arguments = ["kMDItemFSName == \"\(escaped)\"c"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map { URL(filePath: String($0)) }
            .filter { $0.lastPathComponent.caseInsensitiveCompare(file) == .orderedSame }
    }
}
