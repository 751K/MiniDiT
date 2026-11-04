import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct ContentsTransferTests {
    func makeState() -> (FakeSonyState, FakeCard) {
        let card = FakeCard.sample(photo: { Data(($0 + "-full").utf8) + Data(repeating: 9, count: 7_000_000) },
                                   thumb: { Data(($0 + "-thumb").utf8) }, photosPerFolder: 3)
        let state = FakeSonyState()
        state.card = card
        state.requireContentsTransferMode = true
        return (state, card)
    }

    @Test func entersContentsTransferModeAndDownloadsWithLargeObjectReads() async throws {
        let (state, card) = makeState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }

        let lib = try await SonyContentsTransfer.openLibrary(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        #expect(state.sessionMode == SonyFunctionMode.contentsTransfer.rawValue)
        #expect(state.contentsTransferModeParams == [[2, 1, 0]])
        let ops = fake.operations
        #expect(ops.contains(SonyOperation.sdioOpenSession))
        #expect(!ops.contains(PTPOperation.openSession))
        // D295 第 2 次轮询才就绪，说明确实等了。
        #expect(ops.filter { $0 == SonyOperation.getAllExtDevicePropInfo }.count >= 2)

        let folders = try await lib.folders()
        #expect(folders.map(\.name) == ["101MSDCF", "100MSDCF", "视频"])
        let h = try await lib.handles(in: folders[0])[0]
        let item = try await lib.item(h)
        let url = FileManager.default.temporaryDirectory.appending(path: "ct-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try await lib.download(item, to: url) { _, _ in }
        #expect(try Data(contentsOf: url).count == item.size)
        // 7MB 按 3MiB 分块用 0x9211 读 3 次。
        #expect(card.partialReads == 3)
        #expect(fake.operations.contains(SonyOperation.getPartialLargeObject))

        await lib.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(state.contentsTransferModeParams.last == [2, 0, 0])
    }

    @Test func storageIsUnavailableWithoutModeSwitch() async throws {
        let (state, _) = makeState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        try await client.openSession()
        await #expect(throws: PTPError.self) { _ = try await client.storageIDs() }
        await client.disconnect()
    }

    @Test func unknownSizeFilesDownloadCompletely() async throws {
        // ≥4GB 的文件在 ObjectInfo 里大小是 0xFFFFFFFF；这里用小文件 + 假报大小模拟。
        let card = FakeCard()
        let payload = Data((0..<6_500_000).map { UInt8($0 % 253) })
        card.add(PTPObjectInfo(format: PTPObjectFormat.mp4, size: 0, parent: 0, filename: "C0001.MP4"),
                 data: payload, reportedSize: 0xFFFF_FFFF)
        let state = FakeSonyState()
        state.card = card
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        try await client.openSession()

        for large in [true, false] {
            let lib = PTPCameraLibrary(client: client, largeObjectReads: large)
            let folders = try await lib.folders()
            #expect(folders.map(\.name) == ["根目录"])
            guard !folders.isEmpty else { return }
            let item = try await lib.item(try await lib.handles(in: folders[0])[0])
            #expect(item.sizeKnown == false)
            let url = FileManager.default.temporaryDirectory.appending(path: "u-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: url) }
            let log = ProgressLog()
            try await lib.download(item, to: url) { log.add($0, $1) }
            #expect(try Data(contentsOf: url) == payload, "largeObjectReads=\(large)")
            #expect(log.steps.last?.0 == UInt64(payload.count))
        }
        await client.disconnect()
    }

    @Test func stalledCameraTearsDownConnection() async throws {
        let state = FakeSonyState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        fake.silentOperations = [PTPOperation.getStorageIDs]
        let port = try await fake.start()
        defer { fake.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        await client.setResponseTimeout(0.5)
        let lib = PTPCameraLibrary(client: client)

        let start = Date()
        await #expect(throws: PTPIPTransportError.self) { _ = try await client.storageIDs() }
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(await client.isConnected == false)

        // 连接断开信号会发出。
        var it = lib.connectionLost.makeAsyncIterator()
        _ = await it.next()
        // 断开后 shutdown 不会卡住。
        await client.shutdown()
    }
}
