import Foundation
import Network
import Testing
@testable import SonyRemoteKit

/// 富士「无线通信」：握手后是 USB 式容器。按 libfuji 的流程用模拟相机端到端检查。真机未验证。
@Suite struct FujiWiFiTests {
    @Test func encodesInitRequestAndParsesEvents() {
        let req = FujiWiFi.initRequest(guid: [UInt8](repeating: 7, count: 16), name: "MiniDiT Mac")
        #expect(req.count == 82, "富士握手包必须正好 82 字节")
        var r = PTPReader(req)
        #expect((try? r.u32()) == 82 && (try? r.u32()) == 1 && (try? r.u32()) == 0x8F53_E4F2)
        let long = FujiWiFi.initRequest(guid: [], name: String(repeating: "长", count: 60))
        #expect(long.count == 82 && long.suffix(2) == Data([0, 0]), "名字太长时截断并保留结尾的 0")
        var w = PTPWriter()
        w.u16(2); w.u16(0xDF00); w.u32(6); w.u16(0xD222); w.u32(42)
        #expect(FujiWiFi.parseEvents(w.data) == [0xDF00: 6, 0xD222: 42])
        #expect(FujiWiFi.integer(Data([0x0B, 0, 2, 0])) == 0x2000B)
        #expect(FujiWiFi.integer(Data([5, 0])) == 5)
    }

    @Test func formatsMapToKinds() {
        let raf = CameraContentItem(id: 1, storageID: 1, filename: "DSCF0001.RAF", format: 0xB103, size: 1, captureDate: nil,
                                    captureDateRaw: "", width: 0, height: 0)
        #expect(raf.kind == .raw)
    }

    @Test func waitsForOKThenListsAndDownloads() async throws {
        let fake = try FakeFuji(files: [("DSCF0001.JPG", Data(repeating: 0x31, count: 2_500_000)),
                                        ("DSCF0002.RAF", Data(repeating: 0x32, count: 1_200_000)),
                                        ("DSCF0003.MOV", Data(repeating: 0x33, count: 300_000))])
        let ports = try await fake.start()
        defer { fake.stop() }
        let prompts = LockedList()
        let lib = try await FujiCameraLibrary.open(host: "127.0.0.1", port: ports.command, identity: .random(name: "Test"),
                                                   waitForOK: 10, auxiliaryPorts: (ports.event, ports.live),
                                                   progress: { prompts.add($0) })
        #expect(prompts.items.contains { $0.contains("按 OK") }, "状态 0 时提示在相机上按 OK")
        #expect(fake.receivedName == "Test")
        #expect(fake.setValues[FujiWiFi.Prop.mode]?.first == 5, "有 RemoteVersion 时先切到模式 5")
        #expect(fake.setValues[FujiWiFi.Prop.mode]?.last == 11, "状态 6 时最后切到远程看图模式 11")
        #expect(fake.auxiliaryConnections == 2, "远程访问要连上事件和取景端口")
        #expect(await lib.deviceInfo?.model == "X-T5")

        let folder = try await lib.folders()[0]
        let handles = try await lib.handles(in: folder)
        #expect(handles == [3, 2, 1])
        var items: [String: CameraContentItem] = [:]
        for h in handles { let i = try await lib.item(h); items[i.filename] = i }
        #expect(items["DSCF0001.JPG"]?.size == 2_500_000, "读 ObjectInfo 前要打开 0xD227，否则大小是假的")
        #expect(items["DSCF0002.RAF"]?.kind == .raw && items["DSCF0003.MOV"]?.kind == .video)
        #expect(try await lib.thumbnail(1) != nil)

        let out = FileManager.default.temporaryDirectory.appending(path: "fuji-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let jpeg = try #require(items["DSCF0001.JPG"])
        let before = fake.partialReads
        try await lib.download(jpeg, to: out, from: 0, progress: { _, _ in })
        #expect(try Data(contentsOf: out) == fake.files[0].data)
        #expect(fake.partialReads - before == 3, "每块 1 MB")
        await lib.close()
        try await Task.sleep(for: .milliseconds(100))
        #expect(fake.sawGoodbye, "断开时发告别包")
        #expect(fake.setValues[FujiWiFi.Prop.correctFileSize]?.last == 0, "断开前把 0xD227 改回 0")
    }

    @Test func refusedHandshakeIsExplained() async throws {
        let fake = try FakeFuji(files: [])
        fake.refuse = true
        let ports = try await fake.start()
        defer { fake.stop() }
        await #expect(throws: FujiWiFi.Failure.refused) {
            _ = try await FujiCameraLibrary.open(host: "127.0.0.1", port: ports.command, identity: .random(name: "Test"),
                                                 auxiliaryPorts: (ports.event, ports.live))
        }
    }
}

