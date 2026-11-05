import Foundation
import Observation

/// 简单日志，界面里能复制出来排查问题（不记录密码）。
/// 同时写到 ~/Library/Logs/MiniDiT/MiniDiT.log，App 退出后也能看。
@MainActor @Observable
final class AppLog {
    static let shared = AppLog()
    private(set) var lines: [String] = []
    private let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    private let file: FileHandle? = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/MiniDiT", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "MiniDiT.log")
        // 超过 2 MB 就重新开始。
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let h = try? FileHandle(forWritingTo: url)
        _ = try? h?.seekToEnd()
        return h
    }()

    func add(_ s: String) {
        let line = "\(fmt.string(from: Date()))  \(s)"
        lines.append(line)
        if lines.count > 500 { lines.removeFirst(lines.count - 500) }
        try? file?.write(contentsOf: Data((line + "\n").utf8))
    }

    var text: String { lines.joined(separator: "\n") }
}
