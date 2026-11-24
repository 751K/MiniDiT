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
        let actualSourcePath = try #require(await lib.sourcePath(items[0].id))
        #expect(URL(filePath: actualSourcePath).resolvingSymlinksInPath() == clip.appending(path: "C0001.MP4").resolvingSymlinksInPath())
        // 视频的时间来自 XML（相机的钟），不是文件修改时间。
        #expect(items[0].captureDateRaw == "20261017T165849")
        #expect(items[1].captureDateRaw.count == 15)

        let out = root.appending(path: "copy.mp4")
        try await lib.download(items[0], to: out) { _, _ in }
        #expect(try Data(contentsOf: out).count == 9_000_000)
    }

    /// CFexpress 卡上 M4ROOT 在卡的根目录（不在 PRIVATE/ 里）：视频、XML 和代理都要认出来。
    @Test func findsVideosWhenM4RootIsAtTheCardRoot() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "cfexpress-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: root) }
        let clip = root.appending(path: "M4ROOT/CLIP", directoryHint: .isDirectory)
        let sub = root.appending(path: "M4ROOT/SUB", directoryHint: .isDirectory)
        try fm.createDirectory(at: clip, withIntermediateDirectories: true)
        try fm.createDirectory(at: sub, withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appending(path: "PRIVATE/DATABASE"), withIntermediateDirectories: true)
        #expect(LocalCardLibrary.looksLikeCard(root))

        try Data(repeating: 1, count: 4096).write(to: clip.appending(path: "C2536.MP4"))
        try Data(#"<?xml version="1.0"?><NonRealTimeMeta><CreationDate value="2026-10-17T16:58:49+01:00"/></NonRealTimeMeta>"#.utf8)
            .write(to: clip.appending(path: "C2536M01.XML"))
        try Data(repeating: 2, count: 1024).write(to: sub.appending(path: "C2536S03.MP4"))

        let lib = LocalCardLibrary(root: root)
        let folder = try #require(try await lib.folders().first)
        let items = try await lib.handles(in: folder).asyncMap { try await lib.item($0) }
        #expect(items.map(\.filename) == ["C2536.MP4"])
        #expect(items.first?.kind == .video)
        #expect(items.first?.captureDateRaw == "20261017T165849")
        let sidecars = await lib.sidecars(try #require(items.first).id)
        #expect(sidecars.map(\.url.lastPathComponent).sorted() == ["C2536M01.XML", "C2536S03.MP4"])
    }

    @Test func refreshKeepsExistingHandlesWhenNewerMediaArrives() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "refresh-card-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let dcim = root.appending(path: "DCIM/100MSDCF")
        try FileManager.default.createDirectory(at: dcim, withIntermediateDirectories: true)
        let original = dcim.appending(path: "DSC00001.JPG")
        try Data(repeating: 1, count: 100).write(to: original)
        let lib = LocalCardLibrary(root: root)
        let folder = try #require(try await lib.folders().first)
        let first = try #require(try await lib.handles(in: folder).first)
        let newer = dcim.appending(path: "DSC00002.JPG")
        try Data(repeating: 2, count: 200).write(to: newer)
        await lib.refresh()
        let handles = try await lib.handles(in: folder)
        #expect(handles.count == 2)
        #expect(try await lib.item(first).filename == "DSC00001.JPG")
        #expect(await lib.fileURL(first)?.resolvingSymlinksInPath() == original.resolvingSymlinksInPath())
        // 大小改变的同名文件不能沿用旧句柄。
        try Data(repeating: 3, count: 300).write(to: original)
        await lib.refresh()
        let changed = try await lib.handles(in: folder)
        #expect(!changed.contains(first))
    }
}

extension Array {
    func asyncMap<T>(_ f: (Element) async throws -> T) async rethrows -> [T] {
        var out: [T] = []
        for e in self { out.append(try await f(e)) }
        return out
    }
}
