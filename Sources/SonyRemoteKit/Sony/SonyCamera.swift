import Foundation

/// 设置任意属性时的错误，原因分得细一些，方便调用方（命令行、agent）判断该怎么办。
public enum SonyPropertyError: Error, LocalizedError, Sendable, Equatable {
    case unknown(UInt16)
    case readOnly(UInt16)
    case notEnabled(UInt16, displayOnly: Bool)
    case invalidValue(UInt16, allowed: [Int64])
    case outOfRange(UInt16, min: Int64, max: Int64, step: Int64)
    case rejected(UInt16, response: UInt16)
    case readbackMismatch(UInt16, requested: PTPValue, actual: PTPValue)

    public var code: String {
        switch self {
        case .unknown: "unknown_property"
        case .readOnly, .notEnabled: "not_writable"
        case .invalidValue, .outOfRange: "invalid_value"
        case .rejected(_, let r): r == PTPResponse.deviceBusy ? "camera_busy" : "rejected"
        case .readbackMismatch: "readback_mismatch"
        }
    }

    public var errorDescription: String? {
        func n(_ c: UInt16) -> String { SonyPropertyCatalog.name(c).map { "\($0)（\(String(format: "0x%04X", c))）" } ?? String(format: "0x%04X", c) }
        func v(_ c: UInt16, _ x: Int64) -> String { SonyPropertyCatalog.label(c, x) ?? "\(x)" }
        switch self {
        case .unknown(let c): return "相机没有报告属性 \(n(c))。"
        case .readOnly(let c): return "\(n(c)) 是只读属性。"
        case .notEnabled(let c, let display):
            return display ? "\(n(c)) 当前仅显示、不能改（通常是被拍摄模式、拨盘或其他设置锁定）。" : "\(n(c)) 在当前设置下未启用。"
        case .invalidValue(let c, let allowed):
            return "\(n(c)) 不接受这个值。可选：" + allowed.prefix(60).map { v(c, $0) }.joined(separator: "、")
        case let .outOfRange(c, lo, hi, step): return "\(n(c)) 的取值范围是 \(v(c, lo))–\(v(c, hi))，步进 \(step)。"
        case let .rejected(c, r):
            return r == PTPResponse.deviceBusy ? "相机忙，没有接受 \(n(c)) 的设置。" : "相机拒绝设置 \(n(c))（响应 \(String(format: "0x%04X", r))）。"
        case let .readbackMismatch(c, req, act):
            func s(_ p: PTPValue) -> String { if case .int(let x) = p { v(c, x) } else { p.description } }
            return "设置 \(n(c)) 为 \(s(req)) 后读回的是 \(s(act))，相机没有采用这个值。"
        }
    }
}

public enum SonyCameraError: Error, LocalizedError, Sendable {
    case notSonyRemoteCapable
    case settingUnavailable(CameraSettingKind)
    case downloadTimeout

    public var errorDescription: String? {
        switch self {
        case .notSonyRemoteCapable: "相机没有响应索尼遥控协议。请确认相机已开启「遥控拍摄」。"
        case .settingUnavailable(let k): "当前模式下无法调整\(k.title)。"
        case .downloadTimeout: "等待相机传输照片超时。"
        }
    }
}

