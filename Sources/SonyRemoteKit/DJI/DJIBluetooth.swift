import CoreBluetooth
import Foundation

/// 大疆 Osmo 相机的蓝牙控制通道：找相机、配对、唤醒、拿到相机热点的名称和密码，并在整个会话期间保活。
/// 流程来自 osmosis 的 MEDIA_PROTOCOL.md §21–26 和 OsmoOffload 的 ble/（MIT），见 THIRD_PARTY_NOTICES.md。
///
/// GATT 要求（缺一步相机就只确认写入、不回任何东西）：两个特征 fff4、fff5 都打开通知；
/// 在任何 fff5 写入之前，给 fff4 的值（不是描述符）写 `01 00`（要回执），再等约 200 毫秒；
/// fff5 只能无回执写入，相邻两次写入要隔开。
public final class DJIBluetooth: NSObject, @unchecked Sendable {
    public struct Found: Sendable, Identifiable, Hashable {
        public let id: UUID
        public let name: String
        public let model: String
        public let rssi: Int
    }

    public struct Credentials: Sendable {
        public let ssid: String
        public let password: String
        public let alreadyPaired: Bool
    }

    public enum Failure: LocalizedError {
        case bluetoothOff, unauthorized, notFound, connect(String), gatt, timeout(String), approval
        public var errorDescription: String? {
            switch self {
            case .bluetoothOff: String(localized: "蓝牙未打开。", bundle: .miniDiT)
            case .unauthorized: String(localized: "MiniDiT 没有蓝牙权限。请在“系统设置 › 隐私与安全性 › 蓝牙”中允许 MiniDiT。", bundle: .miniDiT)
            case .notFound: String(localized: "未找到大疆相机。请确认相机已开机、在附近，且没有连着 DJI Mimo。", bundle: .miniDiT)
            case .connect(let s): String(localized: "无法通过蓝牙连接相机：\(s)", bundle: .miniDiT)
            case .gatt: String(localized: "相机的蓝牙服务不完整，无法控制。", bundle: .miniDiT)
            case .timeout(let what): String(localized: "相机没有回应（\(what)）。", bundle: .miniDiT)
            case .approval: String(localized: "相机上没有确认连接。请在相机屏幕上点“允许”后重试。", bundle: .miniDiT)
            }
        }
    }

    nonisolated(unsafe) static let service = CBUUID(string: "FFF0")
    nonisolated(unsafe) static let notifyChar = CBUUID(string: "FFF4")
    nonisolated(unsafe) static let writeChar = CBUUID(string: "FFF5")
    /// 大疆在广播厂商数据里的公司 ID（小端 AA 08）。
    static let companyIDs: Set<UInt16> = [0x08AA, 0xAAF7]
    static let models: [UInt8: String] = [0x14: "Osmo Action 4", 0x15: "Osmo Action 5 Pro", 0x18: "Osmo Action 6",
                                          0x19: "Osmo Nano", 0x20: "Osmo Pocket 3", 0x21: "Osmo Pocket 4", 0x22: "Osmo Pocket 4 Pro"]
    static let namePrefixes = ["OsmoPocket", "OsmoAction", "OsmoNano", "Osmo360", "XtraEdge", "Osmo"]

    private let queue = DispatchQueue(label: "MiniDiT.DJIBluetooth")
    private var central: CBCentralManager!
    private var poweredWaiters: [CheckedContinuation<Void, Error>] = []
    private var found: [UUID: (CBPeripheral, Found)] = [:]
    private var peripheral: CBPeripheral?
    private var fff4: CBCharacteristic?
    private var fff5: CBCharacteristic?
    private var connectWaiter: CheckedContinuation<Void, Error>?
    /// 第几次连接；超时的定时块靠它认出自己那一次是不是还在等。
    private var connectAttempt = 0
    private var armWaiter: CheckedContinuation<Void, Error>?
    private var notifying = Set<CBUUID>()
    private var parsers: [CBUUID: DUMLStreamParser] = [:]
    private var waiters: [(id: UUID, match: @Sendable (DUMLFrame) -> Bool, cont: CheckedContinuation<DUMLFrame, Error>)] = []
    private var lastWrite = Date.distantPast
    private var nextID: UInt16 = 0x2000
    private var keepaliveTimer: DispatchSourceTimer?
    private let log: @Sendable (String) -> Void
    /// 蓝牙连接断开时调用（在内部队列上）。
    public var onDisconnect: (@Sendable () -> Void)?

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: 公开接口

