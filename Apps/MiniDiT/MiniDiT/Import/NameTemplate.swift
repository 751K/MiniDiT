import Foundation

/// 会话名、下载文件夹、备份文件夹的命名模板。
///
/// 可用的标记：`{YYYY}` 年、`{MM}` `{DD}` 两位的月日、`{M}` `{D}` 不补零的月日、`{事件}`、`{场次}`。
/// 没填的标记留空，多出来的连接符（`-` `_` `.` 空格）会去掉：「{M}.{D}-{事件}」没填事件就是「3.15」。
/// 只有下载文件夹的模板可以用 `/` 分层。
enum NameTemplate {
    enum Kind: String, CaseIterable {
        case session, folder, backup

        var key: String { "template." + rawValue }
        var defaultValue: String {
            switch self {
            case .session: "{M}.{D}-{事件}"
            case .folder: "{YYYY}/{YYYY}-{MM}-{DD}"
            case .backup: "{YYYY}-{MM}-{DD}-{事件}"
            }
        }
        var allowsFolders: Bool { self == .folder }
    }

    static let tokens = ["{YYYY}", "{MM}", "{DD}", "{M}", "{D}", "{事件}", "{场次}"]

    static func current(_ kind: Kind) -> String {
        let s = UserDefaults.standard.string(forKey: kind.key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? kind.defaultValue : s
    }

    /// 按模板生成名字。`day` 是「yyyyMMdd」（没有日期是 "unknown"）；`scene` 是这一天里的第几场。
    static func render(_ kind: Kind, day: String, event: String?, scene: Int? = nil) -> String {
        render(current(kind), allowsFolders: kind.allowsFolders, day: day, event: event, scene: scene)
    }

    static func render(_ template: String, allowsFolders: Bool, day: String, event: String?, scene: Int?) -> String {
        let ev = sanitize(event ?? "")
        var values: [String: String] = ["{事件}": ev, "{场次}": scene.map { "第\($0)场" } ?? ""]
        if day.count == 8, let m = Int(day.dropFirst(4).prefix(2)), let d = Int(day.suffix(2)) {
            values["{YYYY}"] = String(day.prefix(4))
            values["{MM}"] = String(format: "%02d", m)
            values["{DD}"] = String(format: "%02d", d)
            values["{M}"] = "\(m)"
            values["{D}"] = "\(d)"
        } else {
            // 没有拍摄日期：不套模板，用「没有日期」，有事件名就接在后面。
            return ev.isEmpty ? "无日期" : "无日期-" + ev
        }
        var s = template
        for (k, v) in values { s = s.replacingOccurrences(of: k, with: v) }
        if !allowsFolders { s = s.replacingOccurrences(of: "/", with: "-") }
        s = s.replacingOccurrences(of: ":", with: "-")
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map { tidy(String($0)) }.filter { !$0.isEmpty }
        return parts.isEmpty ? "未命名" : parts.joined(separator: "/")
    }

    /// 事件名里不能有路径符号。
    static func sanitize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }

    private static let separators: Set<Character> = ["-", "_", ".", " "]

    /// 去掉首尾的连接符，连在一起的连接符只留第一个（留空的标记两边的「-」会挨在一起）。
    private static func tidy(_ s: String) -> String {
        var out = ""
        for c in s {
            if separators.contains(c), let last = out.last, separators.contains(last) { continue }
            out.append(c)
        }
        while let f = out.first, separators.contains(f) { out.removeFirst() }
        while let l = out.last, separators.contains(l) { out.removeLast() }
        return out
    }

    /// 把模板应用到一个文件夹：`root/渲染结果`（下载文件夹的模板可以有多层）。
    static func folder(_ kind: Kind, root: URL, day: String, event: String?, scene: Int? = nil) -> URL {
        render(kind, day: day, event: event, scene: scene).split(separator: "/").reduce(root) {
            $0.appending(path: String($1), directoryHint: .isDirectory)
        }
    }
}
