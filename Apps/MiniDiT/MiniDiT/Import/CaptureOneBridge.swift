import AppKit
import Foundation

/// 用 AppleScript 让 Capture One 导入文件（Capture One 16 起支持 `import` 命令）。
/// 导入到 C1 当前打开的文档（目录或会话），按这个文档的导入设置执行。
@MainActor
enum CaptureOneBridge {
    static let bundleID = "com.captureone.captureone16"

    struct DocumentInfo: Equatable {
        var name: String
        var kind: String   // 「目录」或「会话」
        var folder: URL?   // 文档所在的文件夹（会话就是会话文件夹本身）
        var isSession: Bool { kind == "会话" }
    }

    enum Failure: LocalizedError {
        case notInstalled
        case script(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "未找到 Capture One。"
            case .script(let s): s
            }
        }
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil || appURL != nil
    }

    private static var appURL: URL? {
        let u = URL(filePath: "/Applications/Capture One.app")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// 确保 C1 在运行（没运行就启动，最多等 40 秒到能响应脚本）。
    static func ensureRunning() async throws {
        if isRunning { return }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) ?? appURL else { throw Failure.notInstalled }
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        for _ in 0..<40 {
            if isRunning, (try? run("tell application \"Capture One\" to return name")) != nil { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// 新建会话，返回会话的 Capture 文件夹。C1 会立刻打开这个会话。
    /// 生成的结构：<folder>/<name>/{<name>.cosessiondb, Capture, Selects, Output, Trash}
    static func createSession(name: String, in folder: URL) async throws -> URL {
        try await ensureRunning()
        // C1 里已经开着同名的文档时，脚本里按名字找到的会是那个旧文档，照片会存进别的会话。
        if openDocumentNames().contains(name) {
            throw Failure.script("Capture One 中已打开同名会话“\(name)”")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let src = """
        tell application "Capture One"
            set d to make new document with properties {name:\(quote(name)), path:\(quote(folder.path)), kind:session}
            try
                set current collection of d to (first collection of d whose name is "Capture")
            end try
            return POSIX path of (captures of d as alias)
        end tell
        """
        guard let path = try run(src).stringValue else { throw Failure.script("Capture One 未返回会话的 Capture 文件夹") }
        let returned = URL(filePath: path, directoryHint: .isDirectory)
        // 只认新会话自己的 Capture 文件夹：C1 返回了别处时，用按会话结构算出来的位置。
        let expected = folder.appending(path: name, directoryHint: .isDirectory).appending(path: "Capture", directoryHint: .isDirectory)
        if returned.standardizedFileURL.path != expected.standardizedFileURL.path {
            guard FileManager.default.fileExists(atPath: expected.path) else {
                throw Failure.script("Capture One 返回的 Capture 文件夹不属于新会话（\(returned.path)）")
            }
            return expected
        }
        return returned
    }

    /// 让 C1 重新读一遍会话的 Capture 文件夹：切到别的收藏夹再切回来。
    /// 照片是直接写进 Capture 文件夹的；C1 正忙（比如它自己弹出的导入窗口开着）时，可能不会察觉新文件。
    static func refreshCapture(session name: String) {
        guard isRunning else { return }
        _ = try? run("""
        tell application "Capture One"
            tell document \(quote(name + ".cosessiondb"))
                set c to (first collection whose name is "Capture")
                set current collection to (first collection whose name is "Selects")
                delay 0.3
                set current collection to c
            end tell
        end tell
        """)
    }

    /// C1 里打开着的文档名（不带扩展名）。C1 没在运行时为空。
    static func openDocumentNames() -> Set<String> {
        guard isRunning, let list = try? run("tell application \"Capture One\" to return name of every document") else { return [] }
        var names: Set<String> = []
        if list.numberOfItems == 0, let s = list.stringValue { names.insert(s) }
        for i in stride(from: 1, through: list.numberOfItems, by: 1) {
            if let s = list.atIndex(i)?.stringValue { names.insert(s) }
        }
        return Set(names.map { ($0 as NSString).deletingPathExtension })
    }

    /// 打开已有的会话，返回它的 Capture 文件夹。
    static func openSession(_ sessionFile: URL) async throws -> URL {
        try await ensureRunning()
        let src = """
        tell application "Capture One"
            open \(quote(sessionFile.path))
            delay 1
            repeat 20 times
                try
                    set d to current document
                    if (name of d) is \(quote(sessionFile.lastPathComponent)) then exit repeat
                end try
                delay 0.5
            end repeat
            set d to current document
            try
                set current collection of d to (first collection of d whose name is "Capture")
            end try
            return POSIX path of (captures of d as alias)
        end tell
        """
        guard let path = try run(src).stringValue else { throw Failure.script("无法打开会话") }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    /// 某个文件夹下的 C1 会话（文件夹里有同名 .cosessiondb），新的在前。
    static func sessions(in folder: URL) -> [URL] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        let files = dirs.compactMap { dir -> URL? in
            let f = dir.appending(path: dir.lastPathComponent + ".cosessiondb")
            return fm.fileExists(atPath: f.path) ? f : nil
        }
        func date(_ u: URL) -> Date {
            (try? u.deletingLastPathComponent().resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return files.sorted { date($0) > date($1) }
    }

    static var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier?.hasPrefix("com.captureone.captureone") == true || $0.localizedName == "Capture One" }
    }

    private static func run(_ source: String) throws -> NSAppleEventDescriptor {
        guard let script = NSAppleScript(source: source) else { throw Failure.script("脚本无法编译") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let msg = error[NSAppleScript.errorMessage] as? String ?? "未知错误"
            if code == -1743 {
                throw Failure.script("无权控制 Capture One。请在“系统设置 › 隐私与安全性 › 自动化”中允许 MiniDiT 控制 Capture One。")
            }
            if code == -1728 || code == -1719 {
                throw Failure.script("Capture One 中未打开任何目录或会话。请先在 Capture One 中打开要导入的目录。")
            }
            throw Failure.script("Capture One 返回错误（\(code)）：\(msg)")
        }
        return result
    }

    /// C1 当前打开的文档；C1 没运行时返回 nil（不会去启动它）。
    static func currentDocument() -> DocumentInfo? {
        guard isRunning else { return nil }
        let src = """
        tell application "Capture One"
            set d to current document
            set k to kind of d as text
            set p to ""
            try
                set p to POSIX path of ((folder of d) as alias)
            end try
            return (name of d) & "|" & k & "|" & p
        end tell
        """
        guard let r = try? run(src).stringValue else { return nil }
        let parts = r.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        let kind = parts.count > 1 && parts[1].lowercased().contains("session") ? "会话" : "目录"
        let folder = parts.count > 2 && !parts[2].isEmpty ? URL(filePath: parts[2], directoryHint: .isDirectory) : nil
        let name = (parts.first ?? r).replacingOccurrences(of: ".cosessiondb", with: "").replacingOccurrences(of: ".cocatalog", with: "")
        return DocumentInfo(name: name, kind: kind, folder: folder)
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 让 C1 导入这些文件。
    /// - inPlace: 只对目录有效：临时把导入目标改成「当前位置」（不再复制一份），导入后恢复原设置。
    static func importFiles(_ urls: [URL], inPlace: Bool) throws {
        guard !urls.isEmpty else { return }
        guard isInstalled else { throw Failure.notInstalled }
        // 必须传 POSIX 路径文本；传 file 对象 C1 会报「Invalid import source path」。
        let list = "{" + urls.map { quote($0.path) }.joined(separator: ", ") + "}"
        let src: String
        if inPlace {
            src = """
            tell application "Capture One"
                set d to current document
                set s to import settings of d
                set oldType to destination type of s
                try
                    set destination type of s to current location
                end try
                import d source \(list)
                try
                    set destination type of s to oldType
                end try
            end tell
            """
        } else {
            src = """
            tell application "Capture One"
                set d to current document
                import d source \(list)
            end tell
            """
        }
        _ = try run(src)
    }
}
