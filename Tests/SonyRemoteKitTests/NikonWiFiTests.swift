import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

/// 尼康 Z 的 Wi-Fi 配对（libgphoto2 issue #1314 描述的流程），用模拟相机端到端检查。真机未验证。
@Suite struct NikonWiFiTests {
    @Test func parsesPairingCodeAndNikonGUID() {
        #expect(NikonWiFi.pairingCode(Data([4, 0, 0, 0, 1, 6, 5, 2])) == "1652")
        #expect(NikonWiFi.pairingCode(Data([4, 0, 0, 0, 0x31, 6, 5, 2])) == nil, "每位是数值，不是 ASCII")
        #expect(NikonWiFi.pairingCode(Data([4, 0, 0, 0, 1, 6])) == nil)
        #expect(NikonWiFi.isNikon(guid: [0x04, 0xB0, 0x04, 0x58] + [UInt8](repeating: 0, count: 12)))
        #expect(NikonWiFi.isNikon(guid: [0x58, 0x04, 0xB0, 0x04] + [UInt8](repeating: 0, count: 12)))
        #expect(!NikonWiFi.isNikon(guid: [UInt8](repeating: 0xAB, count: 16)))
        #expect(NikonBonjour.state(["apps": "PAIR", "guid": "04b00458-0000-1001-8001-3cbee15497f9"]) == true)
        #expect(NikonBonjour.state(["apps": "$DSC", "vid": "A"]) == false)
        #expect(NikonBonjour.state(["apps": "PAIR"]) == nil, "不像尼康的广播不下结论")
    }

    final class Pairing: @unchecked Sendable {
        let lock = NSLock()
        var paired = false
        var fake: FakeCamera?
    }

    func nikon(_ pairing: Pairing) async throws -> (FakeCamera, UInt16) {
        let state = FakeSonyState()
        state.card = FakeCard.sample(photo: { Data($0.utf8) }, thumb: { _ in Data([0xFF, 0xD8]) })
        let fake = try FakeCamera { code, params, data in
            switch code {
            case NikonWiFi.getPairingCode:
                return pairing.lock.withLock { pairing.paired } ? .init(code: PTPResponse.operationNotSupported)
                    : .init(data: Data([4, 0, 0, 0, 1, 6, 5, 2]))
            case NikonWiFi.confirmPairing:
                guard params == [0x2001] else { return .init(code: 0x2006) }
                // 用户在相机上点了确认：相机发 0x4008。
                Task {
                    try await Task.sleep(for: .milliseconds(300))
                    pairing.lock.withLock { pairing.paired = true }
                    try await pairing.fake?.sendEvent(NikonWiFi.deviceInfoChanged)
                }
                return .init()
            default:
                return state.handle(code, params, data)
            }
        }
        fake.ackGUID = [0x04, 0xB0, 0x04, 0x58, 0, 0, 0x10, 0x01, 0x80, 0x01, 0x3C, 0xBE, 0xE1, 0x54, 0x97, 0xF9]
        fake.ackName = "ZR"
        pairing.fake = fake
        return (fake, try await fake.start())
    }

    @Test func pairsThenReconnectsAndReadsCard() async throws {
        let pairing = Pairing()
        let (fake, port) = try await nikon(pairing)
        defer { fake.stop() }
        let identity = PTPIPHostIdentity.random(name: "Test")
        #expect(try await NikonWiFi.probe(host: "127.0.0.1", port: port, identity: identity).nikon)
        let codes = LockedList()
        let lib = try await NikonWiFi.openLibrary(host: "127.0.0.1", port: port, identity: identity, needsPairing: true,
                                                  showCode: { codes.add($0) })
        #expect(codes.items == ["1652"])
        #expect(pairing.lock.withLock { pairing.paired })
        let ops = fake.operations
        let first952B = try #require(ops.firstIndex(of: NikonWiFi.getPairingCode))
        #expect(ops[first952B - 1] == PTPOperation.openSession, "配对码必须是 OpenSession 之后的第一条命令")
        #expect(ops.filter { $0 == PTPOperation.openSession }.count == 2, "配对后用同一个 GUID 重连")
        #expect(fake.receivedGUID == identity.guid)
        let folders = try await lib.folders()
        #expect(!folders.isEmpty)
        #expect(try await lib.handles(in: folders[0]).count > 0)
        await lib.close()
    }

    @Test func alreadyPairedSkipsPairingAndUnknownStateFallsThrough() async throws {
        let pairing = Pairing(); pairing.paired = true
        let (fake, port) = try await nikon(pairing)
        defer { fake.stop() }
        let codes = LockedList()
        let lib = try await NikonWiFi.openLibrary(host: "127.0.0.1", port: port, identity: .random(name: "Test"),
                                                  needsPairing: nil, showCode: { codes.add($0) })
        #expect(codes.items.isEmpty)
        #expect(fake.operations.filter { $0 == PTPOperation.openSession }.count == 1)
        #expect(!(try await lib.folders()).isEmpty)
        await lib.close()
    }

    @Test func pairedToAnotherComputerIsExplained() async throws {
        let (fake, port) = try await nikon(Pairing())
        defer { fake.stop() }
        fake.rejectWithInitFail = 1
        await #expect(throws: NikonWiFi.Failure.self) {
            _ = try await NikonWiFi.probe(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        }
    }

    @Test func sonyIsNotMistakenForNikon() async throws {
        let fake = try FakeCamera { _, _, _ in .init() }
        let port = try await fake.start()
        defer { fake.stop() }
        #expect(try await NikonWiFi.probe(host: "127.0.0.1", port: port, identity: .random(name: "Test")).nikon == false)
    }
}

@Suite struct NikonCardTests {
    /// 尼康存储卡：DCIM/100NCZ_8/ 里的 NEF 归为 RAW，和同名 JPG 一起列出；NRW 同样。
    @Test func listsNEFAsRaw() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "nikon-card-\(UUID().uuidString)")
        let dir = root.appending(path: "DCIM/100NCZ_8")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["DSC_0001.NEF", "DSC_0001.JPG", "DSCN0002.NRW", "DSC_0003.MOV"] {
            try Data(repeating: 1, count: 64).write(to: dir.appending(path: name))
        }
        #expect(LocalCardLibrary.looksLikeCard(root))
        let lib = LocalCardLibrary(root: root)
        let folder = try await lib.folders()[0]
        var kinds: [String: CameraContentItem.Kind] = [:]
        for h in try await lib.handles(in: folder) { let i = try await lib.item(h); kinds[i.filename] = i.kind }
        #expect(kinds == ["DSC_0001.NEF": .raw, "DSC_0001.JPG": .jpeg, "DSCN0002.NRW": .raw, "DSC_0003.MOV": .video])
    }
}

final class LockedList: @unchecked Sendable {
    private let lock = NSLock(); private var v: [String] = []
    func add(_ s: String) { lock.lock(); v.append(s); lock.unlock() }
    var items: [String] { lock.lock(); defer { lock.unlock() }; return v }
}
