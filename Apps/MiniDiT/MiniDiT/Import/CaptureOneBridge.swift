import AppKit
import Foundation
import SQLite3

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
        /// 界面显示用；kind 本身用于比较，保持不变。
        var kindTitle: String { isSession ? String(localized: "会话") : String(localized: "目录") }
    }

    enum Failure: LocalizedError {
        case notInstalled
        case script(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: String(localized: "未找到 Capture One。")
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

    struct SessionTarget: Hashable {
        let database: URL
        let captureDir: URL
        var name: String { database.deletingPathExtension().lastPathComponent }

        init(database: URL) {
            self.database = database.standardizedFileURL
            let root = database.deletingLastPathComponent()
            captureDir = CaptureOneBridge.storedCaptureFolder(database) ?? root.appending(path: "Capture", directoryHint: .isDirectory)
        }
    }

    /// Read a session's chosen Capture location without opening it in C1.
    nonisolated private static func storedCaptureFolder(_ database: URL) -> URL? {
        guard FileManager.default.fileExists(atPath: database.path) else { return nil }
        var db: OpaquePointer?
        let status = sqlite3_open_v2(database.path, &db, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(db) }
        guard status == SQLITE_OK else { return nil }
        var statement: OpaquePointer?
        let sql = """
        SELECT p.ZISRELATIVE, p.ZMACROOT, p.ZRELATIVEPATH
        FROM ZCOLLECTION c
        LEFT JOIN ZCOLLECTION capture ON c.ZCAPTURECOLLECTION = capture.Z_PK
        JOIN ZPATHLOCATION p ON COALESCE(capture.ZFOLDERLOCATION, c.ZCAPTUREDESTINATIONLOCATION) = p.Z_PK
        WHERE c.ZNAME = 'root' LIMIT 1
        """
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let path = sqlite3_column_text(statement, 2).map { String(cString: $0) } ?? ""
        if sqlite3_column_int(statement, 0) != 0 {
            guard !path.isEmpty else { return nil }
            return database.deletingLastPathComponent().appending(path: path, directoryHint: .isDirectory).standardizedFileURL
        }
        let root = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
        if path.hasPrefix("/") { return URL(filePath: path, directoryHint: .isDirectory) }
        guard root.hasPrefix("/") else { return nil }
        return URL(filePath: root, directoryHint: .isDirectory).appending(path: path, directoryHint: .isDirectory).standardizedFileURL
    }

    /// C1 requires an empty location for creation. Build the blank session next to the
    /// completed project, then move its database into place without moving any photos.
    static func openCompletedSession(_ target: SessionTarget) async throws {
        try Task.checkCancellation()
        try await ensureRunning()
        try Task.checkCancellation()
        let fm = FileManager.default
        if !fm.fileExists(atPath: target.database.path) {
            if openDocumentNames().contains(target.name) {
                throw Failure.script(String(localized: "Capture One 中已打开同名会话“\(target.name)”"))
            }
            let project = target.database.deletingLastPathComponent()
            let staging = project.deletingLastPathComponent()
                .appending(path: ".minidit-c1-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: staging) }
            _ = try run("""
            tell application "Capture One"
                set d to make new document with properties {name:\(quote(target.name)), path:\(quote(staging.path)), kind:session}
                close d
            end tell
            """)
            let generated = staging.appending(path: target.name, directoryHint: .isDirectory)
            for folder in try fm.contentsOfDirectory(at: generated, includingPropertiesForKeys: nil)
                where folder.lastPathComponent != target.database.lastPathComponent {
                let destination = project.appending(path: folder.lastPathComponent)
                if !fm.fileExists(atPath: destination.path) { try fm.moveItem(at: folder, to: destination) }
            }
            try fm.moveItem(at: generated.appending(path: target.database.lastPathComponent), to: target.database)
        }
        try await openSession(target)
    }

    struct LookResult {
        var applied = 0
        var notFound = Set<String>()
        var noProfile = Set<String>()
        var failures: [String] = []
        var scriptError: String?
        var refreshError: String?
    }

    /// Match the actual RAW, not a same-named JPG/HIF. Confirm both settings before reporting success.
    static func applyLooks(session name: String, collection: String, _ pairs: [(file: URL, look: String)]) -> LookResult {
        var result = LookResult()
        guard !pairs.isEmpty else { return result }
        guard isRunning else { result.scriptError = String(localized: "Capture One 未运行"); return result }
        let list = pairs.map { pair in
            let stem = pair.file.deletingPathExtension().lastPathComponent
            return "{\(quote(stem)), \(quote(pair.file.path)), \(quote(pair.look))}"
        }.joined(separator: ", ")
        // 脚本返回给界面的文字按界面语言在此生成。
        let unconfirmed = quote(String(localized: "Capture One 未确认 ICC 配置文件和曲线"))
        let restoreFailed = quote(String(localized: "；恢复原设置失败："))
        let src = """
        tell application "Capture One"
            set d to document \(quote(name + ".cosessiondb"))
            tell d
                set c to (first collection whose name is \(quote(collection)))
                set out to {}
                repeat with p in {\(list)}
                    set n to item 1 of p
                    set targetPath to item 2 of p
                    set resolvedTarget to my canonicalLookPath(targetPath)
                    set lookCode to item 3 of p
                    try
                        set v to missing value
                        repeat with candidate in (every variant of c whose name is n)
                            set candidatePath to path of parent image of candidate
                            if candidatePath is targetPath or my canonicalLookPath(candidatePath) is resolvedTarget then
                                set v to contents of candidate
                                exit repeat
                            end if
                        end repeat
                        if v is missing value then
                            set end of out to ("missing:" & targetPath)
                        else
                            set cp to color profile of adjustments of v
                            set oldCurve to film curve of adjustments of v
                            set AppleScript's text item delimiters to " Look-"
                            if (count of text items of cp) > 1 then
                                set base to text item 1 of cp
                            else
                                set AppleScript's text item delimiters to " "
                                set parts to text items of cp
                                set base to (items 1 thru -2 of parts) as text
                            end if
                            set AppleScript's text item delimiters to ""
                            set profileName to (base & " Look-" & lookCode)
                            set changedProfile to false
                            try
                                set color profile of adjustments of v to profileName
                                set changedProfile to true
                                set film curve of adjustments of v to "Linear Response"
                                if (color profile of adjustments of v is not profileName) or (film curve of adjustments of v is not "Linear Response") then
                                    error \(unconfirmed)
                                end if
                                set end of out to "ok"
                            on error msg
                                if changedProfile then
                                    try
                                        set color profile of adjustments of v to cp
                                        set film curve of adjustments of v to oldCurve
                                    on error restoreError
                                        set msg to (msg & \(restoreFailed) & restoreError)
                                    end try
                                end if
                                if not changedProfile and msg contains "Unrecognized color profile" then
                                    set end of out to ("noprofile:" & profileName)
                                else
                                    set end of out to ("failed:" & n & linefeed & msg)
                                end if
                            end try
                        end if
                    on error msg
                        set AppleScript's text item delimiters to ""
                        set end of out to ("failed:" & n & linefeed & msg)
                    end try
                end repeat
            end tell
            if out contains "ok" then
                try
                    refresh d
                on error msg
                    set end of out to ("refresh:" & msg)
                end try
            end if
            return out
        end tell

        on canonicalLookPath(p)
            try
                return POSIX path of ((POSIX file p) as alias)
            on error
                return p
            end try
        end canonicalLookPath
        """
        let response: NSAppleEventDescriptor
        do { response = try run(src) }
        catch { result.scriptError = error.localizedDescription; return result }
        for i in stride(from: 1, through: response.numberOfItems, by: 1) {
            guard let status = response.atIndex(i)?.stringValue else { continue }
            if status == "ok" { result.applied += 1 }
            else if status.hasPrefix("missing:") { result.notFound.insert(String(status.dropFirst(8))) }
            else if status.hasPrefix("noprofile:") { result.noProfile.insert(String(status.dropFirst(10))) }
            else if status.hasPrefix("failed:") {
                // 照片名与错误之间以换行分隔，由此按界面语言拼接。
                let parts = status.dropFirst(7).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                result.failures.append(parts.count == 2 ? String(localized: "\(parts[0])：\(parts[1])") : parts.joined())
            }
            else if status.hasPrefix("refresh:") { result.refreshError = String(status.dropFirst(8)) }
        }
        return result
    }

    /// C1 里打开着的文档名（不带扩展名）。C1 没在运行时为空。
    /// 按相机里打的星级给会话里的照片设星级（同名的 RAW 和 HIF 变体都设）。返回设上的变体名；还没出现的不在里面。
    static func applyRatings(session name: String, collection: String, _ pairs: [(variant: String, rating: Int)]) -> Set<String> {
        guard isRunning, !pairs.isEmpty else { return [] }
        let list = pairs.map { "{\(quote($0.variant)), \(max(0, min($0.rating, 5)))}" }.joined(separator: ", ")
        let src = """
        tell application "Capture One"
            tell document \(quote(name + ".cosessiondb"))
                set c to (first collection whose name is \(quote(collection)))
                set out to {}
                repeat with p in {\(list)}
                    set n to item 1 of p
                    try
                        set vs to (every variant of c whose name is n)
                        if (count of vs) > 0 then
                            repeat with v in vs
                                set rating of v to (item 2 of p)
                            end repeat
                            set end of out to n
                        end if
                    end try
                end repeat
                return out
            end tell
        end tell
        """
        guard let res = try? run(src) else { return [] }
        return Set((1...max(res.numberOfItems, 1)).compactMap { res.atIndex($0)?.stringValue })
    }

    static func openDocumentNames() -> Set<String> {
        guard isRunning, let list = try? run("tell application \"Capture One\" to return name of every document") else { return [] }
        var names: Set<String> = []
        if list.numberOfItems == 0, let s = list.stringValue { names.insert(s) }
        for i in stride(from: 1, through: list.numberOfItems, by: 1) {
            if let s = list.atIndex(i)?.stringValue { names.insert(s) }
        }
        return Set(names.map { ($0 as NSString).deletingPathExtension })
    }

    /// Open the exact session after its files have been saved and request a scan.
    private static func openSession(_ target: SessionTarget) async throws {
        let sessionFile = target.database
        let folder = sessionFile.deletingLastPathComponent().resolvingSymlinksInPath()
        let src = """
        tell application "Capture One"
            open \(quote(sessionFile.path))
            set expectedFolder to (POSIX file \(quote(folder.path)) as alias)
            repeat 20 times
                try
                    set d to current document
                    if (name of d) is \(quote(sessionFile.lastPathComponent)) and (folder of d as alias) is expectedFolder then
                        set c to first collection of d whose name is \(quote(target.captureDir.lastPathComponent))
                        set current collection of d to c
                        set synchronizing of c to true
                        return true
                    end if
                end try
                delay 0.5
            end repeat
            return false
        end tell
        """
        guard try run(src).booleanValue else { throw Failure.script(String(localized: "无法打开或读取 Capture One 会话“\(sessionFile.deletingPathExtension().lastPathComponent)”")) }
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
        guard let script = NSAppleScript(source: source) else { throw Failure.script(String(localized: "脚本无法编译")) }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int ?? 0
            let msg = error[NSAppleScript.errorMessage] as? String ?? String(localized: "未知错误")
            if code == -1743 {
                throw Failure.script(String(localized: "无权控制 Capture One。请在“系统设置 › 隐私与安全性 › 自动化”中允许 MiniDiT 控制 Capture One。"))
            }
            if code == -1728 || code == -1719 {
                throw Failure.script(String(localized: "Capture One 中未打开任何目录或会话。请先在 Capture One 中打开要导入的目录。"))
            }
            throw Failure.script(String(localized: "Capture One 返回错误（\(code)）：\(msg)"))
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
