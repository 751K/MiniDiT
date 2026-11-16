import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

@Suite struct SonyCameraTests {
    func makeCamera(_ state: FakeSonyState = FakeSonyState()) async throws -> (SonyCamera, FakeCamera, FakeSonyState) {
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        let cam = try await SonyCamera.connect(host: "127.0.0.1", port: port, identity: .random(name: "Test"), startupDelay: 0)
        return (cam, fake, state)
    }

    @Test func handshakeSequenceAndStatus() async throws {
        let (cam, fake, state) = try await makeCamera()
        defer { fake.stop() }

        let ops = fake.operations
        let expectedPrefix: [UInt16] = [0x1002, 0x1001, 0x9201, 0x9201, 0x9202, 0x9201]
        #expect(Array(ops.prefix(6)) == expectedPrefix)
        #expect(ops.contains(SonyOperation.getAllExtDevicePropInfo))
        // PriorityMode 设为 1，存储目标从「仅卡」改为「卡 + 主机」。
        #expect(state.setLog.contains { $0.code == SonyProperty.priorityMode && $0.data == [1] })
        #expect(state.value(SonyProperty.stillImageStoreDestination) == 0x0011)

        let s = try await cam.refreshStatus()
        let text = Dictionary(uniqueKeysWithValues: s.settings.map { ($0.kind, $0.valueText) })
        #expect(text[.shutterSpeed] == "1/250")
        #expect(text[.aperture] == "F4.0")
        #expect(text[.iso] == "AUTO")
        #expect(text[.exposureCompensation] == "±0.0")
        #expect(text[.whiteBalance] == "AWB")
        #expect(s.modeText == "M 手动曝光")
        #expect(s.batteryText == "76%")
        let shutterLabels = s.settings.first { $0.kind == .shutterSpeed }?.options.map(\.label) ?? []
        #expect(shutterLabels.first == "30\"" && shutterLabels.contains("1.6\"") && shutterLabels.contains("1/250") && shutterLabels.suffix(2) == ["1/8000", "BULB"])
        #expect(await cam.displayName == "ILCE-7M4")
        await cam.disconnect()
    }

    @Test func setAndStepSettings() async throws {
        let (cam, fake, state) = try await makeCamera()
        defer { fake.stop() }
        _ = try await cam.refreshStatus()

        try await cam.set(.shutterSpeed, value: 0x0001_03E8)
        #expect(state.value(SonyProperty.shutterSpeed) == 0x0001_03E8)
        #expect(state.setLog.last.map { $0.data } == [0xE8, 0x03, 0x01, 0x00])

        try await cam.step(.aperture, by: 1)
        #expect(state.value(SonyProperty.fNumber) == 450)
        _ = try await cam.refreshStatus()
        try await cam.step(.aperture, by: -2)
        #expect(state.value(SonyProperty.fNumber) == 350)

        try await cam.set(.exposureCompensation, value: -300)
        #expect(state.value(SonyProperty.exposureBias) == -300)
        #expect(state.setLog.last.map { $0.data } == [0xD4, 0xFE])

        let s = try await cam.refreshStatus()
        #expect(s.settings.first { $0.kind == .exposureCompensation }?.valueText == "-0.3")
        await cam.disconnect()
    }

    @Test func invalidValueIsRejectedByCamera() async throws {
        let (cam, fake, _) = try await makeCamera()
        defer { fake.stop() }
        await #expect(throws: PTPError.self) { try await cam.set(.whiteBalance, value: 0x9999) }
        await cam.disconnect()
    }

    @Test func captureAndDownload() async throws {
        let (cam, fake, state) = try await makeCamera()
        defer { fake.stop() }

        try await cam.capture()
        let seq = state.controlLog.map { "\(String(format: "%04X", $0.code)):\($0.value)" }
        #expect(seq == ["D2C1:2", "D2C2:2", "D2C2:1", "D2C1:1"])

        let s = try await cam.refreshStatus()
        #expect(s.pendingTransfers == 1)

        let files = try await cam.downloadPendingFiles()
        #expect(files.count == 1)
        #expect(files.first?.filename == "DSC01234.JPG")
        #expect(files.first?.data.count == 70_000)
        #expect(try await cam.refreshStatus().pendingTransfers == 0)
        await cam.disconnect()
    }

    @Test func halfPressThenCapture() async throws {
        let (cam, fake, state) = try await makeCamera()
        defer { fake.stop() }
        try await cam.halfPress(true)
        #expect(try await cam.refreshStatus().isFocused)
        try await cam.capture()
        let seq = state.controlLog.map { "\(String(format: "%04X", $0.code)):\($0.value)" }
        #expect(seq == ["D2C1:2", "D2C2:2", "D2C2:1", "D2C1:1"])
        await cam.disconnect()
    }

    @Test func movieRecording() async throws {
        let (cam, fake, _) = try await makeCamera()
        defer { fake.stop() }
        try await cam.setRecording(true)
        #expect(try await cam.refreshStatus().isRecording)
        try await cam.setRecording(false)
        #expect(try await cam.refreshStatus().isRecording == false)
        await cam.disconnect()
    }

