import Foundation
import Testing
@testable import SonyRemoteKit
import FakeSonyCamera

/// USB（ImageCaptureCore 透传）的容器编解码，以及用模拟相机走一遍索尼联机和标准 PTP 浏览下载。
/// 模拟设备收到的是和真机一样的命令容器，返回数据阶段和响应容器。真机未验证。
@Suite struct PTPUSBTests {
    @Test func encodesAndDecodesContainers() {
        let c = PTPUSBContainer.encode(type: PTPUSBContainer.command, code: 0x1008, transactionID: 7, params: [0x42])
        #expect(c == Data([16, 0, 0, 0, 1, 0, 0x08, 0x10, 7, 0, 0, 0, 0x42, 0, 0, 0]))
        let d = PTPUSBContainer.decode(c)
        #expect(d?.type == 1 && d?.code == 0x1008 && d?.transactionID == 7 && d?.params == [0x42])
        // 数据阶段带着容器头时去掉，不带时原样返回。
        var w = PTPWriter(); w.u32(15); w.u16(2); w.u16(0x1009); w.u32(7); w.raw([0xFF, 0xD8, 0xFF])
        #expect(PTPUSBContainer.payload(w.data) == Data([0xFF, 0xD8, 0xFF]))
        #expect(PTPUSBContainer.payload(Data([0xFF, 0xD8, 0xFF, 0xD9])) == Data([0xFF, 0xD8, 0xFF, 0xD9]))
        #expect(PTPUSBContainer.decode(Data([1, 2, 3])) == nil)
    }

    @Test func sonyTetherHandshakeAndCaptureOverUSB() async throws {
        let state = FakeSonyState()
        let device = FakeUSBDevice(name: "ILCE-7M5") { state.handle($0, $1, $2) }
        let cam = try await SonyCamera.connect(transport: PTPUSBClient(device: device), startupDelay: 0)
        let ops = device.operations
        #expect(Array(ops.prefix(6)) == [0x1002, 0x1001, 0x9201, 0x9201, 0x9202, 0x9201], "索尼握手和 Wi-Fi 一样")
        #expect(device.dataPhaseCodes.contains(SonyOperation.setExtDevicePropValue), "设置属性要带数据阶段")
        #expect(state.setLog.contains { $0.code == SonyProperty.priorityMode && $0.data == [1] })
        let s = try await cam.refreshStatus()
        #expect(s.settings.first { $0.kind == .shutterSpeed }?.valueText == "1/250")
        try await cam.set(.iso, value: 400)
        #expect(state.value(SonyProperty.iso) == 400)
        #expect(await cam.displayName == "ILCE-7M5")
        // 事件经 ptpEventHandler 进来：属性变化通知上层刷新。
        let notes = cam.notifications
        device.sendEvent(code: SonyEvent.propertyChanged)
        var gotStatus = false
        for await n in notes { if case .statusChanged = n { gotStatus = true; break } }
        #expect(gotStatus)
        await cam.disconnect()
        #expect(device.closed)
    }

    @Test func standardPTPBrowsingAndDownloadOverUSB() async throws {
        let state = FakeSonyState()
        state.card = FakeCard.sample(photo: { Data(repeating: 0x61, count: 5 * 1024 * 1024 + $0.utf8.count) }, thumb: { _ in Data([0xFF, 0xD8]) })
        let device = FakeUSBDevice(name: "ILCE-7M5") { state.handle($0, $1, $2) }
        let lib = PTPCameraLibrary(client: PTPUSBClient(device: device))
        let folders = try await lib.folders()
        #expect(!folders.isEmpty)
        var photo: CameraContentItem?
        for h in try await lib.handles(in: folders[0]) {
            let i = try await lib.item(h)
            if i.size > 4 * 1024 * 1024 { photo = i; break }
        }
        let item = try #require(photo)
        let out = FileManager.default.temporaryDirectory.appending(path: "usb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        try await lib.download(item, to: out, from: 0, progress: { _, _ in })
        #expect(try Data(contentsOf: out).count == Int(item.size))
        // 拔掉：事件流结束，库报告断开。
        let lost = lib.connectionLost
        device.unplug()
        var ended = false
        for await _ in lost { ended = true; break }
        #expect(ended)
    }

    @Test func timesOutWhenDeviceIsSilent() async throws {
        let device = FakeUSBDevice(name: "X") { _, _, _ in .init() }
        device.silent = true
        let client = PTPUSBClient(device: device)
        await client.setResponseTimeout(0.2)
        await #expect(throws: PTPIPTransportError.self) {
            _ = try await client.transaction(PTPOperation.getDeviceInfo)
        }
    }
}

