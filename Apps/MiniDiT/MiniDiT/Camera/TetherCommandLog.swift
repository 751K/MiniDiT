import Foundation
import MiniDiTCore

/// 联机拍摄命令日志：CLI / MCP 发来的每条 tether.* 命令写一行 JSON（时间、命令、参数、耗时、结果或错误码）。
/// 位置：~/Library/Logs/MiniDiT/tether-YYYY-MM-DD.jsonl，按天分文件，只追加。
/// 取景图片的 base64 不写入（只记长度），很长的列表只留前 30 项，免得日志被轮询撑大。
@MainActor enum TetherCommandLog {
    /// 功能检查用：换到临时目录。
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/MiniDiT", directoryHint: .isDirectory)
    }

    static func currentURL(now: Date = .now) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return directory.appending(path: "tether-\(f.string(from: now)).jsonl")
    }

    static let maxItems = 30
    static let maxString = 2000

    static func entry(method: String, params: AgentJSON, response: AgentControlResponse, started: Date, finished: Date = .now) -> AgentJSON {
        let time = ISO8601DateFormatter()
        time.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var o: [String: AgentJSON] = [
            "time": .string(time.string(from: started)),
            "method": .string(method),
            "params": trim(params),
            "durationMs": .integer(Int((finished.timeIntervalSince(started) * 1000).rounded())),
            "ok": .bool(response.error == nil),
        ]
        if let e = response.error {
            o["error"] = .object(["code": .string(e.code), "message": .string(e.message)])
        } else {
            o["result"] = trim(response.result ?? .null)
        }
        return .object(o)
    }

    static func append(method: String, params: AgentJSON, response: AgentControlResponse, started: Date) {
        let line = entry(method: method, params: params, response: response, started: started)
        guard var data = try? line.data() else { return }
        data.append(10)
        let url = currentURL()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: data)
        } catch {
            AppLog.shared.add("联机命令日志写入失败：\(error.localizedDescription)")
        }
    }

    /// 图片数据换成长度说明，长字符串截断，长列表只留前几项。
    static func trim(_ v: AgentJSON, key: String? = nil) -> AgentJSON {
        switch v {
        case .string(let s):
            if key == "data" { return .string("<base64, \(s.utf8.count) chars>") }
            return s.count > maxString ? .string(String(s.prefix(maxString)) + "…") : v
        case .array(let a):
            let head = a.prefix(maxItems).map { trim($0) }
            return a.count > maxItems ? .array(head + [.string("…(\(a.count - maxItems) more)")]) : .array(head)
        case .object(let o):
            return .object(Dictionary(uniqueKeysWithValues: o.map { ($0.key, trim($0.value, key: $0.key)) }))
        default:
            return v
        }
    }
}
