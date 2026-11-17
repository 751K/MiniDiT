import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

/// A small UXP receiver owns all Premiere API calls. Local files carry only typed import requests.
@MainActor enum PremiereBridge {
    struct Project: Codable, Sendable, Equatable { var id: String; var name: String; var path: String }
    struct Result: Codable, Sendable {
        var project: String, projectID: String
        /// 这次是否新建了项目；旧插件不返回。
        var created: Bool? = nil
        var imported: Int, skipped: Int, proxies: Int
        var receivedPaths: [String], failedPaths: [String], warnings: [String]
    }
    struct Heartbeat: Codable, Sendable {
        var protocolVersion: Int, pluginVersion: String, updatedAt: Double, busy: Bool, project: Project?
        var isFresh: Bool { Date().timeIntervalSince1970 - updatedAt < 8 && updatedAt <= Date().timeIntervalSince1970 + 5 }
    }
    static var base: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MiniDiT/Premiere") }
    static var app: AppInfo { AppInfo.find(.premiere) }
    static var isSupported: Bool { app.version.map { $0.compare("25.6", options: .numeric) != .orderedAscending } ?? false }
    static func heartbeat() -> Heartbeat? { try? JSONDecoder().decode(Heartbeat.self, from: Data(contentsOf: base.appending(path: "heartbeat.json"))) }

    nonisolated static func payload(events: [FCPXMLWriter.Event], batch: ImportBatchRecord, projectNames: [UUID: String], target: PremiereHandoff.Target? = nil) throws -> Data {
        let ownership = Dictionary(batch.files.flatMap { file in
            file.assets.flatMap { asset in asset.copies.filter { $0.role == .working }.map { ($0.path, file) } }
        }, uniquingKeysWith: { a, _ in a })
        var groups: [PremiereHandoff.Group] = []
        for event in events {
            for clip in event.clips {
                guard let file = ownership[clip.url.path], let id = file.projectID, let name = projectNames[id] else {
                    throw VideoDelivery.Failure(String(localized: "无法确定视频所属项目，未向 Premiere Pro 发送。"))
                }
                let bins = [name] + (file.roll.map { [$0] } ?? [])
                let info = ClipInfo.sidecar(for: clip.url).flatMap(ClipInfo.read)
                let rate = info.flatMap { VideoFrameRate($0.formatFps) }
                let marks: [PremiereHandoff.Mark] = rate.map { rate in
                    (info?.shotMarks ?? []).map { .init(name: "Shot Mark \($0.shotMark ?? 1)", seconds: Double($0.frame) * Double(rate.denominator) / Double(rate.numerator), duration: Double(rate.denominator) / Double(rate.numerator)) }
                } ?? []
                let media = PremiereHandoff.Clip(url: clip.url, proxy: clip.proxy, marks: marks)
                if let index = groups.firstIndex(where: { $0.binPath == bins }) { groups[index].clips.append(media) }
                else { groups.append(.init(binPath: bins, clips: [media])) }
            }
        }
        return try JSONEncoder().encode(PremiereHandoff(project: target, groups: groups))
    }