    /// 搜索附近的大疆相机，信号强的在前。找到一台后再多听一会儿，最多 `timeout` 秒。
    public func scan(timeout: TimeInterval = 8) async throws -> [Found] {
        try await poweredOn()
        queue.sync { found = [:]; central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]) }
        let start = Date()
        var firstSeen: Date?
        while Date().timeIntervalSince(start) < timeout {
            try await Task.sleep(for: .milliseconds(250))
            let n = queue.sync { found.count }
            if n > 0, firstSeen == nil { firstSeen = Date() }
            if let firstSeen, Date().timeIntervalSince(firstSeen) > 2 { break }
        }
        return queue.sync {
            central.stopScan()
            return found.values.map(\.1).sorted { $0.rssi > $1.rssi }
        }
    }

    /// 连上相机，打开两个通知，写入 `01 00`。
    public func connect(_ camera: Found) async throws {
        try await poweredOn()
        let target = camera.id
        // 超时在蓝牙队列上自己掐：CoreBluetooth 的连接不会自己超时，等待它的续体也不响应取消。
        let what = String(localized: "蓝牙连接", bundle: .miniDiT)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.queue.async {
                guard let p = self.found[target]?.0 ?? self.central.retrievePeripherals(withIdentifiers: [target]).first else {
                    c.resume(throwing: Failure.notFound); return
                }
                self.connectAttempt += 1
                let attempt = self.connectAttempt
                self.peripheral = p
                p.delegate = self
                self.connectWaiter = c
                self.central.connect(p)
                self.queue.asyncAfter(deadline: .now() + 20) {
                    guard self.connectAttempt == attempt, let waiter = self.connectWaiter else { return }
                    self.connectWaiter = nil
                    // 先清掉 peripheral，取消连接引出的「连接断开」回调才不会被当成掉线上报。
                    let pending = self.peripheral
                    self.peripheral = nil; self.fff4 = nil; self.fff5 = nil; self.notifying = []
                    if let pending { self.central.cancelPeripheralConnection(pending) }
                    waiter.resume(throwing: Failure.timeout(what))
                }
            }
        }
        try await Task.sleep(for: .milliseconds(250))
        log("大疆蓝牙：已连接 \(camera.name)")
    }

    /// 配对并拿到热点的名称和密码。第一次连接时相机屏幕上会出现确认框，`approvalNeeded` 在那时被调用。
    public func pair(identifier: String, approvalNeeded: @escaping @Sendable () -> Void) async throws -> Credentials {
        try await send(DJIBLECommand.sessionOpen(id()))
        try await Task.sleep(for: .milliseconds(200))
        // 先挂上等待：用户点允许后相机马上发来 0x07/0x46 请求。
        let approval = Task { try await self.waitFor(timeout: 120) { $0.matches(0x07, 0x46) && $0.isRequest } }
        let reply = try await requestRetry { DJIBLECommand.pair($0, identifier: identifier) }
        let already = reply.payload.count >= 2 && reply.payload[1] == 0x01
        if already {
            approval.cancel()
        } else {
            log("大疆蓝牙：等待在相机上确认连接")
            approvalNeeded()
            guard let req = try? await approval.value else { throw Failure.approval }
            try await send(DJIBLECommand.pairApprovedAck(req.messageID))
        }
        startKeepalive()
        // Pocket 3 对唤醒回 e0，但照样醒；没回复也不算错。
        _ = try? await request(DJIBLECommand.wake(id()), timeout: 2.5)
        try await Task.sleep(for: .milliseconds(500))
        guard let ssid = DJIBLECommand.packedString(try await requestRetry(DJIBLECommand.wifiSSID).payload), !ssid.isEmpty else {
            throw Failure.timeout(String(localized: "读取 Wi-Fi 名称", bundle: .miniDiT))
        }
        try await Task.sleep(for: .milliseconds(500))
        let password = DJIBLECommand.packedString(try await requestRetry(DJIBLECommand.wifiPassword).payload) ?? ""
        log("大疆蓝牙：相机热点 \(ssid)" + (already ? "（之前已配对）" : "（刚刚配对）"))
        return Credentials(ssid: ssid, password: password, alreadyPaired: already)
    }

    /// 热点迟迟不出现时，把相机自己的热点信息发回去催一下（官方 App 不发这条，只作后备）。
    public func nudgeWiFi(_ c: Credentials) async {
        _ = try? await request(DJIBLECommand.connectWiFi(id(), ssid: c.ssid, password: c.password), timeout: 3)
    }

    public func disconnect() {
        queue.sync {
            keepaliveTimer?.cancel(); keepaliveTimer = nil
            if let p = peripheral { central.cancelPeripheralConnection(p) }
            peripheral = nil; fff4 = nil; fff5 = nil; notifying = []
            for w in waiters { w.cont.resume(throwing: CancellationError()) }
            waiters = []
        }
    }

    // MARK: 收发

    private func id() -> UInt16 { queue.sync { nextID = nextID >= 0xFFF0 ? 0x2000 : nextID + 1; return nextID } }

    private func send(_ frame: DUMLFrame) async throws {
        let gap = queue.sync { 0.1 - Date().timeIntervalSince(lastWrite) }
        if gap > 0 { try await Task.sleep(for: .milliseconds(Int(gap * 1000))) }
        try queue.sync {
            guard let p = peripheral, let c = fff5 else { throw Failure.gatt }
            p.writeValue(Data(frame.encoded()), for: c, type: .withoutResponse)
            lastWrite = Date()
        }
    }

    private func waitFor(timeout: TimeInterval, _ match: @escaping @Sendable (DUMLFrame) -> Bool) async throws -> DUMLFrame {
        let key = UUID()
        return try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: DUMLFrame.self) { group in
                group.addTask {
                    try await withCheckedThrowingContinuation { c in
                        self.queue.async { self.waiters.append((key, match, c)) }
                    }
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(timeout))
                    throw Failure.timeout(String(localized: "蓝牙", bundle: .miniDiT))
                }
                defer {
                    group.cancelAll()
                    queue.async {
                        if let i = self.waiters.firstIndex(where: { $0.id == key }) {
                            self.waiters.remove(at: i).cont.resume(throwing: CancellationError())
                        }
                    }
                }
                return try await group.next()!
            }
        } onCancel: {
            queue.async {
                if let i = self.waiters.firstIndex(where: { $0.id == key }) { self.waiters.remove(at: i).cont.resume(throwing: CancellationError()) }
            }
        }
    }

    private func request(_ frame: DUMLFrame, timeout: TimeInterval = 3) async throws -> DUMLFrame {
        let set = frame.commandSet, cmd = frame.commandID
        async let reply = waitFor(timeout: timeout) { $0.matches(set, cmd) && !$0.isRequest }
        try await Task.sleep(for: .milliseconds(10))
        try await send(frame)
        return try await reply
    }

    /// fff5 无回执写入，第一次可能丢：内容不变、换个消息 ID 重发。
    private func requestRetry(_ build: @Sendable (UInt16) -> DUMLFrame, attempts: Int = 3) async throws -> DUMLFrame {
        var last: Error = Failure.timeout(String(localized: "蓝牙", bundle: .miniDiT))
        for _ in 0..<attempts {
            do { return try await request(build(id())) } catch { last = error }
        }
        throw last
    }

    private func startKeepalive() {
        queue.sync {
            keepaliveTimer?.cancel()
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1)
            t.setEventHandler { [weak self] in
                guard let self, let p = self.peripheral, let c = self.fff5 else { return }
                self.nextID = self.nextID >= 0xFFF0 ? 0x2000 : self.nextID + 1
                p.writeValue(Data(DJIBLECommand.keepalive(self.nextID).encoded()), for: c, type: .withoutResponse)
                self.lastWrite = Date()
            }
            t.resume()
            keepaliveTimer = t
        }
    }

    private func poweredOn() async throws {
        let what = String(localized: "蓝牙", bundle: .miniDiT)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            self.queue.async {
                switch self.central.state {
                case .poweredOn: c.resume()
                case .unauthorized: c.resume(throwing: Failure.unauthorized)
                case .poweredOff, .unsupported: c.resume(throwing: Failure.bluetoothOff)
                default:
                    self.poweredWaiters.append(c)
                    // 5 秒还没等到蓝牙状态就放弃；到时还在等的一起结束。
                    self.queue.asyncAfter(deadline: .now() + 5) {
                        let waiting = self.poweredWaiters
                        self.poweredWaiters = []
                        waiting.forEach { $0.resume(throwing: Failure.timeout(what)) }
                    }
                }
            }
        }
    }

    /// 新格式广播（Pocket 4 Pro）里的产品类型：在厂商数据（去掉 2 字节公司 ID 后）第 10–11 字节，
    /// 旧格式的机型字节此时是 0。
    static let productTypes: [UInt16: String] = [218: "Osmo Pocket 4 Pro"]
    /// 广播里没有厂商数据时（广播和扫描回应分两次到）按蓝牙名称认，长的前缀在前：「OsmoPocket4P」要先于「OsmoPocket4」。
    static let nameModels: [(String, String)] = [("OsmoPocket4P", "Osmo Pocket 4 Pro"), ("OsmoPocket4", "Osmo Pocket 4"),
                                                ("OsmoPocket3", "Osmo Pocket 3"), ("OsmoNano", "Osmo Nano"),
                                                ("OsmoAction6", "Osmo Action 6"), ("OsmoAction5Pro", "Osmo Action 5 Pro"),
                                                ("OsmoAction4", "Osmo Action 4"), ("XtraEdgePro", "Xtra Edge Pro")]

    /// 认不出机型、广播里也没有名字时的显示名。只在本次扫描内比较，不保存。
    static var unknownModel: String { String(localized: "大疆相机", bundle: .miniDiT) }

    /// 认出大疆相机和机型。`resolved` = 机型是认出来的，不是只拿蓝牙名称或“大疆相机”顶替。
    static func model(manufacturerData data: Data?, name: String) -> (name: String, resolved: Bool)? {
        var isDJI = false
        if let d = data.map(Array.init), d.count >= 3 {
            let company = UInt16(d[0]) | UInt16(d[1]) << 8
            if companyIDs.contains(company) {
                isDJI = true
                if d.count >= 14, let m = productTypes[UInt16(d[12]) | UInt16(d[13]) << 8] { return (m, true) }
                if let m = models[d[2]] { return (m, true) }
            }
        }
        if let m = nameModels.first(where: { name.hasPrefix($0.0) })?.1 { return (m, true) }
        if isDJI || namePrefixes.contains(where: { name.hasPrefix($0) }) { return (name.isEmpty ? unknownModel : name, false) }
        return nil
    }
}