/// 通过 PTP/IP + 索尼 SDIO 扩展遥控 α 系列相机。
public actor SonyCamera: RemoteCamera {
    private let client: PTPIPClient
    private let cameraName: String
    private var protocolVersion: UInt16 = SonyProtocolVersion.v300
    private var supportedCodes: Set<UInt16> = []
    private var props: [UInt16: SonyPropertyDesc] = [:]
    private var propsFetchedAt: Date = .distantPast
    private var connectedAt = Date()
    private var halfPressed = false
    private var liveViewPrepared = false
    private var eventTask: Task<Void, Never>?

    public nonisolated let notifications: AsyncStream<CameraNotification>
    private let notify: AsyncStream<CameraNotification>.Continuation

    /// 连接后约 3 秒才能首次拍摄（libgphoto2 对 A7 IV 等机型的经验值）。
    private let startupDelay: TimeInterval

    private init(client: PTPIPClient, name: String, startupDelay: TimeInterval) {
        self.client = client
        self.startupDelay = startupDelay
        self.cameraName = name
        (notifications, notify) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(32))
    }

    public var displayName: String { cameraName.isEmpty ? "Sony 相机" : cameraName }
    public var isProtocolV3: Bool { protocolVersion >= SonyProtocolVersion.v300 }

    // MARK: 连接

    public static func connect(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity,
                               tunnel: CameraSSHTunnel? = nil,
                               startupDelay: TimeInterval = 3,
                               progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SonyCamera {
        let client = PTPIPClient(host: host, port: port, identity: identity, tunnel: tunnel)
        progress(tunnel == nil ? "正在建立 PTP/IP 连接…" : "正在通过加密通道建立 PTP/IP 连接…")
        try await client.connect()
        do {
            let cam = SonyCamera(client: client, name: await client.cameraName, startupDelay: startupDelay)
            try await cam.handshake(progress: progress)
            return cam
        } catch {
            await client.disconnect()
            throw error
        }
    }

    private func handshake(progress: @Sendable (String) -> Void) async throws {
        progress("正在打开会话…")
        try await SonySDIO.openSession(client, mode: nil)

        progress("正在进行索尼 SDIO 握手…")
        let info = try await SonySDIO.handshake(client)
        protocolVersion = info.version
        supportedCodes = info.codes

        // 让 APP 优先控制（失败不影响后续）。
        _ = try? await sendSet(SonyProperty.priorityMode, .int(1), type: .uint8)

        progress("正在读取相机设置…")
        try await refreshProperties(force: true)

        // 照片若只存卡，就不会传给手机；改成「卡 + 主机」。
        if let dest = props[SonyProperty.stillImageStoreDestination], dest.isWritable,
           let v = dest.intValue, v == 0x0010, dest.allowedValues.contains(0x0011) {
            _ = try? await sendSet(SonyProperty.stillImageStoreDestination, .int(0x0011), type: dest.dataType)
        }

        connectedAt = Date()
        startEventLoop()
    }

    private func startEventLoop() {
        let events = client.events
        let notify = self.notify
        eventTask = Task {
            for await e in events {
                switch e.code {
                case SonyEvent.objectAdded, PTPEventCode.objectAdded:
                    notify.yield(.fileAvailable)
                case SonyEvent.propertyChanged, PTPEventCode.devicePropChanged:
                    notify.yield(.statusChanged)
                default:
                    break
                }
            }
            notify.yield(.disconnected)
            notify.finish()
        }
    }

    public func disconnect() async {
        eventTask?.cancel()
        if halfPressed { _ = try? await control(SonyControl.shutterHalfPress, SonyControl.up) }
        await client.shutdown()
        notify.finish()
    }

    // MARK: 属性

    private func refreshProperties(force: Bool = false) async throws {
        if !force && Date().timeIntervalSince(propsFetchedAt) < 0.25 { return }
        let r = try await client.transaction(SonyOperation.getAllExtDevicePropInfo)
        let parsed = SonyDatasets.parseAllProperties(r.data)
        if !parsed.isEmpty {
            props.merge(parsed) { _, new in new }
        }
        propsFetchedAt = Date()
    }

    /// 当前用于曝光补偿的属性码：优先标准 0x5010，否则用索尼 0xD224。
    private var exposureBiasCode: UInt16 {
        props[SonyProperty.exposureBias] != nil ? SonyProperty.exposureBias : SonyProperty.exposureCompensation
    }

    private func code(for kind: CameraSettingKind) -> UInt16 {
        switch kind {
        case .shutterSpeed: SonyProperty.shutterSpeed
        case .aperture: SonyProperty.fNumber
        case .iso: SonyProperty.iso
        case .exposureCompensation: exposureBiasCode
        case .whiteBalance: SonyProperty.whiteBalance
        }
    }

    public func refreshStatus() async throws -> CameraStatus {
        try await refreshProperties()
        return status()
    }

    func status() -> CameraStatus {
        let settings: [CameraSetting] = CameraSettingKind.allCases.compactMap { kind in
            guard let p = props[code(for: kind)] else { return nil }
            let options = p.allowedValues.map { SettingOption(value: $0, label: SonyFormat.format(kind, $0)) }
            let text = p.intValue.map { SonyFormat.format(kind, $0) } ?? "--"
            return CameraSetting(kind: kind, currentValue: p.intValue, valueText: text,
                                 options: options, isEditable: p.isWritable && !options.isEmpty)
        }
        let mode = props[SonyProperty.exposureProgramMode]?.intValue.map(SonyFormat.exposureProgram) ?? ""
        var battery: String?
        if let b = props[SonyProperty.batteryLevel]?.intValue, b >= 0 { battery = "\(b)%" }
        let recording = props[SonyProperty.movieRecordingState]?.intValue == 1
        let focus = props[SonyProperty.focusFound]?.intValue
        return CameraStatus(settings: settings, modeText: mode, batteryText: battery,
                            isRecording: recording, isFocused: focus == 2 || focus == 3,
                            pendingTransfers: pendingCount)
    }

    /// 0xD215 ≥ 0x8000 表示有照片在等待传输，低位是数量。
    private var pendingCount: Int {
        guard let v = props[SonyProperty.objectInMemory]?.intValue, v >= 0x8000 else { return 0 }
        return max(1, Int(v & 0x7FFF))
    }

    public func set(_ kind: CameraSettingKind, value: Int64) async throws {
        let c = code(for: kind)
        guard let p = props[c], p.isWritable else { throw SonyCameraError.settingUnavailable(kind) }
        if isProtocolV3 {
            do {
                try await sendSet(c, .int(value), type: p.dataType)
            } catch let e as PTPError where c == SonyProperty.fNumber {
                // libgphoto2 以 UINT32 发送光圈值；按描述类型失败时再试一次。
                _ = e
                try await sendSet(c, .int(value), type: .uint32)
            }
        } else {
            try await stepTowards(kind, code: c, target: value)
        }
        propsFetchedAt = .distantPast
    }

    public func step(_ kind: CameraSettingKind, by delta: Int) async throws {
        let c = code(for: kind)
        guard let p = props[c], p.isWritable else { throw SonyCameraError.settingUnavailable(kind) }
        if isProtocolV3 {
            let values = p.allowedValues
            guard !values.isEmpty else { throw SonyCameraError.settingUnavailable(kind) }
            let idx = p.intValue.flatMap { values.firstIndex(of: $0) } ?? 0
            let next = max(0, min(values.count - 1, idx + delta))
            guard next != idx else { return }
            try await set(kind, value: values[next])
        } else {
            try await sendStep(c, delta)
            propsFetchedAt = .distantPast
        }
    }

    /// 协议 2.00：0x9207 + UINT8 档位（0x01 = +1，0xFF = −1），直到读到目标值。
    private func stepTowards(_ kind: CameraSettingKind, code c: UInt16, target: Int64) async throws {
        for _ in 0..<40 {
            try await refreshProperties(force: true)
            guard let p = props[c], let cur = p.intValue else { return }
            if cur == target { return }
            let values = p.allowedValues
            guard let ci = values.firstIndex(of: cur), let ti = values.firstIndex(of: target) else { return }
            try await sendStep(c, ti > ci ? 1 : -1)
            try await Task.sleep(for: .milliseconds(200))
        }
    }

    private func sendStep(_ c: UInt16, _ delta: Int) async throws {
        var w = PTPWriter()
        w.u8(UInt8(bitPattern: Int8(clamping: delta)))
        try await client.transaction(SonyOperation.controlDevice, [UInt32(c)], dataOut: w.data)
    }

    private func sendSet(_ c: UInt16, _ value: PTPValue, type: PTPDataType) async throws {
        var w = PTPWriter()
        value.write(type, to: &w)
        try await client.transaction(SonyOperation.setExtDevicePropValue, [UInt32(c)], dataOut: w.data)
    }

    private func control(_ c: UInt16, _ value: UInt16) async throws {
        var w = PTPWriter()
        w.u16(value)
        try await client.transaction(SonyOperation.controlDevice, [UInt32(c)], dataOut: w.data)
    }

    // MARK: 任意属性（联机拍摄的 agent 接口用）

    /// 相机报告的全部属性（按编号排序）。
    public func allProperties(refresh: Bool = true) async throws -> [SonyPropertyDesc] {
        if refresh { try await refreshProperties(force: true) }
        return props.values.sorted { $0.code < $1.code }
    }

    /// 设置一个属性并回读确认：在 timeout 内读回的值等于请求值才算成功。
    /// 设置前先检查是否可写、取值是否在可选范围内，失败时给出具体原因。
    @discardableResult
    public func setVerified(_ code: UInt16, _ value: PTPValue, timeout: TimeInterval = 3) async throws -> SonyPropertyDesc {
        try await refreshProperties(force: true)
        guard let p = props[code] else { throw SonyPropertyError.unknown(code) }
        guard p.getSet == 1 else { throw SonyPropertyError.readOnly(code) }
        guard p.isEnabled == 1 else { throw SonyPropertyError.notEnabled(code, displayOnly: p.isEnabled == 2) }
        if case .int(let v) = value {
            switch p.form {
            case .enumeration(let list) where !list.isEmpty && !list.contains(v):
                throw SonyPropertyError.invalidValue(code, allowed: list)
            case let .range(lo, hi, step) where v < lo || v > hi || (step > 1 && (v - lo) % step != 0):
                throw SonyPropertyError.outOfRange(code, min: lo, max: hi, step: step)
            default: break
            }
        }
        if p.current == value { return p }
        do {
            try await sendSet(code, value, type: p.dataType)
        } catch let e as PTPError {
            throw SonyPropertyError.rejected(code, response: e.code)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var last = p
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            try await refreshProperties(force: true)
            if let now = props[code] {
                last = now
                if now.current == value { return now }
            }
        }
        throw SonyPropertyError.readbackMismatch(code, requested: value, actual: last.current)
    }

    // MARK: 存储卡内容（远程传输，和遥控共用这条连接）

    private var contents: SonyRemoteTransferLibrary?

    /// 用远程传输（0x923B–0x923E）读存储卡：遥控会话里也能用，不用切换模式。每次调用都会让列表重新读取。
    public func contentLibrary() async throws -> SonyRemoteTransferLibrary {
        if let c = contents { await c.refresh(); return c }
        var available: [UInt32] = []
        var failures: [String] = []
        for slot: UInt32 in [1, 2] {
            let r = try await client.transaction(SonyOperation.getCapturedDateList, [slot], requireOK: false)
            if r.code == PTPResponse.ok { available.append(slot) }
            else { failures.append("卡槽 \(slot)：\(PTPError(operation: SonyOperation.getCapturedDateList, code: r.code).localizedDescription)") }
        }
        guard !available.isEmpty else { throw SonyRemoteTransferError.cardsUnavailable(failures.joined(separator: "；")) }
        let lib = SonyRemoteTransferLibrary(client: client, slots: available, notes: [], deviceInfo: nil)
        contents = lib
        return lib
    }

    // MARK: 拍摄

    private func waitForStartup() async throws {
        let elapsed = Date().timeIntervalSince(connectedAt)
        if elapsed < startupDelay {
            try await Task.sleep(for: .seconds(startupDelay - elapsed))
        }
    }

    public func halfPress(_ down: Bool) async throws {
        guard down != halfPressed else { return }
        try await control(SonyControl.shutterHalfPress, down ? SonyControl.down : SonyControl.up)
        halfPressed = down
        propsFetchedAt = .distantPast
    }

    public func capture() async throws {
        try await waitForStartup()
        if !halfPressed {
            try await control(SonyControl.shutterHalfPress, SonyControl.down)
            halfPressed = true
        }
        do {
            try await control(SonyControl.shutterFullPress, SonyControl.down)
            // 非手动对焦时最多等 1 秒合焦。
            let manualFocus = props[SonyProperty.focusMode]?.intValue == 1
            if !manualFocus {
                let deadline = Date().addingTimeInterval(1)
                while Date() < deadline {
                    try await refreshProperties(force: true)
                    let f = props[SonyProperty.focusFound]?.intValue
                    if f == 2 || f == 3 || pendingCount > 0 { break }
                    try await Task.sleep(for: .milliseconds(80))
                }
            } else {
                try await Task.sleep(for: .milliseconds(100))
            }
        } catch {
            _ = try? await control(SonyControl.shutterFullPress, SonyControl.up)
            _ = try? await control(SonyControl.shutterHalfPress, SonyControl.up)
            halfPressed = false
            throw error
        }
        try await control(SonyControl.shutterFullPress, SonyControl.up)
        try await control(SonyControl.shutterHalfPress, SonyControl.up)
        halfPressed = false
        propsFetchedAt = .distantPast
    }

    public func setRecording(_ on: Bool) async throws {
        try await control(SonyControl.movieRecord, on ? SonyControl.down : SonyControl.up)
        propsFetchedAt = .distantPast
    }

    // MARK: 取景与下载

    public func liveViewFrame() async throws -> Data? {
        if !liveViewPrepared {
            liveViewPrepared = true
            _ = try? await client.transaction(PTPOperation.getObjectInfo, [SonyObjectHandle.liveView], requireOK: false)
        }
        let r = try await client.transaction(PTPOperation.getObject, [SonyObjectHandle.liveView], requireOK: false)
        switch r.code {
        case PTPResponse.ok:
            return SonyDatasets.extractLiveViewJPEG(r.data)
        case PTPResponse.accessDenied, PTPResponse.deviceBusy:
            // 请求太快时相机会拒绝，稍等再取。
            try await Task.sleep(for: .milliseconds(20))
            return nil
        case PTPResponse.invalidObjectHandle:
            // 不在拍摄模式（例如正在回放），没有取景画面。
            try await Task.sleep(for: .milliseconds(300))
            return nil
        default:
            throw PTPError(operation: PTPOperation.getObject, code: r.code)
        }
    }

    public func downloadPendingFiles() async throws -> [CapturedFile] {
        var files: [CapturedFile] = []
        let start = Date()
        while files.count < 50 {
            try await refreshProperties(force: true)
            if pendingCount == 0 {
                // 已经下完，或 2 秒内都没有待传文件（事件可能不是新照片）就结束。
                if !files.isEmpty || Date().timeIntervalSince(start) > 2 { break }
                try await Task.sleep(for: .milliseconds(200))
                continue
            }
            let handle = SonyObjectHandle.capturedImage
            let infoData = try await client.transaction(PTPOperation.getObjectInfo, [handle]).data
            let info = try PTPObjectInfo.parse(infoData)
            let data = try await client.transaction(PTPOperation.getObject, [handle]).data
            let name = info.filename.isEmpty ? String(format: "SONY%05d.JPG", Int(Date().timeIntervalSince1970) % 100_000) : info.filename
            files.append(CapturedFile(filename: name, data: data))
        }
        return files
    }
}
