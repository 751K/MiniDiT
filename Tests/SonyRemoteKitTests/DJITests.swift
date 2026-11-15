import Foundation
import Testing
@testable import SonyRemoteKit

/// 大疆 DUML 帧和文件列表解析。Fixtures/DJI 里的列表是 osmosis（MIT）从真实 Osmo Pocket 3 抓到的，
/// 见 Fixtures/DJI/LICENSE。
@Suite struct DJITests {
    static func hex(_ s: String) -> [UInt8] {
        var out: [UInt8] = []; var i = s.startIndex
        while i < s.endIndex { let j = s.index(i, offsetBy: 2); out.append(UInt8(s[i..<j], radix: 16)!); i = j }
        return out
    }

    static func fixture(_ name: String) throws -> [UInt8] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/DJI/\(name).bin")
        return [UInt8](try Data(contentsOf: url))
    }

    /// 和协议文档里的帧逐字节一致（含两段 CRC）。
    @Test func framesMatchDocumentedBytes() {
        #expect(DJIBLECommand.sessionOpen(0xCB1B).encoded() == Self.hex("550f04a202f01bcb40002b04009ab9"))
        #expect(DJIBLECommand.keepalive(0xCB1B).encoded() == Self.hex("550f04a202f01bcb40002b0101abd6"))
        #expect(DJIBLECommand.wifiSSID(0xA000).encoded() == Self.hex("550d0433020700a04007077472"))
        #expect(DJIBLECommand.wifiPassword(0xA000).encoded() == Self.hex("550d0433020700a040070eb5ef"))
        let list = DUMLFrame(receiver: DJIAddress.camera, messageID: 0xA000, commandSet: 0x00, commandID: 0x26,
                             payload: DJIManifest.listQuery(counter: 1, cursor: 1))
        #expect(list.encoded() == Self.hex("553704f9020100a04000264a002a10010000000000010000002d000d0100ffffffffffffffff0001000000000000000000000000008185"))
        let next = DUMLFrame(receiver: DJIAddress.camera, messageID: 0xA000, commandSet: 0x00, commandID: 0x26,
                             payload: DJIManifest.listQuery(counter: 1, cursor: 0x401036C0))
        #expect(next.encoded() == Self.hex("553704f9020100a04000264a002a10010000000000c03610402d000d0100ffffffffffffffff000100000000000000000000000000a7d3"))
        let trigger = DUMLFrame(receiver: DJIAddress.camera, messageID: 0xA000, commandSet: 0x00, commandID: 0x26, payload: DJIManifest.listTrigger)
        #expect(trigger.encoded() == Self.hex("551b0475020100a04000264a040e10010000000000010000008d86"))
    }

    @Test func pairingFrameMatchesDocumentedBytes() {
        let f = DJIBLECommand.pair(0xA000, identifier: "284ae5b8d76b3375a04a6417ad71bea3")
        #expect(f.encoded() == Self.hex("553304c2020700a0400745203238346165356238643736623333373561303461363431376164373162656133046f736d6f8c02"))
    }

    @Test func streamParserReassemblesSplitNotificationsAndSkipsGarbage() {
        let a = DJIBLECommand.sessionOpen(1).encoded(), b = DJIBLECommand.wifiSSID(2).encoded()
        var p = DUMLStreamParser()
        #expect(p.feed([0x00, 0x13] + a.prefix(5)).isEmpty)
        let got = p.feed(Array(a.dropFirst(5)) + b + [0x55, 0x01])
        #expect(got.map(\.commandID) == [0x2B, 0x07])
        #expect(DUMLFrame.decode(a)?.0 == DJIBLECommand.sessionOpen(1))
        var bad = a; bad[bad.count - 1] ^= 0xFF
        #expect(DUMLFrame.decode(bad) == nil)
        #expect(DUMLFrame.all(in: [1, 2, 3] + a + [9] + b).count == 2)
    }

    @Test func reassemblesChunksPerCounter() {
        func chunk(_ ctr: UInt8, _ sub: UInt8, _ data: [UInt8]) -> DUMLFrame {
            DUMLFrame(sender: 0x01, receiver: 0x02, messageID: 1, flags: DUMLFrame.response, commandSet: 0x00, commandID: 0x27,
                      payload: [0x4A, sub, 0, 0, ctr, 0, 0, 0, 0, 0] + data)
        }
        let frames = [chunk(1, 0x04, []), chunk(1, 0x01, [1, 2]), chunk(2, 0x01, [9]), chunk(1, 0x01, [3]), chunk(1, 0x03, [])]
        #expect(DJIManifest.reassemble(frames, counter: 1) == [1, 2, 3])
        #expect(DJIManifest.reassemble(frames, counter: 2) == [9])
        #expect(DJIManifest.ended(frames, counter: 1) == (answered: true, ended: true))
        #expect(DJIManifest.ended(frames, counter: 2) == (answered: true, ended: false))
        #expect(DJIManifest.ended(frames, counter: 3) == (answered: false, ended: false))
    }

    /// 真实 Pocket 3：15 段视频，文件名带 _OP3 后缀；句柄 = 0x00040000 + 序号 × 0x10。
    @Test func decodesPocket3Videos() throws {
        let files = DJIManifest.decode(try Self.fixture("op3_15"))
        #expect(files.count == 15)
        #expect(files.allSatisfy { $0.ext == "MP4" && $0.name.contains("_D_OP3.") && $0.mediaPath.hasPrefix("DCIM/DJI_001/") })
        for f in files {
            let seq = UInt32(f.name.split(separator: "_")[2])!
            #expect(f.handle == 0x0004_0000 + seq * 0x10, "\(f.name)")
            // ≥ 4 GB 的长片段（这张卡上 600 秒以上的几段）大小栏是 0，下载时以实际传输为准。
            #expect(f.durationSeconds > 600 ? f.size == 0 : f.size > 1_000_000, "\(f.name) \(f.size)")
            #expect(f.durationSeconds > 0)
            #expect(f.proxySize == 0, "Pocket 3 的 T+28 落在路径里，不能当代理大小")
            #expect(f.proxyPath == f.mediaPath + ".LRF")
            #expect(f.filePath == f.mediaPath + ".MP4")
            #expect(f.thumbPath?.hasPrefix("MISC/THM/") == true)
            #expect(f.captureDateRaw?.hasPrefix(String(f.name.dropFirst(4).prefix(8))) == true, "\(f.name) \(f.captureDateRaw ?? "nil")")
        }
    }

    /// 真实 Pocket 3：同一张卡上 18 张照片、11 段视频。照片的 `19 06` 前面是 f6 而不是 ff，
    /// 要按固定位置（原片路径字段 − 7）读，不能往后扫到下一条记录的句柄。
    @Test func decodesPocket3MixedCard() throws {
        let buf = try Self.fixture("op3_29")
        let files = DJIManifest.decode(buf)
        #expect(files.count == 29)
        #expect(Set(files.map(\.mediaPath)).count == 29)
        #expect(files.filter { $0.ext == "JPG" }.count == 18)
        #expect(files.allSatisfy { $0.handle != 0 })
        #expect(Set(files.map(\.handle)).count == 29)
        #expect(files.filter { $0.ext == "JPG" }.allSatisfy { $0.proxyPath == nil && $0.size > 100_000 })
        #expect(!DJIManifest.hasEndMarker(buf))
        let item = DJICameraLibrary.item(1, files.first { $0.ext == "JPG" }!)
        #expect(item.kind == .jpeg && item.captureDateRaw.count == 15)
    }

    @Test func decodesPocket3Panoramas() throws {
        let files = DJIManifest.decode(try Self.fixture("op3_9_pano"))
        #expect(files.count == 9)
        #expect(files.allSatisfy { $0.handle != 0 && $0.size > 0 })
    }

    @Test func fatTimeDecodes() {
        // 2025-11-15 14:30:00
        let date = UInt32((2025 - 1980) << 9 | 11 << 5 | 15), time = UInt32(14 << 11 | 30 << 5)
        var r = DJIManifest.Record(name: "A.MP4", mediaPath: "DCIM/A", thumbPath: nil, handle: 1, size: 1, proxySize: 0,
                                   fatTime: date << 16 | time, durationSeconds: 1, store: 0)
        #expect(r.captureDateRaw == "20251115T143000")
        r.fatTime = 0
        #expect(r.captureDateRaw == nil)
    }

    @Test func udpHeaderChecksum() {
        let h = DJIDatalink.udpHeader(type: 0x05, payloadLength: 40, session: 0x1234, seq: 0xB88F)
        #expect(h.count == 8 && h[0] == 48 && h[1] == 0x80 && h[6] == 0x05)
        #expect(h[7] == h[0..<7].reduce(0, ^))
    }
}
