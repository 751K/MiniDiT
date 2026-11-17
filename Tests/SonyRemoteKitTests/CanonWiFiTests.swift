import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

/// 佳能 EOS 的 Wi-Fi（遥控 / EOS Utility 连接）：按 libgphoto2 的做法用模拟相机端到端检查。真机未验证。
@Suite struct CanonWiFiTests {
    @Test func recognizesCanonNamesAndBroadcasts() {
        #expect(CanonWiFi.looksLikeCanon(name: "Canon EOS R6"))
        #expect(CanonWiFi.looksLikeCanon(name: "EOS R50"))
        #expect(!CanonWiFi.looksLikeCanon(name: "ILCE-7M5"))
        #expect(!CanonWiFi.looksLikeCanon(name: "ZR"))
        #expect(CanonBonjour.isCanon(["tid.canon.com": "00000000-0000-0000-0000-000000000000"], name: "xyz"))
        #expect(!CanonBonjour.isCanon(["apps": "PAIR", "guid": "04b00458"], name: "ZR_6001234"))
    }

    @Test func formatsMapToKinds() {
        func kind(_ format: UInt16, _ name: String) -> CameraContentItem.Kind {
            CameraContentItem(id: 1, storageID: 1, filename: name, format: format, size: 1, captureDate: nil,
                              captureDateRaw: "", width: 0, height: 0).kind
        }
        #expect(kind(CanonWiFi.formatCR3, "IMG_0001.CR3") == .raw)
        #expect(kind(CanonWiFi.formatCR2, "IMG_0002.CR2") == .raw)
        #expect(kind(CanonWiFi.formatMOV, "MVI_0003.MOV") == .video)
        #expect(kind(PTPObjectFormat.undefined, "MVI_0004.CRM") == .video)
        #expect(kind(0xB982, "MVI_0005.MP4") == .video)
    }

    func canon() async throws -> (FakeCamera, UInt16, FakeSonyState) {
        let state = FakeSonyState()
        state.card = FakeCard.sample(photo: { Data(repeating: 0x5A, count: 3 * 1024 * 1024 + $0.utf8.count) }, thumb: { _ in Data([0xFF, 0xD8]) })
        let fake = try FakeCamera { code, params, data in
            switch code {
            case CanonWiFi.setRemoteMode, CanonWiFi.keepDeviceOn: return .init()
            default: return state.handle(code, params, data)
            }
        }
        fake.ackGUID = [UInt8](repeating: 0x11, count: 16)
        fake.ackName = "Canon EOS R6"
        return (fake, try await fake.start(), state)
    }

    @Test func connectsSetsRemoteModeAndDownloadsInOneMegabyteChunks() async throws {
        let (fake, port, _) = try await canon()
        defer { fake.stop() }
        let identity = PTPIPHostIdentity.random(name: "Test")
        let probe = try await NikonWiFi.probe(host: "127.0.0.1", port: port, identity: identity)
        #expect(!probe.nikon && CanonWiFi.looksLikeCanon(name: probe.name))
        let lib = try await CanonWiFi.openLibrary(host: "127.0.0.1", port: port, identity: identity)
        let ops = fake.operations
        let open = try #require(ops.firstIndex(of: PTPOperation.openSession))
        let remote = try #require(ops.firstIndex(of: CanonWiFi.setRemoteMode), "会话打开后要发 SetRemoteMode")
        #expect(open < remote)
        #expect(fake.receivedGUID == identity.guid)
        let folders = try await lib.folders()
        #expect(!folders.isEmpty)
        let handles = try await lib.handles(in: folders[0])
        var photo: CameraContentItem?
        for h in handles { let i = try await lib.item(h); if i.kind != .other, i.size > 2 * 1024 * 1024 { photo = i; break } }
        let item = try #require(photo)
        let out = FileManager.default.temporaryDirectory.appending(path: "canon-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let before = fake.operations.filter { $0 == PTPOperation.getPartialObject }.count
        try await lib.download(item, to: out, from: 0, progress: { _, _ in })
        let reads = fake.operations.filter { $0 == PTPOperation.getPartialObject }.count - before
        #expect(try Data(contentsOf: out).count == Int(item.size))
        #expect(reads == Int((item.size + 1024 * 1024 - 1) / (1024 * 1024)), "每块 1 MB：\(reads) 次")
        await lib.close()
        #expect(!fake.operations.contains(PTPOperation.closeSession), "佳能断开时不发 CloseSession")
    }

    @Test func refusedHandshakeMeansNotPaired() async throws {
        let (fake, port, _) = try await canon()
        defer { fake.stop() }
        fake.rejectWithInitFail = 2
        await #expect(throws: CanonWiFi.Failure.notPaired) {
            _ = try await CanonWiFi.openLibrary(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        }
    }
}

@Suite struct CanonCardTests {
    /// 佳能存储卡：DCIM/100CANON/ 里的 CR3 / CR2 归为 RAW，CRM 归为视频。
    @Test func listsCanonFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "canon-card-\(UUID().uuidString)")
        let dir = root.appending(path: "DCIM/100CANON")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["IMG_0001.CR3", "IMG_0001.JPG", "IMG_0002.CR2", "MVI_0003.MP4", "MVI_0004.CRM", "IMG_0005.HIF"] {
            try Data(repeating: 1, count: 64).write(to: dir.appending(path: name))
        }
        let lib = LocalCardLibrary(root: root)
        let folder = try await lib.folders()[0]
        var kinds: [String: CameraContentItem.Kind] = [:]
        for h in try await lib.handles(in: folder) { let i = try await lib.item(h); kinds[i.filename] = i.kind }
        #expect(kinds == ["IMG_0001.CR3": .raw, "IMG_0001.JPG": .jpeg, "IMG_0002.CR2": .raw, "MVI_0003.MP4": .video,
                          "MVI_0004.CRM": .video, "IMG_0005.HIF": .heif])
    }
}
