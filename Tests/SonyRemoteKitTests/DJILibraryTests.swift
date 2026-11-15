import Darwin
import Foundation
import Testing
@testable import SonyRemoteKit

/// 模拟一台 Osmo Pocket 3 的 Wi-Fi 一侧（UDP 数据通道 + HTTP /v2），端到端检查 DJICameraLibrary：
/// 握手、注册、Pocket 3 式的回放模式（0x02/0x0c 回 e0，要走 0x01/0x01）、列文件、下载、续传、代理和缩略图。
/// 蓝牙配对和加入热点要真机，这里不覆盖。
final class FakeOsmo: @unchecked Sendable {
    struct File { let path: String; let data: Data }
    let lock = NSLock()
    let udp: Int32
    let tcp: Int32
    let udpPort: UInt16
    let httpPort: Int
    let manifest: [UInt8]
    let files: [String: Data]
    var playback = false
    var seen: [String] = []
    var cutOnce: Set<String>
    var running = true
    private var msg: UInt16 = 1

    init(manifest: [UInt8], files: [String: Data], cutOnce: Set<String>) throws {
        self.manifest = manifest; self.files = files; self.cutOnce = cutOnce
        func bound(_ type: Int32) throws -> (Int32, UInt16) {
            let s = socket(AF_INET, type, 0)
            var yes: Int32 = 1
            setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            inet_pton(AF_INET, "127.0.0.1", &a.sin_addr)
            let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard r == 0 else { throw POSIXError(.EADDRINUSE) }
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) } }
            return (s, UInt16(bigEndian: a.sin_port))
        }
        (udp, udpPort) = try bound(SOCK_DGRAM)
        let (t, hp) = try bound(SOCK_STREAM)
        tcp = t; httpPort = Int(hp)
        listen(tcp, 8)
        Thread.detachNewThread { self.udpLoop() }
        Thread.detachNewThread { self.httpLoop() }
    }

    func stop() { lock.lock(); running = false; lock.unlock(); Darwin.close(udp); Darwin.close(tcp) }
    func note(_ s: String) { lock.lock(); seen.append(s); lock.unlock() }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return seen }

    // MARK: UDP

    private func udpLoop() {
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = buf.withUnsafeMutableBytes { b in withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(udp, b.baseAddress, b.count, 0, $0, &len) } } }
            if n <= 0 { return }
            let d = Array(buf[0..<n])
            guard d.count >= 8 else { continue }
            if d[6] == 0x00 { note("handshake"); reply(DJIDatalink.udpHeader(type: 0x00, payloadLength: d.count - 8, session: 0, seq: 0) + d[8...], to: from); continue }
            guard d[6] == 0x05, let (f, _) = DUMLFrame.decode(d, at: 20) else { continue }
            handle(f, from: from)
        }
    }

    private func handle(_ f: DUMLFrame, from: sockaddr_in) {
        switch (f.commandSet, f.commandID) {
        case (0x00, 0x81):
            note("register")
            var storage = [UInt8](repeating: 0, count: 22)
            storage[2] = 1; storage[6...9] = [0x00, 0xE8, 0x00, 0x00]; storage[10...13] = [0x00, 0x80, 0x00, 0x00]
            push(0x02, 0xDC, storage, to: from)
        case (0x00, 0x88):
            note("presence")
            if playback { pushPlayback(to: from) }
        case (0x02, 0x0C):
            if f.payload == [1, 1, 0, 0] { note("leave"); playback = false }
            else { note("0x02/0x0c"); push(0x02, 0x0C, [0xE0], to: from, flags: DUMLFrame.response) }   // Pocket 3：拒绝
        case (0x01, 0x01):
            if f.payload.first == 0x00 { if !playback { note("playback") }; playback = true; pushPlayback(to: from) }
        case (0x00, 0x26) where f.payload.count > 10 && f.payload[1] == 0x00:
            let counter = f.payload[4]
            note("list \(counter)")
            push(0x00, 0x27, [0x4A, 0x04, 0, 0, counter, 0, 0, 0, 0, 0], to: from)
            guard counter == 1 else { return }   // 没有内置存储：只回开始块
            var seq: UInt16 = 0
            for start in stride(from: 0, to: manifest.count, by: 200) {
                let chunk = Array(manifest[start..<min(start + 200, manifest.count)])
                push(0x00, 0x27, [0x4A, 0x01, 0, 0, counter, 0, UInt8(seq & 0xFF), UInt8(seq >> 8), 0, 0] + chunk, to: from)
                seq += 1
            }
            push(0x00, 0x27, [0x4A, 0x03, 0, 0, counter, 0, 0, 0, 0, 0], to: from)
        default: break
        }
    }

    private func pushPlayback(to: sockaddr_in) {
        var p = [UInt8](repeating: 0, count: 60)
        p[0] = 0x01; p[3] = 0x40
        push(0x02, 0x80, p, to: to)
    }

    private func push(_ set: UInt8, _ id: UInt8, _ payload: [UInt8], to: sockaddr_in, flags: UInt8 = 0x00) {
        msg &+= 1
        let frame = DUMLFrame(sender: 0x01, receiver: 0x02, messageID: msg, flags: flags, commandSet: set, commandID: id, payload: payload).encoded()
        let body = [UInt8](repeating: 0, count: 12) + frame
        reply(DJIDatalink.udpHeader(type: 0x01, payloadLength: body.count, session: 0, seq: 0) + body, to: to)
    }

    private func reply(_ packet: [UInt8], to: sockaddr_in) {
        var a = to
        _ = packet.withUnsafeBytes { b in withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            sendto(udp, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
    }

    // MARK: HTTP

    private func httpLoop() {
        while true {
            let c = accept(tcp, nil, nil)
            if c < 0 { return }
            Thread.detachNewThread { self.serve(c) }
        }
    }

    private func serve(_ c: Int32) {
        defer { Darwin.close(c) }
        var req = [UInt8](); var buf = [UInt8](repeating: 0, count: 4096)
        while !req.contains(13) || String(decoding: req, as: UTF8.self).range(of: "\r\n\r\n") == nil {
            let n = read(c, &buf, buf.count); if n <= 0 { return }; req += buf[0..<n]
        }
        let text = String(decoding: req, as: UTF8.self)
        let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let comps = URLComponents(string: String(parts[1])),
              comps.path == "/v2", let path = comps.queryItems?.first(where: { $0.name == "path" })?.value,
              comps.queryItems?.first(where: { $0.name == "storage" })?.value == "0" else { write(c, "HTTP/1.1 400 Bad\r\nContent-Length: 0\r\n\r\n"); return }
        let method = String(parts[0])
        note("\(method) \(path)")
        guard let data = files[path] else { write(c, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return }
        var start = 0
        if let r = text.range(of: "Range: bytes=") {
            start = Int(text[r.upperBound...].prefix { $0.isNumber }) ?? 0
        }
        let body = data.subdata(in: start..<data.count)
        let head = start > 0
            ? "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(data.count - 1)/\(data.count)\r\n"
            : "HTTP/1.1 200 OK\r\n"
        write(c, head + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n")
        guard method == "GET" else { return }
        lock.lock(); let cut = cutOnce.remove(path) != nil; lock.unlock()
        // 模拟相机长传输中途断开：第一次只发一半就关连接。
        let send = cut ? body.prefix(body.count / 2) : body
        _ = send.withUnsafeBytes { Darwin.write(c, $0.baseAddress, $0.count) }
    }

    private func write(_ c: Int32, _ s: String) { _ = s.withCString { Darwin.write(c, $0, strlen($0)) } }
}

@Suite struct DJILibraryTests {
    /// 按 Pocket 3 的字段顺序造一条记录：… FAT 时间 / 大小 / 句柄 / 时长 / 类型 `ff 19 06` 00 00 00 38 01，
    /// 然后是原片路径、缩略图路径、文件名。
    static func record(name: String, handle: UInt32, size: UInt32, fat: UInt32, duration: UInt16) -> [UInt8] {
        func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> ($0 * 8)) & 0xFF) } }
        let base = (name as NSString).deletingPathExtension
        let media = Array("DCIM/DJI_001/\(base)".utf8), thumb = Array("MISC/THM/DJI_001/\(base)".utf8), file = Array(name.utf8)
        var r: [UInt8] = [0xF0, 0x00, 0x04, 0x00]          // 填充，让 T−18 之前还有字节
        r += le32(fat) + le32(size) + le32(handle)         // T−18, T−14, T−10
        r += [UInt8(duration & 0xFF), UInt8(duration >> 8), 0x05, 0x10, name.hasSuffix(".MP4") ? 0x03 : 0x00, 0xFF]  // T−6 … T−1
        r += [0x19, 0x06, 0x00, 0x00, 0x00, 0x38, 0x01]    // T … T+6
        r += [0x1A, UInt8(media.count + 6), 0, 0, 0, 0x01] + media
        r += [0x1A, UInt8(thumb.count + 6), 0, 0, 0, 0x02] + thumb
        r += [0x1B, 0x0A, 0, 0, 0, 0x02, 0x02, 0x01, 0x14, 0x02, 0x15, 0x03, 0x00]
        r += [0x0D, UInt8(file.count)] + file
        return r
    }

    static func fat(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> UInt32 {
        UInt32((y - 1980) << 9 | mo << 5 | d) << 16 | UInt32(h << 11 | mi << 5)
    }

    @Test func endToEndOverFakePocket3() async throws {
        let clip = Data((0..<300_000).map { UInt8($0 % 251) })
        let long = Data((0..<123_456).map { UInt8($0 % 241) })   // 列表里大小为 0（模拟 ≥ 4 GB）
        let photo = Data((0..<20_000).map { UInt8($0 % 239) })
        let lrf = Data(repeating: 0x4C, count: 50_000)
        let thumb = Data(repeating: 0xD8, count: 900)
        var manifest: [UInt8] = [3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        manifest += Self.record(name: "DJI_20251115143000_0003_D.MP4", handle: 0x0004_0030, size: UInt32(clip.count), fat: Self.fat(2025, 11, 15, 14, 31), duration: 12)
        manifest += Self.record(name: "DJI_20251115120000_0002_D.MP4", handle: 0x0004_0020, size: 0, fat: Self.fat(2025, 11, 15, 12, 30), duration: 1340)
        manifest += Self.record(name: "DJI_20251115110000_0001_D.JPG", handle: 0x0004_0010, size: UInt32(photo.count), fat: Self.fat(2025, 11, 15, 11, 0), duration: 0)
        let files: [String: Data] = [
            "DCIM/DJI_001/DJI_20251115143000_0003_D.MP4": clip,
            "DCIM/DJI_001/DJI_20251115143000_0003_D.LRF": lrf,
            "DCIM/DJI_001/DJI_20251115120000_0002_D.MP4": long,
            "DCIM/DJI_001/DJI_20251115110000_0001_D.JPG": photo,
            "MISC/THM/DJI_001/DJI_20251115143000_0003_D": thumb,
        ]
        let fake = try FakeOsmo(manifest: manifest, files: files, cutOnce: ["DCIM/DJI_001/DJI_20251115120000_0002_D.MP4"])
        defer { fake.stop() }
        let closed = LockedFlag()
        let lib = try await DJICameraLibrary.open(model: "Osmo Pocket 3", ssid: "OsmoPocket3-C2D8", identifier: String(repeating: "a", count: 32),
                                                  bluetooth: nil, host: "127.0.0.1", port: fake.udpPort, httpPort: fake.httpPort,
                                                  bindLocal: false, log: { _ in }, onClose: { closed.set() })
        let folder = try await lib.folders()[0]
        let hs = try await lib.handles(in: folder)
        #expect(hs.count == 3)
        var items: [String: CameraContentItem] = [:]
        for h in hs { let i = try await lib.item(h); items[i.filename] = i }
        let c = try #require(items["DJI_20251115143000_0003_D.MP4"]), l = try #require(items["DJI_20251115120000_0002_D.MP4"])
        let p = try #require(items["DJI_20251115110000_0001_D.JPG"])
        #expect(c.kind == .video && p.kind == .jpeg)
        #expect(c.captureDateRaw == "20251115T143000" && c.size == 300_000 && c.sizeKnown)
        #expect(l.size == 0 && !l.sizeKnown)
        #expect(await lib.kinds(in: folder)?.count == 3)

        let dir = FileManager.default.temporaryDirectory.appending(path: "dji-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for item in [c, l, p] {
            let dst = dir.appending(path: item.filename)
            try await lib.download(item, to: dst, from: 0) { _, _ in }
            #expect(try Data(contentsOf: dst) == files["DCIM/DJI_001/" + item.filename], "\(item.filename)")
        }
        let proxy = try #require(await lib.proxy(of: c.id))
        #expect(proxy.filename == "DJI_20251115143000_0003_D.LRF" && proxy.size == 50_000)
        let proxyDst = dir.appending(path: "proxy.MP4")
        try await lib.download(proxy, to: proxyDst, from: 0) { _, _ in }
        #expect(try Data(contentsOf: proxyDst) == lrf)
        #expect(await lib.proxy(of: p.id) == nil, "照片没有代理")
        #expect(await lib.proxy(of: l.id) == nil, "相机上没有这段的 .LRF（HEAD 404）")
        #expect(try await lib.thumbnail(c.id) == thumb)
        #expect(await lib.sourcePath(c.id) == "DCIM/DJI_001/DJI_20251115143000_0003_D.MP4")

        try await Task.sleep(for: .milliseconds(1500))
        await lib.close()
        #expect(closed.value)
        let log = fake.log
        #expect(log.first == "handshake")
        #expect(log.contains("register") && log.contains("0x02/0x0c") && log.contains("playback"), "Pocket 3 要走 0x01/0x01 进入回放：\(log)")
        #expect(log.contains("list 1") && log.contains("list 2"))
        #expect(log.filter { $0 == "presence" }.count >= 3, "回放模式要靠每秒的在线声明保持")
        #expect(log.filter { $0 == "GET DCIM/DJI_001/DJI_20251115120000_0002_D.MP4" }.count == 2, "中途断开后带 Range 续传")
        #expect(log.last == "leave")
    }
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock(); private var v = false
    func set() { lock.lock(); v = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return v }
}
