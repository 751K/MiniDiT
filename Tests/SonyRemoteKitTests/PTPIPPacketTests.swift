import Foundation
import Testing
@testable import SonyRemoteKit

@Suite struct PTPIPPacketTests {
    func roundTrip(_ p: PTPIPPacket) throws -> PTPIPPacket {
        var r = PTPReader(p.encoded())
        let len = try r.u32()
        let type = try r.u32()
        #expect(Int(len) == p.encoded().count)
        return try PTPIPPacket.decode(type: type, payload: try r.raw(r.remaining))
    }

    @Test func initCommandRequestLayout() throws {
        let guid = [UInt8](0..<16)
        let p = PTPIPPacket.initCommandRequest(guid: guid, name: "iPhone", version: 0x0001_0000)
        let bytes = [UInt8](p.encoded())
        // 8 字节头 + 16 GUID + "iPhone\0" UTF-16 (14) + 4 版本
        #expect(bytes.count == 8 + 16 + 14 + 4)
        #expect(Array(bytes[0..<8]) == [42, 0, 0, 0, 1, 0, 0, 0])
        #expect(Array(bytes[8..<24]) == guid)
        #expect(Array(bytes[38..<42]) == [0, 0, 1, 0])
        #expect(try roundTrip(p) == p)
    }

    @Test func operationRequestLayout() throws {
        let p = PTPIPPacket.operationRequest(phase: .dataOut, code: 0x9205, transactionID: 7, params: [0xD20D])
        let bytes = [UInt8](p.encoded())
        #expect(bytes == [22, 0, 0, 0, 6, 0, 0, 0, 2, 0, 0, 0, 0x05, 0x92, 7, 0, 0, 0, 0x0D, 0xD2, 0, 0])
        #expect(try roundTrip(p) == p)
    }

    @Test func otherPacketsRoundTrip() throws {
        let packets: [PTPIPPacket] = [
            .initCommandAck(connectionNumber: 3, guid: [UInt8](repeating: 9, count: 16), name: "ILCE-7M4", version: 0x0001_0000),
            .initEventRequest(connectionNumber: 3),
            .initEventAck,
            .initFail(reason: 1),
            .operationResponse(code: 0x2001, transactionID: 5, params: [1, 2]),
            .event(code: 0xC203, transactionID: 0, params: [0xD20D]),
            .startData(transactionID: 5, totalLength: 1_000_000),
            .data(transactionID: 5, payload: Data([1, 2, 3])),
            .endData(transactionID: 5, payload: Data([4, 5])),
            .probeRequest,
        ]
        for p in packets { #expect(try roundTrip(p) == p) }
    }

    @Test func ptpStringRoundTrip() throws {
        var w = PTPWriter()
        w.ptpString("DSC01234.JPG")
        w.ptpString("")
        var r = PTPReader(w.bytes)
        #expect(try r.ptpString() == "DSC01234.JPG")
        #expect(try r.ptpString() == "")
        #expect(r.isAtEnd)
    }

    @Test func readerThrowsOnTruncation() {
        var r = PTPReader([1, 2])
        #expect(throws: PTPDecodeError.self) { try r.u32() }
    }
}
