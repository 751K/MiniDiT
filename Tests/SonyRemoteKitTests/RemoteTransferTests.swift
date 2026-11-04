import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct RemoteTransferTests {
    static let ops: [UInt16] = [PTPOperation.getDeviceInfo, PTPOperation.openSession, SonyOperation.sdioConnect,
                                SonyOperation.getExtDeviceInfo, SonyOperation.getCapturedDateList, SonyOperation.getContentsInfoList,
                                SonyOperation.getContentsData, SonyOperation.getContentsCompressedData]

    func start(_ state: FakeSonyState) async throws -> (FakeCamera, UInt16) {
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        return (fake, try await fake.start())
    }

    @Test func contentsListRoundTrip() throws {
        let c = SonyContent(id: 0x20001, createdUTC: 1_762_000_000_123, createdLocal: 1_762_028_800_123, files: [
            .init(id: 1, path: "A:/DCIM/100MSDCF/DSC00001.ARW", format: 0xB101, size: 25_000_000, width: 7008, height: 4672),
            .init(id: 2, path: "A:/DCIM/100MSDCF/DSC00001.JPG", format: 0x3801, size: 9_000_000),
        ])
        #expect(try SonyContent.parseList(SonyContent.encodeList([c, c])) == [c, c])
        #expect(throws: (any Error).self) { try SonyContent.parseList(Data(count: 20)) }

        let item = SonyRemoteTransferLibrary.makeItem(handle: 7, slot: 2, content: c, file: c.files[0])
        #expect(item.filename == "DSC00001.ARW")
        #expect(item.kind == .raw)
        #expect(item.storageID >> 16 == 2)
        #expect(item.size == 25_000_000)
        #expect(item.captureDate == Date(timeIntervalSince1970: 1_762_000_000.123))
        #expect(item.captureDateRaw.count == 15)
    }

    @Test func browsesBothSlots() async throws {
        // 卡 1：100 张 JPEG + 34 张 RAW + 1 段视频 = 101 次拍摄，要翻两页。
        let card1 = FakeCard.sample(photo: { Data(($0 + "-full").utf8) + Data(repeating: 7, count: 5_000_000) },
                                    thumb: { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(($0 + "-thumb").utf8) },
                                    photosPerFolder: 50)
        let card2 = FakeCard()
        let f = card2.folder("100MSDCF", parent: card2.folder("DCIM", parent: 0))
        card2.add(PTPObjectInfo(format: PTPObjectFormat.jpeg, size: 0, parent: f, filename: "SLOT2.JPG",
                                captureDate: "20261104T120000"), data: Data(repeating: 3, count: 1000))
        let state = FakeSonyState()
        state.remoteSlots = [1: card1, 2: card2]
        state.advertisedOperations = Self.ops
        let (fake, port) = try await start(state)
        defer { fake.stop() }

        let lib = try await SonyRemoteTransferLibrary.open(host: "127.0.0.1", port: port, identity: .random(name: "T"))
        let folders = try await lib.folders()
        #expect(folders.map(\.name) == ["卡槽 1", "卡槽 2"])
        let info = try #require(await lib.deviceInfo)
        #expect(info.model == "ILCE-7M5")
        #expect(info.cameraID == "ILCE-7M5#00000000012345")

        let hs1 = try await lib.handles(in: folders[0])
        #expect(hs1.count == 135)
        #expect(card1.remoteListRequests == 2)
        let kinds = try #require(await lib.kinds(in: folders[0]))
        #expect(kinds.values.filter { $0 == .jpeg }.count == 100)
        #expect(kinds.values.filter { $0 == .raw }.count == 34)
        #expect(kinds.values.filter { $0 == .video }.count == 1)
        // 新的在前。
        let first = try await lib.item(hs1[0]), last = try await lib.item(hs1[hs1.count - 1])
        #expect(first.captureDate! > last.captureDate!)

        let jpgHandle = try #require(kinds.first { $0.value == .jpeg }?.key)
        let jpg = try await lib.item(jpgHandle)
        let thumb = try #require(try await lib.thumbnail(jpgHandle))
        #expect(thumb.prefix(4) == Data([0xFF, 0xD8, 0xFF, 0xE0]))

        let url = FileManager.default.temporaryDirectory.appending(path: "rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let progress = ProgressLog()
        try await lib.download(jpg, to: url) { progress.add($0, $1) }
        let data = try Data(contentsOf: url)
        #expect(UInt64(data.count) == jpg.size)
        #expect(data.prefix(4) == Data("DSC0".utf8))
        #expect(progress.steps.count == 2)   // 5MB 按 4MiB 分块

        // 卡 2：直接切过去就能读，不用重连。
        let hs2 = try await lib.handles(in: folders[1])
        #expect(hs2.count == 1)
        #expect(try await lib.item(hs2[0]).filename == "SLOT2.JPG")
        #expect(try await lib.item(hs2[0]).storageID >> 16 == 2)
        await lib.close()
    }

    @Test func singleSlotListsOnlyThatSlot() async throws {
        let state = FakeSonyState()
        state.remoteSlots = [1: FakeCard.sample(photo: { Data($0.utf8) }, thumb: { _ in Data() })]
        let (fake, port) = try await start(state)
        defer { fake.stop() }
        let lib = try await SonyRemoteTransferLibrary.open(host: "127.0.0.1", port: port, identity: .random(name: "T"))
        #expect(try await lib.folders().map(\.name) == ["卡槽 1"])
        #expect(await lib.listingNotes.contains { $0.contains("卡槽 2") })
        await lib.close()
    }

    @Test func unsupportedCameraThrows() async throws {
        // 不支持远程传输（老实现：操作列表为空，0x923B 返回 OperationNotSupported）。
        let state = FakeSonyState()
        let (fake, port) = try await start(state)
        defer { fake.stop() }
        await #expect(throws: SonyRemoteTransferError.self) {
            _ = try await SonyRemoteTransferLibrary.open(host: "127.0.0.1", port: port, identity: .random(name: "T"))
        }

        // 操作列表里没有 0x923B：一个远程传输操作都不能发。
        let state2 = FakeSonyState()
        state2.advertisedOperations = [PTPOperation.getDeviceInfo, SonyOperation.sdioConnect]
        let card = FakeCard.sample(photo: { Data($0.utf8) }, thumb: { _ in Data() })
        state2.remoteSlots = [1: card]
        let (fake2, port2) = try await start(state2)
        defer { fake2.stop() }
        await #expect(throws: SonyRemoteTransferError.self) {
            _ = try await SonyRemoteTransferLibrary.open(host: "127.0.0.1", port: port2, identity: .random(name: "T"))
        }
        #expect(card.remoteListRequests == 0)
    }
}