@Suite struct FujiCardTests {
    @Test func listsRAFAsRaw() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "fuji-card-\(UUID().uuidString)")
        let dir = root.appending(path: "DCIM/100_FUJI")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["DSCF0001.RAF", "DSCF0001.JPG", "DSCF0002.HIF", "DSCF0003.MOV"] {
            try Data(repeating: 1, count: 64).write(to: dir.appending(path: name))
        }
        let lib = LocalCardLibrary(root: root)
        let folder = try await lib.folders()[0]
        var kinds: [String: CameraContentItem.Kind] = [:]
        for h in try await lib.handles(in: folder) { let i = try await lib.item(h); kinds[i.filename] = i.kind }
        #expect(kinds == ["DSCF0001.RAF": .raw, "DSCF0001.JPG": .jpeg, "DSCF0002.HIF": .heif, "DSCF0003.MOV": .video])
    }
}

/// 模拟富士相机：82 字节握手 → 68 字节应答，然后是 USB 式容器。开始时状态 0（等按 OK），轮询两次后变成 6。
final class FakeFuji: @unchecked Sendable {
    let files: [(name: String, data: Data)]
    var refuse = false
    private let lock = NSLock()
    private let command: NWListener, event: NWListener, live: NWListener
    private let queue = DispatchQueue(label: "fakefuji")
    private var sockets: [PTPIPSocket] = []
    private var polls = 0
    private var correctSize = false
    private var _setValues: [UInt16: [UInt32]] = [:]
    private var _partialReads = 0, _aux = 0, _goodbye = false, _name = ""

    var setValues: [UInt16: [UInt32]] { lock.withLock { _setValues } }
    var partialReads: Int { lock.withLock { _partialReads } }
    var auxiliaryConnections: Int { lock.withLock { _aux } }
    var sawGoodbye: Bool { lock.withLock { _goodbye } }
    var receivedName: String { lock.withLock { _name } }