/// 模拟 ImageCaptureCore 里的 USB 相机：解析命令容器，交给 FakeSonyState，按透传接口的格式返回。
final class FakeUSBDevice: PTPPassthroughDevice, @unchecked Sendable {
    let name: String
    private let handler: (UInt16, [UInt32], Data?) -> FakeCamera.Reply
    private let lock = NSLock()
    private var log: [UInt16] = []
    private var dataCodes: [UInt16] = []
    private var eventHandler: (@Sendable (Data) -> Void)?
    private var removalHandler: (@Sendable () -> Void)?
    private var _closed = false
    var silent = false

    init(name: String, handler: @escaping (UInt16, [UInt32], Data?) -> FakeCamera.Reply) {
        self.name = name
        self.handler = handler
    }

    var operations: [UInt16] { lock.withLock { log } }
    var dataPhaseCodes: [UInt16] { lock.withLock { dataCodes } }
    var closed: Bool { lock.withLock { _closed } }

    func send(command: Data, outData: Data?) async throws -> (data: Data, response: Data) {
        if silent { try await Task.sleep(for: .seconds(30)) }
        guard let c = PTPUSBContainer.decode(command), c.type == PTPUSBContainer.command else { throw PTPUSBError.noResponse }
        lock.withLock { log.append(c.code); if outData != nil { dataCodes.append(c.code) } }
        let reply = handler(c.code, c.params, outData)
        var response = PTPWriter()
        response.u32(UInt32(12 + 4 * reply.params.count)); response.u16(PTPUSBContainer.response)
        response.u16(reply.code); response.u32(c.transactionID)
        reply.params.forEach { response.u32($0) }
        // 和真机一样：数据阶段有时带容器头。这里交替返回两种形式。
        var data = reply.data ?? Data()
        if !data.isEmpty, c.transactionID % 2 == 0 {
            var w = PTPWriter(); w.u32(UInt32(12 + data.count)); w.u16(PTPUSBContainer.data); w.u16(c.code); w.u32(c.transactionID)
            w.raw(data); data = w.data
        }
        return (data, response.data)
    }

    func setEventHandler(_ handler: @escaping @Sendable (Data) -> Void) { lock.withLock { eventHandler = handler } }
    func setRemovalHandler(_ handler: @escaping @Sendable () -> Void) { lock.withLock { removalHandler = handler } }

    func sendEvent(code: UInt16, params: [UInt32] = []) {
        let h = lock.withLock { eventHandler }
        h?(PTPUSBContainer.encode(type: PTPUSBContainer.event, code: code, transactionID: 0, params: params))
    }

    func unplug() {
        let h = lock.withLock { removalHandler }
        h?()
    }

    func close() async {
        lock.withLock { _closed = true }
    }
}

@Suite struct USBCameraOpenerTests {
    @Test func standardStorageUsesPlainPTP() async throws {
        let state = FakeSonyState()
        state.card = FakeCard.sample(photo: { Data($0.utf8) }, thumb: { _ in Data() })
        let device = FakeUSBDevice(name: "X-T5") { state.handle($0, $1, $2) }
        let lib = try await USBCameraOpener.openLibrary(name: "X-T5", makeTransport: { PTPUSBClient(device: device) })
        #expect(lib is PTPCameraLibrary)
        #expect(!(try await lib.folders()).isEmpty)
        #expect(!device.operations.contains(SonyOperation.sdioConnect), "标准模式不发索尼命令")
    }

    @Test func sonyPCRemoteModeUsesRemoteTransfer() async throws {
        let state = FakeSonyState()
        state.remoteSlots = [1: FakeCard.sample(photo: { Data($0.utf8) }, thumb: { _ in Data() })]
        let device = FakeUSBDevice(name: "ILCE-7M5") { state.handle($0, $1, $2) }
        let lib = try await USBCameraOpener.openLibrary(name: "ILCE-7M5", makeTransport: { PTPUSBClient(device: device) })
        #expect(lib is SonyRemoteTransferLibrary)
        #expect(try await lib.folders().map(\.name) == ["卡槽 1"])
    }

    @Test func nonSonyWithoutStorageIsExplained() async throws {
        let device = FakeUSBDevice(name: "EOS R6") { code, _, _ in
            code == PTPOperation.getStorageIDs ? .init(data: Data([0, 0, 0, 0])) : .init()
        }
        await #expect(throws: USBCameraOpener.Failure.self) {
            _ = try await USBCameraOpener.openLibrary(name: "EOS R6", makeTransport: { PTPUSBClient(device: device) })
        }
        #expect(device.closed)
    }
}
