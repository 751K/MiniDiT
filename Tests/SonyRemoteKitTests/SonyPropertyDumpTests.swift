import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct SonyPropertyDumpTests {
    @Test func readsEveryPropertyWithoutWriting() async throws {
        let state = FakeSonyState()
        state.advertisedOperations = [PTPOperation.getDeviceInfo]
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let dump = try await SonyPropertyDump.read(host: "127.0.0.1", port: port, identity: .random(name: "Test"))
        let ops = fake.operations
        // 只读：不设属性、不按按键。
        #expect(!ops.contains(SonyOperation.setExtDevicePropValue) && !ops.contains(SonyOperation.controlDevice))
        #expect(state.setLog.isEmpty && state.controlLog.isEmpty)
        #expect(state.value(SonyProperty.stillImageStoreDestination) == 0x0010)
        #expect(dump.parseError == nil)
        #expect(dump.declaredCount == dump.entries.count)
        #expect(Set(dump.advertisedProperties) == Set(dump.entries.map(\.desc.code)))
        #expect(dump.advertisedControls == [SonyControl.shutterHalfPress, SonyControl.shutterFullPress, SonyControl.movieRecord])
        #expect(dump.deviceInfo?.model == "ILCE-7M5")
        let shutter = try #require(dump.entries.first { $0.desc.code == SonyProperty.shutterSpeed })
        #expect(shutter.desc.allowedValues.count == 56 && shutter.desc.isWritable)
        // 每条记录的位置首尾相接，覆盖整段数据。
        var cursor = 8
        for e in dump.entries { #expect(e.offset == cursor); cursor += e.length }
        #expect(cursor == dump.raw.count)
    }

    @Test func stopsAtUnparseableRecordAndKeepsTheRest() throws {
        let a = SonyPropertyDesc(code: 0xD20D, dataType: .uint32, getSet: 1, isEnabled: 1, factoryDefault: .int(1), current: .int(2),
                                 form: .enumeration([1, 2]))
        var data = SonyDatasets.encodeAllProperties([a])
        data[0] = 2   // 声明 2 条
        data.append(contentsOf: [0x99, 0xD2, 0x34, 0x12, 1, 1, 0, 0])   // 未知数据类型 0x1234
        let r = SonyPropertyDump.parse(data)
        #expect(r.entries.count == 1 && r.declared == 2)
        #expect(r.error?.contains("code 0xD299") == true)
    }
}
