import Foundation
import Testing
@testable import SonyRemoteKit

@Suite struct LocalCardTests {
    @Test func listsPhotosAndVideosAndCopies() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "card-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let dcim = root.appending(path: "DCIM/100MSDCF", directoryHint: .isDirectory)
        let clip = root.appending(path: "PRIVATE/M4ROOT/CLIP", directoryHint: .isDirectory)
        try fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        try fm.createDirectory(at: clip, withIntermediateDirectories: true)
        #expect(!LocalCardLibrary.looksLikeCard(fm.temporaryDirectory.appending(path: "nope-\(UUID().uuidString)")))
        #expect(LocalCardLibrary.looksLikeCard(root))

        let old = Date(timeIntervalSince1970: 1_700_000_000), new = Date(timeIntervalSince1970: 1_762_000_000)
        func put(_ url: URL, _ size: Int, _ date: Date) throws {
            try Data(repeating: 1, count: size).write(to: url)
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        try put(dcim.appending(path: "DSC00001.ARW"), 300, old)
        try put(dcim.appending(path: "DSC00001.JPG"), 200, old)
        try put(dcim.appending(path: "notes.txt"), 5, new)
        try put(clip.appending(path: "C0001.MP4"), 9_000_000, new)
        try Data(#"<?xml version="1.0"?><NonRealTimeMeta><CreationDate value="2026-10-17T16:58:49+01:00"/></NonRealTimeMeta>"#.utf8)
            .write(to: clip.appending(path: "C0001M01.XML"))

        let lib = LocalCardLibrary(root: root)
        let folder = try #require(try await lib.folders().first)
        let hs = try await lib.handles(in: folder)
        #expect(hs.count == 3)
        let items = try await hs.asyncMap { try await lib.item($0) }
        #expect(items.map(\.filename) == ["C0001.MP4", "DSC00001.ARW", "DSC00001.JPG"])   // 新的在前
        #expect(items.map(\.kind) == [.video, .raw, .jpeg])
        // 视频的时间来自 XML（相机的钟），不是文件修改时间。
        #expect(items[0].captureDateRaw == "20261017T165849")
        #expect(items[1].captureDateRaw.count == 15)

        let out = root.appending(path: "copy.mp4")
        try await lib.download(items[0], to: out) { _, _ in }
        #expect(try Data(contentsOf: out).count == 9_000_000)
    }
}

extension Array {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await f(e)) }
        return out
    }
}
