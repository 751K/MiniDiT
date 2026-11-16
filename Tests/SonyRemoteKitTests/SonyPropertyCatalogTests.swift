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
        await #expect(throws: SonyPropertyError.readOnly(SonyProperty.focusMode)) {
            try await cam.setVerified(SonyProperty.focusMode, .int(1))
        }
        await #expect(throws: SonyPropertyError.invalidValue(SonyProperty.fNumber, allowed: [280, 320, 350, 400, 450, 500, 560, 630, 710, 800,
                                                                                             900, 1000, 1100, 1300, 1400, 1600, 1800, 2000, 2200])) {
            try await cam.setVerified(SonyProperty.fNumber, .int(120))
        }
        await #expect(throws: SonyPropertyError.unknown(0xD0E0)) { try await cam.setVerified(0xD0E0, .int(1)) }
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

    @Test func shootingModeGroups() {
        func mode(_ v: Int64) -> String? { SonyPropertyCatalog.shootingMode(v).map { "\($0.mode.rawValue) \($0.exposure)" } }
        #expect(mode(0x78053) == "movie m" && mode(1) == "photo m" && mode(0x10002) == "photo p")
        #expect(mode(0x9805C) == "sq m" && mode(0xC8096) == nil)
        let a7v: [Int64] = [0x48000, 0x10002, 0x20003, 0x30004, 0x1, 0x78054, 0x78050, 0x78051, 0x78052, 0x78053]
        #expect(SonyPropertyCatalog.exposureProgram(.photo, exposure: "P", allowed: a7v) == 0x10002)
        #expect(SonyPropertyCatalog.exposureProgram(.photo, exposure: "p", allowed: [1, 2, 3, 4]) == 2)
        #expect(SonyPropertyCatalog.exposureProgram(.movie, exposure: "auto", allowed: a7v) == 0x78054)
        #expect(SonyPropertyCatalog.exposureProgram(.movie, exposure: "m", allowed: [1, 2]) == nil)
        #expect(SonyPropertyCatalog.label(0x500E, 0x9805C) == "S&Q M" && SonyPropertyCatalog.label(0x500E, 0x78053) == "Movie M" && SonyPropertyCatalog.parse(0x500E, "Movie M", allowed: a7v) == 0x78053)
    }

    @Test func customWhiteBalanceStandbyCaptureAndCancel() async throws {
        let state = FakeSonyState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let cam = try await SonyCamera.connect(host: "127.0.0.1", port: port, identity: .random(name: "Test"), startupDelay: 0)
        func read() async throws -> [UInt16: Int64] {
            Dictionary(try await cam.allProperties().compactMap { d in d.intValue.map { (d.code, $0) } }, uniquingKeysWith: { _, b in b })
        }
        // AWB 时不能待机；切到自定义 3 后可以。
        var p = try await read()
        #expect(p[0xD26D] == 0)
        _ = try await cam.setVerified(SonyProperty.whiteBalance, .int(0x8022))
        p = try await read()
        #expect(p[0xD26D] == 1 && p[0xD20F] == 5500)
        try await cam.customWBButton(.standby)
        p = try await read()
        #expect(p[0xD270] == 1 && p[0xD26F] == 1)
        try await cam.customWBButton(.cancel)
        p = try await read()
        #expect(p[0xD270] == 0 && p[0xD26D] == 1)
        try await cam.customWBButton(.standby)
        try await cam.customWBCapture(.int(320 << 16 | 240), type: .uint32)
        p = try await read()
        #expect(p[0xD270] == 2)
        var polls = 0
        while p[0xD270] != 0, polls < 10 { polls += 1; p = try await read() }
        #expect(p[0xD270] == 0 && p[0xD20F] == 6300 && p[0xD210] == 188)
        #expect(state.customWBPosition == 0x0140_00F0 && state.customWBResult(slot: 3)?.kelvin == 6300 && state.customWBResult(slot: 1)?.kelvin == 7000)
        await cam.disconnect()
    }

    @Test func movieSettingLabels() {
        #expect(SonyPropertyCatalog.label(0xD241, 11) == "XAVC HS 4K" && SonyPropertyCatalog.label(0xD241, 15) == "XAVC S-I HD")
        // 实测：46 时录到 4K 59.94p 4:2:2 HEVC，3 时 59.94p。
        #expect(SonyPropertyCatalog.label(0xD242, 46) == "200M 4:2:2 10bit")
        #expect(SonyPropertyCatalog.label(0xD242, 1) == "60p 50M" && SonyPropertyCatalog.label(0xD242, 69) == "260M 4:2:2 10bit")
        #expect(SonyPropertyCatalog.label(0xD286, 3) == "60p" && SonyPropertyCatalog.label(0xD0D0, 7) == "24p")
        // α7 V 实测：PP1 的伽马 0x303、色彩模式 8 在机身上显示 S-Log3 / S-Gamut3.Cine。
        #expect(SonyPropertyCatalog.label(0xD0E1, 0x303) == "S-Log3" && SonyPropertyCatalog.label(0xD0E9, 8) == "S-Gamut3.Cine")
        #expect(SonyPropertyCatalog.label(0xD23F, 11) == "PP11" && SonyPropertyCatalog.label(0xD23F, 0x42) == "PP-LUT2")
        #expect(SonyFormat.settingLabel(0xD23F, 0) == "关" && SonyFormat.settingLabel(0xD03C, 257) == "用户 1" && SonyFormat.settingLabel(0xD03C, 2) == "预设 2")
        #expect(SonyPropertyCatalog.label(0xD03C, 0x0105) == "User5" && SonyPropertyCatalog.label(0xD052, 120) == "120fps")
        #expect(SonyFormat.settingLabel(0xE000, 0x501) == "开（Flexible ISO）" && SonyPropertyCatalog.label(0xE001, 1) == "S-Gamut3.Cine")
    }

    @Test func remoteTouchSendsPositionAndCancels() async throws {
        let state = FakeSonyState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let cam = try await SonyCamera.connect(host: "127.0.0.1", port: port, identity: .random(name: "Test"), startupDelay: 0)
        func value(_ c: UInt16) async throws -> Int64? { try await cam.allProperties().first { $0.code == c }?.intValue }
        try await cam.remoteTouch(x: 100, y: 400)
        #expect(state.touchPosition == UInt32(100 << 16 | 400))
        var cancel = try await value(0xD285), found = try await value(SonyProperty.focusFound)
        #expect(cancel == 1 && found == 2)
        try await cam.remoteTouch(x: 900, y: -5)   // 超出范围时夹到边上
        #expect(state.touchPosition == UInt32(639 << 16))
        try await cam.cancelRemoteTouch()
        cancel = try await value(0xD285); found = try await value(SonyProperty.focusFound)
        #expect(cancel == 0 && found == 1)
        #expect(SonyFormat.settingLabel(0xD283, 11) == "触摸跟踪" && SonyPropertyCatalog.label(0xD283, 9) == "FocusNoAE")
        await cam.disconnect()
    }

    @Test func extendedPropertiesReadAndWrite() async throws {
        let state = FakeSonyState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let cam = try await SonyCamera.connect(host: "127.0.0.1", port: port, identity: .random(name: "Test"), startupDelay: 0)
        // 0x9209 带扩展参数才读得到 0xE000；0x9205 带扩展参数才改得动（α7 V 实测）。
        #expect(try await cam.allProperties().contains { $0.code == 0xE000 })
        let d = try await cam.setVerified(0xE000, .int(0x501))
        #expect(d.intValue == 0x501 && state.value(0xE000) == 0x501)
        let gamut = try await cam.allProperties().first { $0.code == 0xE001 }
        #expect(gamut?.isWritable == true)
        await cam.disconnect()
    }

    @Test func focusPositionMovesWithoutRecordingAChange() async throws {
        let state = FakeSonyState()
        let fake = try FakeCamera { state.handle($0, $1, $2) }
        let port = try await fake.start()
        defer { fake.stop() }
        let cam = try await SonyCamera.connect(host: "127.0.0.1", port: port, identity: .random(name: "Test"), startupDelay: 0)
        let props = Dictionary(try await cam.allProperties().map { ($0.code, $0) }, uniquingKeysWith: { _, b in b })
        let c = SonyCamera.focusPositionControl(props)
        #expect(c?.setCode == 0xE088 && c?.currentCode == 0xE089 && c?.range == 0...63978)
        try await cam.setFocusPosition(20000)
        #expect(state.value(0xE089) == 20000 && state.value(0xE043) == 2048 + 20000 * (61971 - 2048) / 63978)
        try await cam.setFocusPosition(99999)   // 超出范围夹到近端
        #expect(state.value(0xE089) == 63978)
        // 调焦不算「改过的设置」：结束联机时不把对焦拉回去。
        #expect(await cam.changedProperties.allSatisfy { $0.code != 0xE088 })
        await cam.disconnect()
    }

    @Test func lensDistanceTableFromA7V() throws {
        let t = try #require(LensDistanceTable.parse(FakeSonyState.lensTable))
        #expect(t.entries.count == 29 && t.entries.first?.centimeters == 25 && t.entries.last?.centimeters == 0xFFFF)
        #expect(t.meters(at: 65535) == 0.25 && t.meters(at: 0) == .infinity)
        #expect(t.meters(at: 0x7FFF) == 0.5)                       // 表里正好有：0x7FFF → 50 cm
        let mid = try #require(t.meters(at: (0x9FFF + 0x7FFF) / 2))  // 40 cm 和 50 cm 之间
        #expect(mid > 0.4 && mid < 0.5)
        #expect(LensDistanceTable.text(0.453) == "0.45 m" && LensDistanceTable.text(1.24) == "1.2 m" && LensDistanceTable.text(12.4) == "12 m")
        #expect(LensDistanceTable.text(.infinity) == "∞")
    }

    @Test func focalFramesFromLiveViewDataset() {
        // FocalFrameInfo v1.04：版本 + 保留，空的保留数组，对焦框 1 个（广域）、人脸框 0、跟踪框 1 个（α7 V 实测的样子）。
        var f = [UInt8]()
        func u16(_ v: Int) { f += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: Int) { f += (0..<4).map { UInt8(v >> ($0 * 8) & 0xFF) } }
        func pad(_ n: Int) { f += [UInt8](repeating: 0, count: n) }
        func section(_ entries: [(t: Int, st: Int, x: Int, y: Int, h: Int, w: Int)]) {
            u32(1000); u32(1000); u16(entries.count); pad(6)
            for e in entries { u16(e.t); u16(e.st); pad(4); u32(e.x); u32(e.y); u32(e.h); u32(e.w) }
        }
        u16(104); pad(6); pad(40); u16(0); pad(6)
        section([(3, 1, 500, 500, 829, 788)])
        section([])
        section([(2, 2, 748, 625, 94, 78)])
        // 数据集头部：JPEG 偏移、长度，对焦框信息偏移、长度。
        let jpeg: [UInt8] = [0xFF, 0xD8, 1, 2, 0xFF, 0xD9]
        var w = PTPWriter()
        w.u32(32); w.u32(UInt32(jpeg.count)); w.u32(UInt32(32 + jpeg.count)); w.u32(UInt32(f.count))
        w.raw([UInt8](repeating: 0, count: 16)); w.raw(jpeg); w.raw(f)
        let info = SonyDatasets.extractFocalFrames(w.data)
        #expect(info?.version == 104 && info?.frames.count == 2)
        #expect(info?.frames.first?.kind == .focus && info?.frames.first?.w == 0.788)
        let t = info?.frames.last
        #expect(t?.kind == .tracking && t?.focused == true && t?.cx == 0.748 && t?.cy == 0.625 && t?.h == 0.094)
        #expect(SonyDatasets.extractLiveViewJPEG(w.data) == Data(jpeg))
        // 头部没有对焦框信息时为 nil。
        var plain = PTPWriter()
        plain.u32(16); plain.u32(UInt32(jpeg.count)); plain.u32(0); plain.u32(0); plain.raw(jpeg)
        #expect(SonyDatasets.extractFocalFrames(plain.data) == nil)
    }

    @Test func driveModeAndSidebarLabels() {
        func drive(_ v: Int64) -> String? { SonyFormat.driveMode(v)?.label }
        #expect(drive(1) == "单张拍摄" && drive(0x18015) == "连拍：中" && drive(0x38005) == "自拍 2 秒")
        // 包围：libgphoto2 表里的连续 / 单拍、各档位、2 张的 + / −。
        #expect(drive(0x48337) == "连续包围 0.3 EV 3 张" && drive(0x48911) == "连续包围 1.0 EV 9 张")
        #expect(drive(0x4C23F) == "连续包围 0.3 EV 2 张 −" && drive(0x5C230) == "单拍包围 3.0 EV 2 张 +")
        #expect(drive(0x58590) == "单拍包围 2.7 EV 5 张" && SonyFormat.driveMode(0x58590)?.sub == "2.7 EV")
        #expect(drive(0x48336) == nil && drive(0x12345) == nil)
        #expect(SonyFormat.settingLabel(0xD252, 1) == "超精细" && SonyFormat.settingLabel(0xD289, 7) == "压缩 HQ")
        #expect(SonyFormat.settingLabel(0xD201, 0x1F) == "自动" && SonyFormat.settingLabel(0xD0FB, 3) == nil)
    }
}
