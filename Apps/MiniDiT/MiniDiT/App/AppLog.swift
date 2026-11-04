import Foundation
import Observation

/// 简单日志，界面里能复制出来排查问题（不记录密码）。
@MainActor @Observable
final class AppLog {
    static let shared = AppLog()
    private(set) var lines: [String] = []
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    func add(_ s: String) {
        lines.append("\(fmt.string(from: Date()))  \(s)")
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
    }

    var text: String { lines.joined(separator: "\n") }
}