extension DJIBluetooth: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let ws = poweredWaiters
        switch central.state {
        case .poweredOn: poweredWaiters = []; ws.forEach { $0.resume() }
        case .unauthorized: poweredWaiters = []; ws.forEach { $0.resume(throwing: Failure.unauthorized) }
        case .poweredOff, .unsupported: poweredWaiters = []; ws.forEach { $0.resume(throwing: Failure.bluetoothOff) }
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard let (model, resolved) = Self.model(manufacturerData: advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
                                                 name: name) else { return }
        // 广播和扫描回应分两次到：已经认出机型的不要被认不出的那次覆盖。
        if !resolved, let old = found[peripheral.identifier]?.1, old.model != old.name, old.model != Self.unknownModel { return }
        found[peripheral.identifier] = (peripheral, Found(id: peripheral.identifier, name: name.isEmpty ? model : name,
                                                          model: model, rssi: RSSI.intValue))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([Self.service])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectWaiter?.resume(throwing: Failure.connect(error?.localizedDescription ?? String(localized: "未知原因", bundle: .miniDiT))); connectWaiter = nil
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectWaiter?.resume(throwing: Failure.connect(error?.localizedDescription ?? String(localized: "连接断开", bundle: .miniDiT))); connectWaiter = nil
        keepaliveTimer?.cancel(); keepaliveTimer = nil
        if self.peripheral == peripheral {
            log("大疆蓝牙：连接断开")
            onDisconnect?()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == Self.service }) else {
            connectWaiter?.resume(throwing: Failure.gatt); connectWaiter = nil; return
        }
        peripheral.discoverCharacteristics([Self.notifyChar, Self.writeChar], for: s)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        fff4 = service.characteristics?.first { $0.uuid == Self.notifyChar }
        fff5 = service.characteristics?.first { $0.uuid == Self.writeChar }
        guard let fff4, let fff5 else { connectWaiter?.resume(throwing: Failure.gatt); connectWaiter = nil; return }
        peripheral.setNotifyValue(true, for: fff4)
        peripheral.setNotifyValue(true, for: fff5)
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if error == nil, characteristic.isNotifying { notifying.insert(characteristic.uuid) }
        guard notifying.isSuperset(of: [Self.notifyChar, Self.writeChar]), let fff4 else { return }
        peripheral.writeValue(Data([0x01, 0x00]), for: fff4, type: .withResponse)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.notifyChar else { return }
        if let error { connectWaiter?.resume(throwing: Failure.connect(error.localizedDescription)) } else { connectWaiter?.resume() }
        connectWaiter = nil
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        var parser = parsers[characteristic.uuid] ?? DUMLStreamParser()
        let frames = parser.feed(data)
        parsers[characteristic.uuid] = parser
        for f in frames {
            if let i = waiters.firstIndex(where: { $0.match(f) }) { waiters.remove(at: i).cont.resume(returning: f) }
        }
    }
}
