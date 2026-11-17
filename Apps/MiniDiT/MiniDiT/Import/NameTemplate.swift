import Foundation

/// 会话名、下载文件夹、备份文件夹、视频文件夹的命名模板。
///
/// 可用的标记：`{YYYY}` 年、`{MM}` `{DD}` 两位的月日、`{M}` `{D}` 不补零的月日、`{事件}`、`{场次}`，视频还有 `{卷号}`。
/// `{事件}` `{场次}` `{卷号}` 另有英文写法 `{Event}` `{Scene}` `{Roll}`，两种写法都可用；内部统一按中文标记展开。
/// 没填的标记留空，多出来的连接符（`-` `_` `.` 空格）会去掉：「{M}.{D}-{事件}」没填事件就是「3.15」。
/// 下载文件夹和视频文件夹的模板可以用 `/` 分层。
enum NameTemplate {
    enum Kind: String, CaseIterable {
        case session, folder, backup, video

        var key: String { "template." + rawValue }
        /// 默认模板，标记按界面语言书写。已保存的模板不受影响。
        var defaultValue: String {
            switch self {
            case .session: NameTemplate.localized("{M}.{D}-{事件}")
            case .folder: "{YYYY}/{YYYY}-{MM}-{DD}"
            case .backup: NameTemplate.localized("{YYYY}-{MM}-{DD}-{事件}")
            case .video: NameTemplate.localized("{M}.{D}-{事件}")
            }
        }
        var allowsFolders: Bool { self == .folder || self == .video }
    }

    /// 带文字的标记。中文写法是内部标准写法，英文写法为别名。
    enum Token: CaseIterable {
        case event, scene, roll

        var chinese: String {
            switch self {
            case .event: "{事件}"
            case .scene: "{场次}"
            case .roll: "{卷号}"
            }
        }
        var english: String {
            switch self {
            case .event: "{Event}"
            case .scene: "{Scene}"
            case .roll: "{Roll}"
            }
        }
        /// 界面语言的写法，用于显示和新的默认模板。
        var localized: String {
            switch self {
            case .event: String(localized: "{事件}")
            case .scene: String(localized: "{场次}")
            case .roll: String(localized: "{卷号}")
            }
        }
    }

    static var tokens: [String] { ["{YYYY}", "{MM}", "{DD}", "{M}", "{D}"] + Token.allCases.map(\.localized) }

    /// 把模板中的英文标记（不区分大小写）换成中文标记。
    static func canonical(_ template: String) -> String {
        var s = template
        for t in Token.allCases {
            s = s.replacingOccurrences(of: t.english, with: t.chinese, options: .caseInsensitive)
        }
        return s
    }

    /// 把模板中的标记换成界面语言的写法。
    static func localized(_ template: String) -> String {
        var s = canonical(template)
        for t in Token.allCases where t.localized != t.chinese {
            s = s.replacingOccurrences(of: t.chinese, with: t.localized)
        }
        return s
    }

    /// 模板是否用到某个标记（中英文写法均可）。
    static func uses(_ token: Token, in template: String) -> Bool {
        canonical(template).contains(token.chinese)
    }

    /// 两个模板是否相同（忽略首尾空格与标记的语言）。
    static func same(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return canonical(a.trimmingCharacters(in: .whitespaces)) == canonical(b.trimmingCharacters(in: .whitespaces))
    }

    static func current(_ kind: Kind) -> String {
        let s = UserDefaults.standard.string(forKey: kind.key)?.trimmingCharacters(in: .whitespaces) ?? ""
        return s.isEmpty ? kind.defaultValue : s
    }

    /// 按模板生成名字。`day` 是「yyyyMMdd」（没有日期是 "unknown"）；`scene` 是这一天里的第几场。
    /// 「第 N 场」「无日期」「未命名」按界面语言生成；`legacy` 为 true 时按旧版本的中文生成，用于识别已有的文件夹和项目。
    static func render(_ kind: Kind, day: String, event: String?, scene: Int? = nil, roll: String? = nil, legacy: Bool = false) -> String {
        render(current(kind), allowsFolders: kind.allowsFolders, day: day, event: event, scene: scene, roll: roll, legacy: legacy)
    }

    static func render(_ template: String, allowsFolders: Bool, day: String, event: String?, scene: Int?, roll: String? = nil,
                       legacy: Bool = false) -> String {
        let ev = sanitize(event ?? "")
        let sceneName: (Int) -> String = { legacy ? "第\($0)场" : String(localized: "第\($0)场") }
        let noDate = legacy ? "无日期" : String(localized: "无日期")
        let untitled = legacy ? "未命名" : String(localized: "未命名")
        var values: [String: String] = ["{事件}": ev, "{场次}": scene.map(sceneName) ?? "", "{卷号}": roll ?? ""]
        if day.count == 8, let m = Int(day.dropFirst(4).prefix(2)), let d = Int(day.suffix(2)) {
            values["{YYYY}"] = String(day.prefix(4))
            values["{MM}"] = String(format: "%02d", m)
            values["{DD}"] = String(format: "%02d", d)
            values["{M}"] = "\(m)"
            values["{D}"] = "\(d)"
        } else {
            // 没有拍摄日期：不套模板，用「没有日期」，有事件名就接在后面。
            return ev.isEmpty ? noDate : noDate + "-" + ev
        }
        var s = canonical(template)
        for (k, v) in values { s = s.replacingOccurrences(of: k, with: v) }
        if !allowsFolders { s = s.replacingOccurrences(of: "/", with: "-") }
        s = s.replacingOccurrences(of: ":", with: "-")
        let parts = s.split(separator: "/", omittingEmptySubsequences: true).map { tidy(String($0)) }.filter { !$0.isEmpty }
        return parts.isEmpty ? untitled : parts.joined(separator: "/")
    }

    /// 在 `root` 下选用的相对路径：按界面语言生成的文件夹还不存在、而旧版中文名的已存在时沿用旧名，其余情况用界面语言。
    static func existing(_ current: String, legacy: String, in root: URL) -> String {
        guard current != legacy, !legacy.isEmpty else { return current }
        let fm = FileManager.default
        if fm.fileExists(atPath: root.appending(path: current).path) { return current }
        return fm.fileExists(atPath: root.appending(path: legacy).path) ? legacy : current
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
    static func folder(_ kind: Kind, root: URL, day: String, event: String?, scene: Int? = nil, roll: String? = nil) -> URL {
        let relative = existing(render(kind, day: day, event: event, scene: scene, roll: roll),
                                legacy: render(kind, day: day, event: event, scene: scene, roll: roll, legacy: true), in: root)
        return relative.split(separator: "/").reduce(root) {
            $0.appending(path: String($1), directoryHint: .isDirectory)
        }
    }
}