    init(files: [(String, Data)]) throws {
        self.files = files.map { (name: $0.0, data: $0.1) }
        command = try NWListener(using: .tcp, on: .any)
        event = try NWListener(using: .tcp, on: .any)
        live = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> (command: UInt16, event: UInt16, live: UInt16) {
        let c = try await listen(command) { sock in await self.serve(sock) }
        let e = try await listen(event) { _ in self.lock.withLock { self._aux += 1 } }
        let l = try await listen(live) { _ in self.lock.withLock { self._aux += 1 } }
        return (c, e, l)
    }

    func stop() {
        [command, event, live].forEach { $0.cancel() }
        lock.withLock { sockets.forEach { $0.close() } }
    }

    private func listen(_ listener: NWListener, _ serve: @escaping @Sendable (PTPIPSocket) async -> Void) async throws -> UInt16 {
        let once = OnceBox()
        return try await withCheckedThrowingContinuation { cont in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: if once.claim() { cont.resume(returning: listener.port!.rawValue) }
                case .failed(let e): if once.claim() { cont.resume(throwing: e) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                conn.start(queue: self.queue)
                let sock = PTPIPSocket(accepted: conn)
                self.lock.withLock { self.sockets.append(sock) }
                Task { await serve(sock) }
            }
            listener.start(queue: queue)
        }
    }

    private func serve(_ s: PTPIPSocket) async {
        do {
            let req = try await s.receiveBytes(82, timeout: 5)
            var r = PTPReader(req)
            guard try r.u32() == 82, try r.u32() == 1, try r.u32() == 0x8F53_E4F2 else { s.close(); return }
            let name = FujiPTPClient.utf16(Array(req[28...]))
            lock.withLock { _name = name }
            var w = PTPWriter()
            if refuse {
                w.u32(12); w.u32(5); w.u32(1)
                try await s.sendRaw(w.data); s.close(); return
            }
            w.u32(68); w.u32(2); w.u32(1); w.raw([UInt8](repeating: 0xF0, count: 16))
            var model = Array("X-T5".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            model += [UInt8](repeating: 0, count: 40 - model.count)
            w.raw(model)
            try await s.sendRaw(w.data)
            while true {
                var h = PTPReader(try await s.receiveBytes(8, timeout: nil))
                let length = Int(try h.u32()), type = try h.u16(), code = try h.u16()
                if length == 8 && type == 0xFFFF && code == 0xFFFF { lock.withLock { _goodbye = true }; s.close(); return }
                var t = PTPReader(try await s.receiveBytes(4, timeout: 5))
                let tid = try t.u32()
                var pr = PTPReader(try await s.receiveBytes(length - 12, timeout: 5))
                var params: [UInt32] = []
                for _ in 0..<((length - 12) / 4) { params.append(try pr.u32()) }
                var dataOut: Data?
                if code == PTPOperation.setDevicePropValue {
                    var dh = PTPReader(try await s.receiveBytes(12, timeout: 5))
                    let dl = Int(try dh.u32())
                    dataOut = Data(try await s.receiveBytes(dl - 12, timeout: 5))
                }
                let (rc, data) = handle(code, params, dataOut)
                var out = PTPWriter()
                if let data { out.u32(UInt32(12 + data.count)); out.u16(2); out.u16(code); out.u32(tid); out.raw(data) }
                out.u32(12); out.u16(3); out.u16(rc); out.u32(tid)
                try await s.sendRaw(out.data)
            }
        } catch {
            s.close()
        }
    }

    private func handle(_ code: UInt16, _ params: [UInt32], _ dataOut: Data?) -> (UInt16, Data?) {
        lock.withLock {
            var w = PTPWriter()
            switch code {
            case PTPOperation.openSession, PTPOperation.closeSession, FujiWiFi.Op.getPropertyDescriptors,
                 FujiWiFi.Op.initiateOpenCapture, FujiWiFi.Op.terminateOpenCapture:
                return (PTPResponse.ok, nil)
            case PTPOperation.getDevicePropValue:
                switch UInt16(params.first ?? 0) {
                case FujiWiFi.Prop.events:
                    polls += 1
                    w.u16(2); w.u16(FujiWiFi.Prop.state); w.u32(polls > 2 ? 6 : 0)
                    w.u16(FujiWiFi.Prop.objectCount); w.u32(UInt32(files.count))
                case FujiWiFi.Prop.remoteVersion: w.u32(0x2000B)
                case FujiWiFi.Prop.remoteGetObjectVersion: w.u32(4)
                case FujiWiFi.Prop.storage: w.u16(1)
                default: return (PTPResponse.operationNotSupported, nil)
                }
                return (PTPResponse.ok, w.data)
            case PTPOperation.setDevicePropValue:
                let prop = UInt16(params.first ?? 0), value = dataOut.flatMap(FujiWiFi.integer) ?? 0
                _setValues[prop, default: []].append(value)
                if prop == FujiWiFi.Prop.correctFileSize { correctSize = value == 1 }
                return (PTPResponse.ok, nil)
            case PTPOperation.getObjectInfo:
                guard let h = params.first, h >= 1, Int(h) <= files.count else { return (PTPResponse.invalidObjectHandle, nil) }
                let f = files[Int(h) - 1]
                let format: UInt16 = f.name.hasSuffix("RAF") ? 0xB103 : f.name.hasSuffix("MOV") ? 0x300D : 0x3801
                let info = PTPObjectInfo(storageID: FujiWiFi.storageID, format: format,
                                         size: correctSize ? UInt32(f.data.count) : 102_400, parent: 0, filename: f.name,
                                         captureDate: "20261117T101500")
                return (PTPResponse.ok, info.encoded())
            case PTPOperation.getThumb:
                return (PTPResponse.ok, Data([0xFF, 0xD8, 0xFF, 0xD9]))
            case PTPOperation.getPartialObject:
                guard params.count >= 3, params[0] >= 1, Int(params[0]) <= files.count else { return (PTPResponse.invalidObjectHandle, nil) }
                _partialReads += 1
                let d = files[Int(params[0]) - 1].data
                let start = min(Int(params[1]), d.count), end = min(d.count, start + Int(params[2]))
                return (PTPResponse.ok, d.subdata(in: start..<end))
            default:
                return (PTPResponse.operationNotSupported, nil)
            }
        }
    }
}

private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
