import Foundation
import SonyRemoteKit

/// 视频的卷号（「A001」）：每导入一次、每台相机（按机型分）一卷，字母按机型第一次出现的顺序给（A、B、C…），
/// 数字按字母各自递增。卷号跟着片段记住（键是「文件名|大小」，读卡器和 Wi-Fi 认得出是同一个片段）：
/// 中断后续传、只导代理后再导原片，都还是原来那一卷，文件夹名里用了 {卷号} 也不会变。
@MainActor
final class RollStore {
    static let shared = RollStore()

    private struct State: Codable {
        var letters: [String: String] = [:]   // 机型 → 字母
        var counters: [String: Int] = [:]     // 字母 → 用到第几卷
        var clips: [String: String] = [:]     // 片段 → 卷号
    }

    private let url: URL
    private var state: State

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: LegacyMigration.supportFolder, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appending(path: "rolls.json")
        state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: url))) ?? State()
    }

    private static func key(_ item: CameraContentItem) -> String { "\(item.filename.uppercased())|\(item.size)" }

    func roll(of item: CameraContentItem) -> String? { state.clips[Self.key(item)] }

    /// 给这次导入里还没有卷号的片段分卷：同一机型一卷。返回每个片段（按 id）的卷号，包括之前就有的。
    func assign(_ items: [(item: CameraContentItem, model: String)]) -> [UInt32: String] {
        var out: [UInt32: String] = [:]
        var fresh: [String: String] = [:]   // 机型 → 这次新开的卷
        for (item, model) in items {
            if let r = state.clips[Self.key(item)] { out[item.id] = r; continue }
            let roll = fresh[model] ?? {
                let letter = state.letters[model] ?? {
                    let used = Set(state.letters.values)
                    let l = (65...90).map { String(UnicodeScalar($0)!) }.first { !used.contains($0) } ?? "Z"
                    state.letters[model] = l
                    return l
                }()
                let n = (state.counters[letter] ?? 0) + 1
                state.counters[letter] = n
                let r = letter + String(format: "%03d", n)
                fresh[model] = r
                return r
            }()
            state.clips[Self.key(item)] = roll
            out[item.id] = roll
        }
        if !fresh.isEmpty, let data = try? JSONEncoder().encode(state) { try? data.write(to: url, options: .atomic) }
        return out
    }
}
