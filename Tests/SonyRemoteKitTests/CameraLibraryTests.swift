import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct CameraLibraryTests {
    func makeLibrary() async throws -> (PTPCameraLibrary, FakeCamera, FakeCard) {
        let card = FakeCard.sample(photo: { Data(($0 + "-full").utf8) + Data(repeating: 7, count: 5_000_000) },
                                   thumb: { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(($0 + "-thumb").utf8) })
        let state = FakeSonyState()
        state.card = card
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        try await client.openSession()
        return (PTPCameraLibrary(client: client, onClose: { await client.disconnect() }), fake, card)
    }

    @Test func foldersNewestFirstThenVideo() async throws {
        let (lib, fake, _) = try await makeLibrary()
        defer { fake.stop() }
        let folders = try await lib.folders()
        #expect(folders.map(\.name) == ["101MSDCF", "100MSDCF", "视频"])
        #expect(folders.last?.isVideo == true)
        await lib.close()
    }

    @Test func itemsAndKinds() async throws {
        let (lib, fake, _) = try await makeLibrary()
        defer { fake.stop() }
        let folders = try await lib.folders()
        let handles = try await lib.handles(in: folders[0])
        // 101MSDCF：6 张 JPG + 2 张 ARW，新的在前。
        #expect(handles.count == 8)
        let first = try await lib.item(handles[0])
        #expect(first.filename == "DSC00012.JPG")
        #expect(first.kind == .jpeg)
        #expect(first.captureDate != nil)
        #expect(first.width == 7008)

        var kinds: [CameraContentItem.Kind] = []
        for h in handles { kinds.append(try await lib.item(h).kind) }
        #expect(kinds.filter { $0 == .raw }.count == 2)

        let video = try await lib.item(try await lib.handles(in: folders[2])[0])
        #expect(video.kind == .video)
        #expect(video.filename == "C0001.MP4")
        await lib.close()
    }

    @Test func thumbnailAndChunkedDownload() async throws {
        let (lib, fake, card) = try await makeLibrary()
        defer { fake.stop() }
        let folder = try await lib.folders()[1]
        let h = try await lib.handles(in: folder).last!
        let item = try await lib.item(h)
        #expect(item.filename == "DSC00001.ARW")
        #expect(try await lib.thumbnail(h) == Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data("DSC00001-thumb".utf8))

        let jpgHandle = try await lib.handles(in: folder).dropLast().last!
        let jpg = try await lib.item(jpgHandle)
        #expect(jpg.filename == "DSC00001.JPG")
        let url = FileManager.default.temporaryDirectory.appending(path: "dl-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        let progress = ProgressLog()
        try await lib.download(jpg, to: url) { done, total in progress.add(done, total) }
        let data = try Data(contentsOf: url)
        #expect(data.count == jpg.size)
        #expect(data.prefix(13) == Data("DSC00001-full".utf8))
        // 5MB 按 3MiB 分块 = 2 次 GetPartialObject，进度单调递增并以 100% 结束。
        #expect(card.partialReads == 2)
        let steps = progress.steps
        #expect(steps.count == 2)
        #expect(steps.last?.0 == jpg.size)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0.0 < $1.0 })
        await lib.close()
    }

    @Test func fallsBackToFlatListing() async throws {
        let (lib, fake, card) = try await makeLibrary()
        defer { fake.stop() }
        card.rejectHierarchicalListing = true
        let folders = try await lib.folders()
        #expect(folders.map(\.name) == ["全部文件"])
        #expect(folders.first?.isFlat == true)
        let handles = try await lib.handles(in: folders[0])
        var kinds: [CameraContentItem.Kind] = []
        for h in handles { kinds.append(try await lib.item(h).kind) }
        // 平铺会把文件夹也列出来（界面上当非媒体文件隐藏），照片、RAW、视频都在。
        #expect(kinds.filter { $0 == .jpeg }.count == 12)
        #expect(kinds.filter { $0 == .raw }.count == 4)
        #expect(kinds.filter { $0 == .video }.count == 1)
        #expect(await lib.listingNotes.contains { $0.contains("按文件夹读取失败") })
        await lib.close()
    }

    @Test func kindsFromFormatListing() async throws {
        let (lib, fake, card) = try await makeLibrary()
        defer { fake.stop() }
        card.rejectHierarchicalListing = true
        let flat = try await lib.folders()[0]
        let kinds = try #require(await lib.kinds(in: flat))
        #expect(kinds.values.filter { $0 == .jpeg }.count == 12)
        #expect(kinds.values.filter { $0 == .raw }.count == 4)
        #expect(kinds.values.filter { $0 == .video }.count == 1)
        // 和逐个读文件信息的结果一致。
        for (h, k) in kinds { #expect(try await lib.item(h).kind == k) }

        card.ignoreFormatFilter = true
        #expect(await lib.kinds(in: flat) == nil)
        await lib.close()
    }

    @Test func thumbnailFallsBackToEmbeddedPreview() async throws {
        // 小预览图：一个完整的 JPEG（> 1000 字节）。
        let preview = Data([0xFF, 0xD8, 0xFF, 0xDB]) + Data(repeating: 0x11, count: 2000) + Data([0xFF, 0xD9])
        // 主文件：SOI + APP1（里面嵌着预览图）+ 大量图像数据。
        let photo = Data([0xFF, 0xD8, 0xFF, 0xE1, 0x10, 0x00]) + Data("Exif\0\0".utf8) + Data(repeating: 0, count: 100)
            + preview + Data(repeating: 0x22, count: 500_000) + Data([0xFF, 0xD9])
        let card = FakeCard()
        let f = card.folder("100MSDCF", parent: card.folder("DCIM", parent: 0))
        let h = card.add(PTPObjectInfo(format: PTPObjectFormat.jpeg, size: 0, parent: f, filename: "DSC00001.JPG"), data: photo)  // 没有 GetThumb 缩略图
        let state = FakeSonyState()
        state.card = card
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        try await client.openSession()
        for large in [false, true] {
            let lib = PTPCameraLibrary(client: client, largeObjectReads: large)
            #expect(try await lib.thumbnail(h) == preview, "largeObjectReads=\(large)")
            #expect(await lib.listingNotes.contains { $0.contains("GetThumb 失败") })
        }
        await client.disconnect()
    }

    @Test func thumbnailFormatDetection() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 1, count: 20) + Data([0xFF, 0xD9])
        #expect(PTPCameraLibrary.decodableImage(jpeg) == jpeg)
        // HEIF：第 4~7 字节是 "ftyp"。
        let heif = Data([0, 0, 0, 0x18]) + Data("ftypheic".utf8) + Data(repeating: 2, count: 40)
        #expect(PTPCameraLibrary.decodableImage(heif) == heif)
        #expect(PTPCameraLibrary.imageKind(heif).hasPrefix("HEIF"))
        // 前面带了 32 字节自定义头的 JPEG。
        let wrapped = Data(repeating: 0x07, count: 32) + jpeg
        #expect(PTPCameraLibrary.decodableImage(wrapped) == jpeg)
        #expect(PTPCameraLibrary.decodableImage(Data(repeating: 0x07, count: 64)) == nil)
    }

    @Test func ptpDateParsing() {
        let d = PTPObjectInfo.parseDate("20261104T153012Z")
        #expect(d == ISO8601DateFormatter().date(from: "2026-11-04T15:30:12Z"))
        let tz = PTPObjectInfo.parseDate("20261104T153012.0+0800")
        #expect(tz == ISO8601DateFormatter().date(from: "2026-11-04T07:30:12Z"))
        #expect(PTPObjectInfo.parseDate("") == nil)
        #expect(PTPObjectInfo.parseDate("20261104T153012") != nil)
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(UInt64, UInt64)] = []
    func add(_ a: UInt64, _ b: UInt64) { lock.withLock { items.append((a, b)) } }
    var steps: [(UInt64, UInt64)] { lock.withLock { items } }
}
