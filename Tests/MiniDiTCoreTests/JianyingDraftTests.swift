import Foundation
import Testing
@testable import MiniDiTCore

@Suite struct JianyingDraftTests {
    private func tempRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "jianying-" + UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    @Test func newDraftListsClipsInMediaPanelWithEmptyTimeline() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let handoff = JianyingDraft.Handoff(name: "11.6-临时", clips: [
            .init(path: "/Volumes/Work/11.6/C0001.MP4", duration: 3.5, width: 3840, height: 2160, fps: 25),
            .init(path: "/Volumes/Work/11.6/C0002.MP4", duration: 12, width: 1920, height: 1080),
        ])
        let id = UUID()
        let (folder, outcome) = try JianyingDraft.deliver(handoff, id: id, in: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(outcome == .created)
        #expect(folder.lastPathComponent == "11.6-临时")
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["11.6-临时"], "不留下临时文件夹")

        let meta = try json(folder.appending(path: "draft_meta_info.json"))
        #expect(meta["draft_id"] as? String == id.uuidString)
        #expect(meta["draft_name"] as? String == "11.6-临时")
        #expect(meta["draft_fold_path"] as? String == folder.path)
        #expect(meta["draft_root_path"] as? String == root.path)
        let groups = try #require(meta["draft_materials"] as? [[String: Any]])
        #expect(groups.map { $0["type"] as? Int } == [0, 1, 2, 3, 6, 7, 8])
        let videos = try #require(groups.first?["value"] as? [[String: Any]])
        #expect(videos.map { $0["file_Path"] as? String } == handoff.clips.map(\.path))
        #expect(videos.map { $0["duration"] as? Int } == [3_500_000, 12_000_000])
        #expect(videos.map { $0["extra_info"] as? String } == ["C0001.MP4", "C0002.MP4"])
        #expect(videos.allSatisfy { $0["metetype"] as? String == "video" && $0["type"] as? Int == 0 })
        #expect(groups.dropFirst().allSatisfy { ($0["value"] as? [Any])?.isEmpty == true })

        let info = try json(folder.appending(path: "draft_info.json"))
        let canvas = try #require(info["canvas_config"] as? [String: Any])
        #expect(canvas["width"] as? Int == 3840 && canvas["height"] as? Int == 2160)
        #expect(info["fps"] as? Double == 25)
        #expect((info["tracks"] as? [Any])?.isEmpty == true, "时间线留空")
        let materials = try #require(info["materials"] as? [String: Any])
        #expect(materials.count == 45 && (materials["videos"] as? [Any])?.isEmpty == true)
    }

    @Test func sameNamedDraftGetsNewClipsUntilJianyingOpensIt() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let a = JianyingDraft.Clip(path: "/tmp/A.MP4", duration: 1, width: 0, height: 0)
        let b = JianyingDraft.Clip(path: "/tmp/B.MP4", duration: 2, width: 1920, height: 1080)
        let (folder, first) = try JianyingDraft.deliver(.init(name: "婚礼", clips: [a]), id: UUID(), in: root)
        #expect(first == .created)
        let info = try json(folder.appending(path: "draft_info.json"))
        let canvas = try #require(info["canvas_config"] as? [String: Any])
        #expect(canvas["width"] as? Int == 1920 && info["fps"] as? Double == 30, "读不到尺寸时用默认画布")

        // 剪映列出草稿时会给 draft_meta_info 补字段，但仍是明文：第二张卡加进同一个草稿，已有的片段不重复。
        var meta = try json(folder.appending(path: "draft_meta_info.json"))
        meta["cloud_draft_sync"] = false
        try JSONSerialization.data(withJSONObject: meta).write(to: folder.appending(path: "draft_meta_info.json"))
        let (again, second) = try JianyingDraft.deliver(.init(name: "婚礼", clips: [a, b]), id: UUID(), in: root)
        #expect(again == folder && second == .added(new: 1, existing: 1))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["婚礼"], "不新建第二个草稿")
        meta = try json(folder.appending(path: "draft_meta_info.json"))
        #expect(meta["cloud_draft_sync"] as? Bool == false, "保留剪映写入的字段")
        let groups = try #require(meta["draft_materials"] as? [[String: Any]])
        let videos = try #require(groups.first { $0["type"] as? Int == 0 }?["value"] as? [[String: Any]])
        #expect(videos.map { $0["file_Path"] as? String } == ["/tmp/A.MP4", "/tmp/B.MP4"])
        #expect(try JianyingDraft.deliver(.init(name: "婚礼", clips: [a, b]), id: UUID(), in: root).outcome == .added(new: 0, existing: 2))

        // 剪映打开后草稿文件是密文：不改写，也不新建同名草稿。
        let encrypted = Data("e3Faw+1DB8BZCHrxiQtO".utf8)
        try encrypted.write(to: folder.appending(path: "draft_meta_info.json"))
        #expect(try JianyingDraft.deliver(.init(name: "婚礼", clips: [b]), id: UUID(), in: root).outcome == .locked)
        #expect(try Data(contentsOf: folder.appending(path: "draft_meta_info.json")) == encrypted)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["婚礼"])

        #expect(try JianyingDraft.deliver(.init(name: "../.隐藏/项目", clips: [a]), id: UUID(), in: root).folder.lastPathComponent == "-.隐藏-项目")
        #expect(try JianyingDraft.deliver(.init(name: " ", clips: [a]), id: UUID(), in: root).folder.lastPathComponent == "MiniDiT")
    }

    @Test func failuresLeaveNothingBehind() throws {
        let root = try tempRoot(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: JianyingDraft.Failure.self) {
            try JianyingDraft.deliver(.init(name: "空", clips: []), id: UUID(), in: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        #expect(throws: JianyingDraft.Failure.self) {
            try JianyingDraft.deliver(.init(name: "无目录", clips: [.init(path: "/tmp/A.MP4", duration: 1, width: 1, height: 1)]),
                                     id: UUID(), in: root.appending(path: "missing"))
        }
    }
}