    @Test func liveViewSkipsFakeMarkerInHeader() async throws {
        let (cam, fake, state) = try await makeCamera()
        defer { fake.stop() }
        let frame = try await cam.liveViewFrame()
        #expect(frame == state.jpeg)
        await cam.disconnect()
    }

    @Test func eventsBecomeNotifications() async throws {
        let (cam, fake, _) = try await makeCamera()
        defer { fake.stop() }
        try await fake.sendEvent(SonyEvent.objectAdded, [SonyObjectHandle.capturedImage])
        var it = cam.notifications.makeAsyncIterator()
        #expect(await it.next() == .fileAvailable)
        await cam.disconnect()
    }
}

@Suite struct SonyDatasetTests {
    @Test func twinEnumListUsesSecondList() throws {
        // 第一列表 [1,2]，第二列表 [2]，随后是下一条记录。
        var w = PTPWriter()
        w.u32(2); w.u32(0)
        w.u16(0x5005); w.u16(PTPDataType.uint16.rawValue); w.u8(1); w.u8(1)
        w.u16(2); w.u16(2); w.u8(2)
        w.u16(2); w.u16(1); w.u16(2)
        w.u16(1); w.u16(2)
        w.u16(0xD218); w.u16(PTPDataType.int8.rawValue); w.u8(0); w.u8(1)
        w.u8(0xFF); w.u8(50); w.u8(0)
        let props = SonyDatasets.parseAllProperties(w.data)
        #expect(props[0x5005]?.form == .enumeration([2]))
        #expect(props[0xD218]?.intValue == 50)
    }

    @Test func singleEnumListFollowedByRecord() throws {
        let a = SonyPropertyDesc(code: 0x5007, dataType: .uint16, getSet: 1, isEnabled: 1,
                                 factoryDefault: .int(280), current: .int(400), form: .enumeration([280, 400]))
        let b = SonyPropertyDesc(code: 0xD20D, dataType: .uint32, getSet: 1, isEnabled: 1,
                                 factoryDefault: .int(0), current: .int(0x0001_00FA), form: .none)
        let props = SonyDatasets.parseAllProperties(SonyDatasets.encodeAllProperties([a, b]))
        #expect(props[0x5007] == a)
        #expect(props[0xD20D] == b)
    }

    @Test func truncatedDatasetKeepsParsedRecords() {
        let a = SonyPropertyDesc(code: 0x5007, dataType: .uint16, getSet: 1, isEnabled: 1,
                                 factoryDefault: .int(280), current: .int(400), form: .none)
        var data = SonyDatasets.encodeAllProperties([a])
        data.append(contentsOf: [0x0D, 0xD2, 0x06, 0x00, 1])
        #expect(SonyDatasets.parseAllProperties(data).count == 1)
    }

    @Test func objectInfoRoundTrip() throws {
        let o = PTPObjectInfo(format: 0xB101, size: 12345, parent: 7, filename: "DSC09999.ARW", captureDate: "20261104T153012")
        #expect(try PTPObjectInfo.parse(o.encoded()) == o)
    }

    @Test func liveViewFallbackScan() {
        var bytes: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 9, 9]
        bytes += [0xFF, 0xD8, 7, 7, 0xFF, 0xD9, 0, 0]
        #expect(SonyDatasets.extractLiveViewJPEG(Data(bytes)) == Data([0xFF, 0xD8, 7, 7, 0xFF, 0xD9]))
    }
}

@Suite struct SonyFormatTests {
    @Test func shutter() {
        #expect(SonyFormat.shutterSpeed(0x0001_00FA) == "1/250")
        #expect(SonyFormat.shutterSpeed(0x0001_1F40) == "1/8000")
        #expect(SonyFormat.shutterSpeed((15 << 16) | 10) == "1.5\"")
        #expect(SonyFormat.shutterSpeed((300 << 16) | 10) == "30\"")
        #expect(SonyFormat.shutterSpeed((4 << 16) | 10) == "0.4\"")
        #expect(SonyFormat.shutterSpeed(0) == "BULB")
    }

    @Test func aperture() {
        #expect(SonyFormat.fNumber(180) == "F1.8")
        #expect(SonyFormat.fNumber(400) == "F4.0")
        #expect(SonyFormat.fNumber(1100) == "F11")
        #expect(SonyFormat.fNumber(0xFFFF) == "--")
    }

    @Test func isoAndBias() {
        #expect(SonyFormat.iso(0x00FF_FFFF) == "AUTO")
        #expect(SonyFormat.iso(100) == "100")
        #expect(SonyFormat.iso(102_400) == "102400")
        #expect(SonyFormat.iso(0x01FF_FFFF) == "多帧NR AUTO")
        #expect(SonyFormat.exposureBias(300) == "+0.3")
        #expect(SonyFormat.exposureBias(-1700) == "-1.7")
        #expect(SonyFormat.exposureBias(0) == "±0.0")
        #expect(SonyFormat.exposureBias(Int64(UInt16(bitPattern: -700))) == "-0.7")
    }

    @Test func program() {
        #expect(SonyFormat.exposureProgram(0x0002_0003) == "A 光圈优先")
        #expect(SonyFormat.exposureProgram(0x0004) == "S 快门优先")
        #expect(SonyFormat.exposureProgram(0x0003) == "A 光圈优先")
    }
}
