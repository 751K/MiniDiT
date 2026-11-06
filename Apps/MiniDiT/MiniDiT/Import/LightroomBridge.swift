import AppKit
import Foundation
import SonyRemoteKit

/// 和 Lightroom Classic 里的 MiniDiT 插件打交道：安装插件、看它在不在跑、交任务。
///
/// LrC 没有 AppleScript，只能靠插件（见 `LightroomPlugin`）。App 把下载好的照片写成任务文件放进共享文件夹，
/// 插件每秒扫一次；再发一个 `lightroom://` 链接让它马上处理。LrC 没开时这个链接会把 LrC 启动起来，
/// 链接本身会丢，但插件启动后会扫到任务文件，所以任务文件才是主通道。
@MainActor
enum LightroomBridge {
    static let bundleID = "com.adobe.LightroomClassicCC7"

    static var base: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MiniDiT/Lightroom", directoryHint: .isDirectory)
    }
    static var jobsFolder: URL { base.appending(path: "jobs", directoryHint: .isDirectory) }
    static var resultsFolder: URL { base.appending(path: "results", directoryHint: .isDirectory) }
    static var heartbeatFile: URL { base.appending(path: "heartbeat") }

    static var modulesFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Adobe/Lightroom/Modules", directoryHint: .isDirectory)
    }
    static var pluginFolder: URL { modulesFolder.appending(path: LightroomPlugin.folderName, directoryHint: .isDirectory) }

    static var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
    static var isInstalled: Bool { appURL != nil }
    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty }

    /// 已经装好的插件版本（没装是 nil）。
    static var installedPluginVersion: String? {
        (try? String(contentsOf: pluginFolder.appending(path: "version.txt"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 状态

    struct Heartbeat {
        var lrcVersion: String
        var pluginVersion: String
        var catalog: String
        var date: Date
        /// 插件最近几秒还在写心跳。
        var isFresh: Bool { Date().timeIntervalSince(date) < 6 }
        var catalogName: String { (catalog as NSString).lastPathComponent.replacingOccurrences(of: ".lrcat", with: "") }
    }

    static func heartbeat() -> Heartbeat? {
        guard let text = try? String(contentsOf: heartbeatFile, encoding: .utf8),
              let date = (try? heartbeatFile.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        else { return nil }
        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            if parts.count == 2 { fields[parts[0]] = parts[1] }
        }
        return Heartbeat(lrcVersion: fields["lrc"] ?? "", pluginVersion: fields["plugin"] ?? "", catalog: fields["catalog"] ?? "", date: date)
    }

    enum Status: Equatable {
        /// 没装 Lightroom Classic。
        case appMissing
        /// 没装插件，或者装的是旧版本。
        case pluginMissing
        case pluginOutdated(String)
        /// LrC 开着、插件还没开始跑：LrC 15 不在启动时运行插件，第一次用到（收到链接）才初始化，已经发了链接叫醒它。
        case starting
        /// 叫过了还是没反应：插件是在 LrC 开着时装的（要重启 LrC），或者被停用了。
        case needsRestart
        /// LrC 没开：导入时会自动打开。
        case notRunning
        case ready(catalog: String)

        /// 能交任务（LrC 没开也行，打开后会处理）。
        var canImport: Bool {
            switch self {
            case .notRunning, .ready, .starting, .needsRestart: true
            default: false
            }
        }
    }

    static func status() -> Status {
        guard isInstalled else { return .appMissing }
        guard let v = installedPluginVersion else { return .pluginMissing }
        if v.compare(LightroomPlugin.version, options: .numeric) == .orderedAscending { return .pluginOutdated(v) }
        guard isRunning else { return .notRunning }
        if let h = heartbeat(), h.isFresh, h.pluginVersion == LightroomPlugin.version { lastWake = nil; return .ready(catalog: h.catalogName) }
        // 没有心跳：先叫一次；叫过 40 秒还没反应才算要重启（LrC 刚被链接启动时，加载目录要二十来秒）。
        if let t = lastWake, Date().timeIntervalSince(t) > 40 { return .needsRestart }
        if lastWake == nil { wake() }
        return .starting
    }

    private static var lastWake: Date?

    // MARK: 安装

    /// 把插件写进 LrC 的 Modules 文件夹（LrC 启动时自动加载）。返回是否需要重启 LrC。
    /// LrC 开着的时候替换插件文件夹，插件就找不到自己的脚本了，所以装好后一定要重启 LrC。
    @discardableResult
    static func installPlugin() throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: modulesFolder, withIntermediateDirectories: true)
        let tmp = modulesFolder.appending(path: ".MiniDiT-\(UUID().uuidString.prefix(8)).lrplugin", directoryHint: .isDirectory)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        for (name, text) in LightroomPlugin.files {
            try Data(text.utf8).write(to: tmp.appending(path: name), options: .atomic)
        }
        if fm.fileExists(atPath: pluginFolder.path) {
            _ = try fm.replaceItemAt(pluginFolder, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: pluginFolder)
        }
        try fm.createDirectory(at: jobsFolder, withIntermediateDirectories: true)
        try fm.createDirectory(at: resultsFolder, withIntermediateDirectories: true)
        AppLog.shared.add("已安装 Lightroom Classic 插件 \(LightroomPlugin.version)：\(pluginFolder.path)")
        lastWake = nil
        return isRunning
    }

    // MARK: 任务

    struct Photo {
        var url: URL
        /// 叠到这张 RAW 下面（RAW + JPG/HIF 成对时）。
        var stackWith: URL?
        /// 按创意外观要设的 Look 配置文件（XMP 文件的位置）。
        var look: String?
    }

    private static var counter = 0

    /// 交一个任务，返回任务名（回执同名）。
    @discardableResult
    static func enqueue(collection: String?, set: String? = "MiniDiT", select: Bool, photos: [Photo]) throws -> String {
        let fm = FileManager.default
        try fm.createDirectory(at: jobsFolder, withIntermediateDirectories: true)
        counter += 1
        let name = String(format: "%013lld-%05d", Int64(Date().timeIntervalSince1970 * 1000), Int32(counter))
        var lines = ["minidit-job\t1"]
        if let set, !set.isEmpty { lines.append("set\t" + clean(set)) }
        if let collection, !collection.isEmpty { lines.append("collection\t" + clean(collection)) }
        if select { lines.append("select\t1") }
        for p in photos {
            // 第 5 栏：相机里打的星级（从下载好的文件开头读；没打星不写）。
            let rating = PhotoRating.read(fileAt: p.url).flatMap { $0 != 0 ? String($0) : nil } ?? ""
            lines.append("photo\t" + p.url.path + "\t" + (p.stackWith?.path ?? "") + "\t" + (p.look.map(clean) ?? "") + "\t" + rating)
        }
        // 先写成 .tmp 再改名，插件只认 .job，不会读到写了一半的文件。
        let tmp = jobsFolder.appending(path: name + ".tmp")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: tmp, options: .atomic)
        try fm.moveItem(at: tmp, to: jobsFolder.appending(path: name + ".job"))
        return name
    }

    private static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    /// 让插件马上处理；LrC 没开时会把它打开（打开当前的目录）。不把 LrC 拉到前台。
    static func wake() {
        guard let url = URL(string: "lightroom://\(LightroomPlugin.toolkitID)/wake") else { return }
        lastWake = Date()
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        if let app = appURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    /// 还没处理的任务数。
    static var pendingJobs: Int {
        ((try? FileManager.default.contentsOfDirectory(atPath: jobsFolder.path)) ?? []).filter { $0.hasSuffix(".job") }.count
    }

    struct Results {
        var added = 0, skipped = 0, failed = 0, pending = 0
        var failures: [String] = []
        /// 这次读到回执的任务。
        var done: [String] = []
    }

    /// 这些任务的回执汇总；读过的回执删掉。
    static func collect(_ names: [String]) -> Results {
        var r = Results()
        let fm = FileManager.default
        for name in names {
            let result = resultsFolder.appending(path: name + ".result")
            let failed = resultsFolder.appending(path: name + ".failed")
            if let text = try? String(contentsOf: result, encoding: .utf8) {
                for line in text.split(separator: "\n") {
                    let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                    switch f.first {
                    case "ok": r.added += 1
                    case "skip": r.skipped += 1
                    case "fail":
                        r.failed += 1
                        r.failures.append(((f.count > 1 ? f[1] : "") as NSString).lastPathComponent + (f.count > 2 ? "：" + f[2] : ""))
                    default: break
                    }
                }
                try? fm.removeItem(at: result)
                r.done.append(name)
            } else if fm.fileExists(atPath: failed.path) {
                r.failed += 1
                r.failures.append("任务 \(name) 无法处理")
                try? fm.removeItem(at: failed)
                r.done.append(name)
            } else {
                r.pending += 1
            }
        }
        return r
    }
}