    /// 插件按交接内容里的目标项目打开或新建 .prproj 再导入。`expected` 是第一次发送时绑定的项目，重试时必须还是它。
    static func send(_ payload: Data, expected: Project?) async throws -> Result {
        try await connect()
        let handoff = try JSONDecoder().decode(PremiereHandoff.self, from: payload)
        return try await exchange(action: "import", projectID: expected?.id, handoff: handoff, base: base)
    }
    private static func connect() async throws {
        let application = app
        guard let url = application.url else { throw VideoDelivery.Failure(String(localized: "未找到 Adobe Premiere Pro，请安装后重试。")) }
        guard isSupported else { throw VideoDelivery.Failure(String(localized: "MiniDiT 插件需要 Premiere Pro 25.6 或更新版本。")) }
        if !application.isRunning {
            let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
        // Opening the panel is a one-time host action, not evidence of a successful import.
        for _ in 0..<(application.isRunning ? 1 : 20) {
            try Task.checkCancellation()
            if let h = heartbeat(), h.isFresh {
                guard h.protocolVersion == 1, h.pluginVersion == PremierePlugin.version else { throw VideoDelivery.Failure(String(localized: "请在“设置 › 连接”中更新 Premiere Pro 的 MiniDiT 插件。")) }
                return
            }
            if !application.isRunning { try await Task.sleep(for: .seconds(1)) }
        }
        throw VideoDelivery.Failure(String(localized: "请安装 MiniDiT 插件，并在 Premiere Pro 的“窗口 › UXP 插件”中打开 MiniDiT 面板。"))
    }

    private struct Request: Codable, Sendable {
        var protocolVersion = 1
        var id: String, action: String
        var expiresAt: Double
        var projectID: String?
        var handoff: PremiereHandoff?
    }
    private struct Lease: Codable { var id: String; var expiresAt: Double }
    private struct Response<T: Decodable>: Decodable { var id: String; var value: T?; var error: String? }

    /// Separately testable transport. Removing this attempt's lease stops late work at the next checkpoint.
    nonisolated static func exchange<T: Decodable & Sendable>(action: String, projectID: String? = nil, handoff: PremiereHandoff? = nil, base: URL, timeout: TimeInterval = 120) async throws -> T {
        let fm = FileManager.default, id = UUID().uuidString
        let directory = base.appending(path: "requests/" + id)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: directory) }
        let encoder = JSONEncoder(), end = Date().addingTimeInterval(timeout)
        let lease = directory.appending(path: "lease.json")
        try encoder.encode(Lease(id: id, expiresAt: Date().addingTimeInterval(10).timeIntervalSince1970)).write(to: lease, options: .atomic)
        try encoder.encode(Request(id: id, action: action, expiresAt: end.timeIntervalSince1970, projectID: projectID, handoff: handoff)).write(to: directory.appending(path: "request.json"), options: .atomic)
        var renewed = Date()
        while Date() < end {
            try Task.checkCancellation()
            let resultURL = directory.appending(path: "result.json")
            if fm.fileExists(atPath: resultURL.path) {
                let reply = try JSONDecoder().decode(Response<T>.self, from: Data(contentsOf: resultURL))
                guard reply.id == id else { throw VideoDelivery.Failure(String(localized: "Premiere Pro 返回了其他任务的结果，未将其记作本批完成。")) }
                if let error = reply.error { throw VideoDelivery.Failure(error) }
                guard let value = reply.value else { throw VideoDelivery.Failure(String(localized: "Premiere Pro 未返回文件接收结果。")) }
                return value
            }
            if Date().timeIntervalSince(renewed) >= 1 {
                try encoder.encode(Lease(id: id, expiresAt: Date().addingTimeInterval(10).timeIntervalSince1970)).write(to: lease, options: .atomic)
                renewed = Date()
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        throw VideoDelivery.Failure(String(localized: "等待 Premiere Pro 接收超时，请检查 MiniDiT 面板后重试。"))
    }
}

@MainActor enum PremierePlugin {
    static let version = "1.1.0"
    static var resource: URL? { Bundle.main.url(forResource: "PremierePlugin", withExtension: "bundle") }
    static func makePackage(source: URL? = nil, output: URL? = nil) async throws -> URL {
        guard let source = source ?? resource else { throw VideoDelivery.Failure(String(localized: "未找到 Premiere Pro 插件文件，请重新安装 MiniDiT。")) }
        let target = output ?? PremiereBridge.base.appending(path: "MiniDiT-Premiere-\(version).ccx")
        return try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temporary = target.deletingLastPathComponent().appending(path: UUID().uuidString + ".ccx")
            defer { try? fm.removeItem(at: temporary) }
            let process = Process(); process.executableURL = URL(filePath: "/usr/bin/zip")
            process.currentDirectoryURL = source
            process.arguments = ["-q", temporary.path, "manifest.json", "index.html", "index.js", "receiver.js", "mailbox.js"]
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw VideoDelivery.Failure(String(localized: "无法生成 Premiere Pro 插件安装文件。")) }
            if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: temporary) }
            else { try fm.moveItem(at: temporary, to: target) }
            return target
        }.value
    }
}
