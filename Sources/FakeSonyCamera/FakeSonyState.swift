import Foundation
import SonyRemoteKit

/// 模拟 A7 IV 的 SDIO 行为：属性表、按键、取景帧、待传照片。
public final class FakeSonyState: @unchecked Sendable {
    private let lock = NSLock()
    private var props: [UInt16: SonyPropertyDesc] = [:]
    private(set) var controls: [(code: UInt16, value: UInt16)] = []
    private(set) var sets: [(code: UInt16, data: [UInt8])] = []
    private var s1 = false
    public var pendingFile: (name: String, data: Data)?
    public var twinList = true
    /// 模拟存储卡；为 nil 时不响应存储操作。
    public var card: FakeCard?
    /// 远程传输（0x923B–0x923E）能读到的卡槽；空表示相机不支持远程传输。
    public var remoteSlots: [UInt32: FakeCard] = [:]
    /// GetDeviceInfo 里列出的操作码；nil 时返回空数据（模拟老实现）。
    public var advertisedOperations: [UInt16]?
    /// GetDeviceInfo 里的型号和序列号。
    public var model = "ILCE-7M5"
    public var serialNumber = "00000000012345"
    /// 收到的 0x9212（内容传输模式）参数。
    public private(set) var contentsTransferModeParams: [[UInt32]] = []
    /// 为 true 时模拟真机：不进入内容传输模式就读不到存储卡（返回 StoreNotAvailable）。
    public var requireContentsTransferMode = false
    /// 远程传输下每次取文件数据前等这么久（秒），用来模拟慢速 Wi-Fi、测试导入中途断开。
    public var slowDownload: TimeInterval = 0
    /// 0x9210 收到的功能模式。
    public private(set) var sessionMode: UInt32?
    private var contentsOn = false
    private var clipCount = 0
    /// 自定义白平衡各槽位的结果（色温、G–M 原始值）。
    private var customWB: [Int64: (kelvin: Int64, gm: Int64)] = [0x8020: (7000, 188), 0x8021: (5500, 192), 0x8022: (5500, 192)]
    /// 最近一次取白命令带的位置。
    private var lastCustomWBPosition: UInt32?
    public var customWBPosition: UInt32? { lock.withLock { lastCustomWBPosition } }
    public func customWBResult(slot: Int) -> (kelvin: Int64, gm: Int64)? { lock.withLock { customWB[0x8020 + Int64(slot - 1)] } }
    private var customWBPolls = 0
    private var readyPolls = 0
    public let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 0xFF, 0xD9])
    /// 可替换成真实画面（命令行模拟器会生成真正的 JPEG）。
    public var liveViewProvider: (@Sendable () -> Data)?
    public var photoProvider: (@Sendable () -> Data)?
    /// 收到 PTP 操作时的日志回调。
    public var onOperation: (@Sendable (String) -> Void)?

    public init() {
        func p(_ code: UInt16, _ t: PTPDataType, _ v: Int64, _ list: [Int64]? = nil, writable: Bool = true) {
            props[code] = SonyPropertyDesc(code: code, dataType: t, getSet: writable ? 1 : 0, isEnabled: 1,
                                           factoryDefault: .int(v), current: .int(v),
                                           form: list.map { .enumeration($0) } ?? .none)
        }
        p(SonyProperty.shutterSpeed, .uint32, 0x0001_00FA, [0x0001_00FA, 0x0001_01F4, 0x0001_03E8, 0x0012_000A, 0])
        p(SonyProperty.fNumber, .uint16, 400, [280, 400, 560, 800, 1100])
        p(SonyProperty.iso, .uint32, 0x00FF_FFFF, [0x00FF_FFFF, 100, 200, 400, 0x01FF_FFFF])
        p(SonyProperty.exposureBias, .int16, 0, [-1000, -300, 0, 300, 700])
        p(SonyProperty.whiteBalance, .uint16, 0x0002, [0x0002, 0x0004, 0x8010, 0x8012, 0x8020, 0x8021, 0x8022])
        // 远程取白（和 α7 V 实测一致）：白平衡在自定义 1–3 时 0xD26D = 1；待机后 0xD270 = 1，取白时 = 2，完成后回到 0。
        p(0xD20F, .uint16, 0, writable: false)
        p(0xD210, .uint16, 192, writable: false)
        for c: UInt16 in [0xD26B, 0xD26C] { p(c, .uint32, 0, writable: false) }
        for c: UInt16 in [0xD26D, 0xD26E, 0xD26F, 0xD270] { p(c, .uint8, 0, writable: false) }
        // 和 α7 V 一样：照片 P/A/S/M/智能自动 + 录像 P/A/S/M/智能自动；相机优先时仅显示（见 setValue）。
        p(SonyProperty.exposureProgramMode, .uint32, 0x0000_0001,
          [0x48000, 0x10002, 0x20003, 0x30004, 0x1, 0x78054, 0x78050, 0x78051, 0x78052, 0x78053,
           0x9805D, 0x98059, 0x9805A, 0x9805B, 0x9805C])
        setEnabled(SonyProperty.exposureProgramMode, 2)
        p(SonyProperty.focusMode, .uint16, 2, writable: false)
        p(SonyProperty.focusFound, .uint8, 1, writable: false)
        p(SonyProperty.objectInMemory, .uint16, 0, writable: false)
        p(SonyProperty.movieRecordingState, .uint8, 0, writable: false)
        p(SonyProperty.stillImageStoreDestination, .uint16, 0x0010, [0x0001, 0x0010, 0x0011])
        p(SonyProperty.contentsTransferEnabled, .uint8, 0, writable: false)
        // 和 α7 V 一样默认「相机优先」；联机时改成 PC，结束时应改回。
        p(SonyProperty.priorityMode, .uint8, 0, [0, 1])
        props[SonyProperty.batteryLevel] = SonyPropertyDesc(code: SonyProperty.batteryLevel, dataType: .int8, getSet: 0, isEnabled: 1,
                                                            factoryDefault: .int(-1), current: .int(76),
                                                            form: .range(min: -1, max: 100, step: 1))
    }

    public func value(_ code: UInt16) -> Int64? { lock.withLock { props[code]?.intValue } }

    private func setValue(_ code: UInt16, _ v: Int64) {
        guard let p = props[code] else { return }
        props[code] = SonyPropertyDesc(code: p.code, dataType: p.dataType, getSet: p.getSet, isEnabled: p.isEnabled,
                                       factoryDefault: p.factoryDefault, current: .int(v), form: p.form)
        // PC 优先时曝光模式才能远程改。
        if code == SonyProperty.priorityMode { setEnabled(SonyProperty.exposureProgramMode, v == 1 ? 1 : 2) }
        if code == SonyProperty.whiteBalance {
            let custom = customWB[v]
            setValue(0xD26D, custom == nil ? 0 : 1)
            setValue(0xD20F, custom?.kelvin ?? 0)
            setValue(0xD210, custom?.gm ?? 192)
        }
    }

    /// 锁内读值（handle 已持有锁）。
    private func raw(_ code: UInt16) -> Int64? { props[code]?.intValue }

    private func setEnabled(_ code: UInt16, _ e: UInt8) {
        guard let p = props[code] else { return }
        props[code] = SonyPropertyDesc(code: p.code, dataType: p.dataType, getSet: p.getSet, isEnabled: e,
                                       factoryDefault: p.factoryDefault, current: p.current, form: p.form)
    }

    public var controlLog: [(code: UInt16, value: UInt16)] { lock.withLock { controls } }
    public var setLog: [(code: UInt16, data: [UInt8])] { lock.withLock { sets } }

    public func handle(_ code: UInt16, _ params: [UInt32], _ dataOut: Data?) -> FakeCamera.Reply {
        onOperation?(String(format: "op 0x%04X %@", code, params.map { String(format: "0x%X", $0) }.joined(separator: ",")))
        // 存储卡上的对象（不含取景、刚拍的照片这两个特殊句柄）交给 FakeCard。
        let storageOps: Set<UInt16> = [PTPOperation.getStorageIDs, PTPOperation.getStorageInfo, PTPOperation.getObjectHandles,
                                       PTPOperation.getObjectInfo, PTPOperation.getThumb, PTPOperation.getPartialObject,
                                       PTPOperation.getObject, SonyOperation.getPartialLargeObject]
        let remoteOps: Set<UInt16> = [SonyOperation.getCapturedDateList, SonyOperation.getContentsInfoList,
                                      SonyOperation.getContentsData, SonyOperation.getContentsCompressedData]
        if remoteOps.contains(code) {
            let slots = lock.withLock { remoteSlots }
            guard !slots.isEmpty else { return .init(code: PTPResponse.operationNotSupported) }
            let slot = code == SonyOperation.getCapturedDateList ? params.first ?? 0
                : code == SonyOperation.getContentsInfoList ? (params.count > 3 ? params[3] : 0)
                : (params.count > 1 ? params[1] >> 24 : 0)
            guard let c = slots[slot] else { return .init(code: 0x201D) }   // InvalidParameter：没有卡
            if code == SonyOperation.getContentsData, slowDownload > 0 { Thread.sleep(forTimeInterval: slowDownload) }
            return c.remoteTransfer(code, params) ?? .init(code: 0x201D)
        }
        if let card, storageOps.contains(code), params.first.map({ $0 < 0xFFFF_0000 }) ?? true {
            let allowed = lock.withLock { !requireContentsTransferMode || contentsOn }
            guard allowed else { return .init(code: PTPResponse.storeNotAvailable) }
            if let reply = card.handle(code, params) { return reply }
        }
        return lock.withLock {
            switch code {
            case SonyOperation.sdioOpenSession:
                sessionMode = params.count > 1 ? params[1] : nil
                return .init()
            case SonyOperation.setContentsTransferMode:
                contentsTransferModeParams.append(params)
                contentsOn = params.count > 1 && params[1] == 1 && sessionMode == 1
                readyPolls = 0
                if !contentsOn { setValue(SonyProperty.contentsTransferEnabled, 0) }
                return .init()
            case SonyOperation.getDeviceDescriptionFile:
                let xml = "<root><X_PTP_Information><X_PTP_MediaServerSupport>Enable</X_PTP_MediaServerSupport>" +
                    "<X_PTP_ContentsTransferSupport>Enable</X_PTP_ContentsTransferSupport></X_PTP_Information></root>"
                return .init(data: Data(xml.utf8))
            case PTPOperation.getDeviceInfo:
                guard let ops = advertisedOperations else { return .init() }
                var w = PTPWriter()
                w.u16(100); w.u32(0x11); w.u16(100); w.u8(0); w.u16(0)
                w.u32(UInt32(ops.count)); ops.forEach { w.u16($0) }
                for _ in 0..<4 { w.u32(0) }   // 事件、属性、拍摄格式、图像格式
                w.ptpString("Sony Corporation"); w.ptpString(model); w.ptpString("1.00"); w.ptpString(serialNumber)
                return .init(data: w.data)
            case PTPOperation.openSession, PTPOperation.closeSession:
                return .init()
            case SonyOperation.sdioConnect:
                return .init(data: Data(count: 8))
            case SonyOperation.getExtDeviceInfo:
                var w = PTPWriter()
                w.u16(SonyProtocolVersion.v300)
                let propCodes = Array(props.keys)
                w.u32(UInt32(propCodes.count)); propCodes.forEach { w.u16($0) }
                let ctl: [UInt16] = [SonyControl.shutterHalfPress, SonyControl.shutterFullPress, SonyControl.movieRecord]
                w.u32(UInt32(ctl.count)); ctl.forEach { w.u16($0) }
                return .init(data: w.data)
            case SonyOperation.getAllExtDevicePropInfo:
                // 进入传输模式后第 2 次轮询才报告就绪，用来测试等待逻辑。
                if contentsOn {
                    readyPolls += 1
                    if readyPolls >= 2 { setValue(SonyProperty.contentsTransferEnabled, 1) }
                }
                if raw(0xD270) == 2 {
                    customWBPolls += 1
                    if customWBPolls >= 3, let wb = raw(SonyProperty.whiteBalance) {
                        customWB[wb] = (6300, 188)
                        setValue(SonyProperty.whiteBalance, wb)
                        setValue(0xD270, 0)
                    }
                }
                let list = props.values.sorted { $0.code < $1.code }
                return .init(data: SonyDatasets.encodeAllProperties(list, twinList: twinList))
            case SonyOperation.setExtDevicePropValue:
                let c = UInt16(params.first ?? 0)
                let bytes = [UInt8](dataOut ?? Data())
                sets.append((c, bytes))
                guard let p = props[c] else { return .init() }  // 未知属性（如 PriorityMode）照样返回 OK
                guard p.getSet == 1, p.isEnabled == 1 else { return .init(code: PTPResponse.accessDenied) }
                var r = PTPReader(bytes)
                guard let v = try? PTPValue.read(p.dataType, from: &r).intValue else {
                    return .init(code: 0x201C)
                }
                if case .enumeration(let allowed) = p.form, !allowed.contains(v) { return .init(code: 0x201C) }
                setValue(c, v)
                return .init()
            case SonyOperation.controlDevice:
                let c = UInt16(params.first ?? 0)
                var r = PTPReader(dataOut ?? Data())
                let v = (try? r.u16()) ?? 0
                controls.append((c, v))
                switch (c, v) {
                case (SonyControl.shutterHalfPress, SonyControl.down):
                    s1 = true; setValue(SonyProperty.focusFound, 2)
                case (SonyControl.shutterHalfPress, SonyControl.up):
                    s1 = false; setValue(SonyProperty.focusFound, 1)
                case (SonyControl.shutterFullPress, SonyControl.up):
                    pendingFile = ("DSC01234.JPG", photoProvider?() ?? Data((0..<70_000).map { UInt8($0 % 251) }))
                    setValue(SonyProperty.objectInMemory, 0x8001)
                case (0xD2DF, SonyControl.up) where raw(0xD26D) == 1:
                    setValue(0xD270, 1); setValue(0xD26D, 0); setValue(0xD26E, 1); setValue(0xD26F, 1)
                case (0xD2E0, SonyControl.up) where raw(0xD270) == 1:
                    setValue(0xD270, 0); setValue(0xD26D, 1); setValue(0xD26E, 0); setValue(0xD26F, 0)
                case (0xD2E1, _):
                    guard raw(0xD270) == 1, let d = dataOut, d.count >= 4 else { return .init(code: PTPResponse.accessDenied) }
                    var r4 = PTPReader(d)
                    lastCustomWBPosition = try? r4.u32()
                    customWBPolls = 0
                    setValue(0xD270, 2); setValue(0xD26E, 0); setValue(0xD26F, 0)
                case (SonyControl.movieRecord, SonyControl.down):
                    setValue(SonyProperty.movieRecordingState, 1)
                case (SonyControl.movieRecord, SonyControl.up):
                    setValue(SonyProperty.movieRecordingState, 0)
                    // 和真机一样：停止后卡上多一个片段（MP4 末尾内嵌 M01 XML）。
                    if let card = remoteSlots[1] {
                        clipCount += 1
                        let name = String(format: "C%04d", 100 + clipCount)
                        let xml = Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<NonRealTimeMeta xmlns=\"urn:schemas-professionalDisc:nonRealTimeMeta:ver.2.20\"><Duration value=\"25\"/><VideoFormat><VideoFrame videoCodec=\"HEVC\" captureFps=\"25p\" formatFps=\"25p\"/></VideoFormat></NonRealTimeMeta>\n".utf8)
                        let f = FakeCard.Formatter.clipDate(clipCount)
                        _ = card.add(PTPObjectInfo(format: PTPObjectFormat.mp4, size: 0, parent: 0, filename: name + ".MP4",
                                                   captureDate: f, imageWidth: 3840, imageHeight: 2160),
                                     data: Data(repeating: 0x43, count: 200_000) + xml)
                    }
                default: break
                }
                return .init()
            case PTPOperation.getObjectInfo:
                if params.first == SonyObjectHandle.liveView { return .init(data: Data(count: 64)) }
                guard let f = pendingFile else { return .init(code: PTPResponse.invalidObjectHandle) }
                return .init(data: PTPObjectInfo(format: PTPObjectFormat.jpeg, size: UInt32(f.data.count), parent: 0, filename: f.name).encoded())
            case PTPOperation.getObject:
                if params.first == SonyObjectHandle.liveView {
                    // 头部 u32 偏移、u32 长度，并在头部里故意放一个假的 FF D8。
                    var w = PTPWriter()
                    let frame = liveViewProvider?() ?? jpeg
                    w.u32(32); w.u32(UInt32(frame.count))
                    w.raw([0xFF, 0xD8]); w.raw([UInt8](repeating: 0, count: 22))
                    w.raw(frame)
                    return .init(data: w.data)
                }
                guard let f = pendingFile else { return .init(code: PTPResponse.invalidObjectHandle) }
                pendingFile = nil
                setValue(SonyProperty.objectInMemory, 0)
                return .init(data: f.data)
            default:
                return .init(code: PTPResponse.operationNotSupported)
            }
        }
    }
}
