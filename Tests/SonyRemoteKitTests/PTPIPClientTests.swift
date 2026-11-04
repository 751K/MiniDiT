import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct PTPIPClientTests {
    @Test func handshakeSessionAndDataIn() async throws {
        let payload = Data((0..<5000).map { UInt8($0 & 0xFF) })
        let cam = try FakeCamera { code, _, _ in
            code == PTPOperation.getDeviceInfo ? .init(data: payload) : .init()
        }
        let port = try await cam.start()
        defer { cam.stop() }

        let identity = PTPIPHostIdentity(guid: [UInt8](repeating: 7, count: 16), friendlyName: "Test")
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: identity)
        try await client.connect(timeout: 3)
        #expect(await client.cameraName == "ILCE-7M4")
        #expect(cam.receivedGUID == identity.guid)

        try await client.openSession()
        let r = try await client.transaction(PTPOperation.getDeviceInfo)
        #expect(r.data == payload)
        await client.disconnect()
    }

    @Test func dataOutAndErrorCodes() async throws {
        let cam = try FakeCamera { code, _, data in
            if code == 0x9205 { return .init(code: data?.count == 2 ? PTPResponse.ok : PTPResponse.generalError) }
            return .init(code: PTPResponse.deviceBusy)
        }
        let port = try await cam.start()
        defer { cam.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        try await client.transaction(0x9205, [0xD2C1], dataOut: Data([2, 0]))
        await #expect(throws: PTPError.self) { try await client.transaction(0x1234) }
        await client.disconnect()
    }

    @Test func concurrentTransactionsAreSerialized() async throws {
        let cam = try FakeCamera { _, params, _ in
            var w = PTPWriter(); w.u32(params.first ?? 0)
            return .init(data: w.data)
        }
        let port = try await cam.start()
        defer { cam.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        try await withThrowingTaskGroup(of: Void.self) { g in
            for i in 0..<20 {
                g.addTask {
                    let r = try await client.transaction(0x1015, [UInt32(i)])
                    var rd = PTPReader(r.data)
                    #expect(try rd.u32() == UInt32(i))
                }
            }
            try await g.waitForAll()
        }
        await client.disconnect()
    }

    @Test func initFailIsReported() async throws {
        let cam = try FakeCamera { _, _, _ in .init() }
        cam.rejectWithInitFail = 1
        let port = try await cam.start()
        defer { cam.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        await #expect(throws: PTPIPTransportError.self) { try await client.connect(timeout: 3) }
    }

    @Test func eventsAreDelivered() async throws {
        let cam = try FakeCamera { _, _, _ in .init() }
        let port = try await cam.start()
        defer { cam.stop() }
        let client = PTPIPClient(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        try await client.connect(timeout: 3)
        try await cam.sendEvent(0xC201, [0xFFFFC001])
        var it = client.events.makeAsyncIterator()
        let e = await it.next()
        #expect(e == PTPEvent(code: 0xC201, params: [0xFFFFC001]))
        await client.disconnect()
    }
}
