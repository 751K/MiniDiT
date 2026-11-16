import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct SonyPropertyCatalogTests {
    @Test func namesAndCodes() {
        #expect(SonyPropertyCatalog.code(for: "CreativeLook") == 0xD0FA)
        #expect(SonyPropertyCatalog.code(for: "creativelook_contrast") == 0xD0FB)
        #expect(SonyPropertyCatalog.code(for: "ISO") == 0xD21E)
        #expect(SonyPropertyCatalog.code(for: "0xD20F") == 0xD20F && SonyPropertyCatalog.code(for: "d20f") == 0xD20F)
        #expect(SonyPropertyCatalog.code(for: "NoSuchThing") == nil)
        #expect(SonyPropertyCatalog.name(0xD20F) == "Colortemp")
    }

    @Test func readableValuesRoundTrip() {
        let shutter: [Int64] = [0x0001_00FA, 0x0001_01F4, 0x0001_03E8, 0x0012_000A, 0]
        #expect(SonyPropertyCatalog.parse(0xD20D, "1/1000", allowed: shutter) == 0x0001_03E8)
        #expect(SonyPropertyCatalog.parse(0xD20D, "1.8\"", allowed: shutter) == 0x0012_000A)
        #expect(SonyPropertyCatalog.parse(0xD20D, "1.8s", allowed: shutter) == 0x0012_000A)
        let f: [Int64] = [280, 400, 560]
        #expect(SonyPropertyCatalog.parse(0x5007, "F5.6", allowed: f) == 560)
        #expect(SonyPropertyCatalog.parse(0x5007, "f/2.8", allowed: f) == 280)
        let iso: [Int64] = [0x00FF_FFFF, 100, 200, 3200]
        #expect(SonyPropertyCatalog.parse(0xD21E, "ISO 3200", allowed: iso) == 3200)
        #expect(SonyPropertyCatalog.parse(0xD21E, "AUTO", allowed: iso) == 0x00FF_FFFF)
        #expect(SonyPropertyCatalog.parse(0xD20F, "3200K", allowed: []) == 3200)
        #expect(SonyPropertyCatalog.label(0xD20F, 5600) == "5600K")
        #expect(SonyPropertyCatalog.parse(0xD0FA, "ST", allowed: Array(1...12)) == 1)
        #expect(SonyPropertyCatalog.parse(0xD0FA, "fl2", allowed: Array(1...12)) == 11)
        #expect(SonyPropertyCatalog.parse(0xD0FB, "+3", allowed: []) == 3 && SonyPropertyCatalog.label(0xD0FB, 3) == "+3")
        #expect(SonyPropertyCatalog.parse(0x5005, "ColorTemp", allowed: [2, 0x8012]) == 0x8012)
        #expect(SonyPropertyCatalog.parse(0x5005, "Custom2", allowed: [0x8020, 0x8021]) == 0x8021)
        #expect(SonyPropertyCatalog.parse(0xD222, "card+pc", allowed: [1, 0x10, 0x11]) == 0x11)
        #expect(SonyPropertyCatalog.parse(0x500A, "MF", allowed: [1, 2, 0x8004]) == 1)
        #expect(SonyPropertyCatalog.parse(0xD289, "0x7", allowed: [6, 7, 1]) == 7)
        // 白平衡微调（α7 V 实测：A2 = 200、G1 = 196）。
        #expect(SonyPropertyCatalog.label(0xD21C, 200) == "A2" && SonyPropertyCatalog.label(0xD210, 196) == "G1")
        #expect(SonyPropertyCatalog.label(0xD21C, 186) == "B1.5" && SonyPropertyCatalog.label(0xD210, 191) == "M0.25")
        #expect(SonyPropertyCatalog.label(0xD21C, 192) == "0")
        #expect(SonyPropertyCatalog.parse(0xD21C, "A2", allowed: []) == 200 && SonyPropertyCatalog.parse(0xD210, "M0.25", allowed: []) == 191)
        #expect(SonyPropertyCatalog.parse(0xD210, "G7", allowed: []) == 220 && SonyPropertyCatalog.parse(0xD21C, "0", allowed: []) == 192)
        #expect(SonyPropertyCatalog.parse(0xD253, "RAW+HEIF", allowed: [1, 4, 5]) == 4)
        #expect(SonyPropertyCatalog.parse(0xD252, "ExFine", allowed: [1, 2, 3, 4]) == 1)
    }

    @Test func setVerifiedChecksAndReadsBack() async throws {
        let state = FakeSonyState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let cam = try await SonyCamera.connect(host: "127.0.0.1", port: port, identity: .random(name: "Test"), startupDelay: 0)
        let d = try await cam.setVerified(SonyProperty.iso, .int(400))
        #expect(d.intValue == 400 && state.value(SonyProperty.iso) == 400)
        await #expect(throws: SonyPropertyError.readOnly(SonyProperty.exposureProgramMode)) {
            try await cam.setVerified(SonyProperty.exposureProgramMode, .int(2))
        }
        await #expect(throws: SonyPropertyError.invalidValue(SonyProperty.fNumber, allowed: [280, 400, 560, 800, 1100])) {
            try await cam.setVerified(SonyProperty.fNumber, .int(630))
        }
        await #expect(throws: SonyPropertyError.unknown(0xD0FA)) { try await cam.setVerified(0xD0FA, .int(1)) }
        #expect(SonyPropertyError.readOnly(1).code == "not_writable" && SonyPropertyError.rejected(1, response: 0x2019).code == "camera_busy")
        await cam.disconnect()
    }

    @Test func restoresChangedPropertiesNewestFirst() async throws {
        let state = FakeSonyState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let cam = try await SonyCamera.connect(host: "127.0.0.1", port: port, identity: .random(name: "Test"), startupDelay: 0)
        // 连接时改成 PC 优先，原值（相机优先）记下来。
        #expect(state.value(SonyProperty.priorityMode) == 1)
        _ = try await cam.setVerified(SonyProperty.iso, .int(400))
        _ = try await cam.setVerified(SonyProperty.iso, .int(200))
        _ = try await cam.setVerified(SonyProperty.whiteBalance, .int(0x8012))
        _ = try await cam.setVerified(SonyProperty.fNumber, .int(400))  // 本来就是 F4：不算改过
        let changed = await cam.changedProperties
        #expect(changed.map(\.code) == [SonyProperty.priorityMode, SonyProperty.iso, SonyProperty.whiteBalance])
        #expect(changed[1].original == .int(0x00FF_FFFF))

        let onlyPriority = await cam.restoreChanged(only: [SonyProperty.priorityMode])
        #expect(onlyPriority.map(\.code) == [SonyProperty.priorityMode] && onlyPriority[0].error == nil)
        #expect(state.value(SonyProperty.priorityMode) == 0 && state.value(SonyProperty.iso) == 200)

        let start = state.setLog.count
        let rest = await cam.restoreChanged()
        #expect(rest.map(\.code) == [SonyProperty.whiteBalance, SonyProperty.iso] && rest.allSatisfy { $0.error == nil })
        #expect(state.setLog[start...].map(\.code) == [SonyProperty.whiteBalance, SonyProperty.iso])
        #expect(state.value(SonyProperty.iso) == 0x00FF_FFFF && state.value(SonyProperty.whiteBalance) == 2)
        #expect(await cam.changedProperties.isEmpty)
        await cam.disconnect()
    }
}
