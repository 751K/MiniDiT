import Foundation

/// 通过 Wi-Fi 浏览、下载大疆 Osmo 相机（Pocket 3 等）里的素材。
/// 文件列表走 UDP 数据通道（DJIDatalink），文件本身用 HTTP 从相机热点下载：
/// `GET http://192.168.2.1/v2?storage=<0 SD | 1 内置>&path=<DCIM/…>`，支持 Range 续传。
/// 代理（.LRF）不在列表里，和原片同路径、扩展名不同；JPEG+RAW 的 .DNG 也不在列表里，同样按路径去取。
public actor DJICameraLibrary: CameraLibrary {
    /// 句柄 → 列表里的一条记录。代理用单独的句柄（原片句柄 | 0x8000_0000）。
    private var records: [UInt32: DJIManifest.Record] = [:]
    private var proxies: [UInt32: CameraContentItem] = [:]
    private var listed: [UInt32]?
    private var notes: [String] = []
    private var thumbs: [UInt32: Data] = [:]
    private let datalink: DJIDatalink
    private let bluetooth: DJIBluetooth?
    private let model: String
    private let ssid: String
    private let identifier: String
    private let host: String
    private let onClose: @Sendable () async -> Void
    private let queue = DispatchQueue(label: "MiniDiT.DJIDatalink")
    private var keepalive: DispatchSourceTimer?
    private let session: URLSession
    private var closed = false
    public nonisolated let connectionLost: AsyncStream<Void>
    private let lostContinuation: AsyncStream<Void>.Continuation

    /// 电脑已经连上相机热点后调用：打开数据通道、注册、进入回放模式。
    /// `port` / `httpPort` / `bindLocal` 只给测试用（模拟相机在本机）。
    public static func open(model: String, ssid: String, identifier: String, bluetooth: DJIBluetooth?,
                            host: String = "192.168.2.1", port: UInt16 = 9004, httpPort: Int? = nil, bindLocal: Bool = true,
                            log: @escaping @Sendable (String) -> Void,
                            onClose: @escaping @Sendable () async -> Void) async throws -> DJICameraLibrary {
        let lib = DJICameraLibrary(model: model, ssid: ssid, identifier: identifier, bluetooth: bluetooth, host: host,
                                   httpPort: httpPort, datalink: DJIDatalink(host: host, port: port, bindLocal: bindLocal, log: log),
                                   onClose: onClose)
        try await lib.start()
        return lib
    }

    private let httpPort: Int?

    init(model: String, ssid: String, identifier: String, bluetooth: DJIBluetooth?, host: String, httpPort: Int?,
         datalink: DJIDatalink, onClose: @escaping @Sendable () async -> Void) {
        self.model = model; self.ssid = ssid; self.identifier = identifier; self.bluetooth = bluetooth
        self.host = host; self.httpPort = httpPort; self.datalink = datalink; self.onClose = onClose
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: config)
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        connectionLost = stream
        lostContinuation = cont
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { c in queue.async { c.resume(with: Result { try body() }) } }
    }

    private func start() async throws {
        let dl = datalink, id = identifier
        try await onQueue { try dl.open(identifier: id); dl.register(); dl.enterPlayback() }
        bluetooth?.onDisconnect = { [weak self] in Task { await self?.bluetoothDropped() } }
        startKeepalive()
    }

    private func bluetoothDropped() {
        // 配对后相机会按设计断开蓝牙；只要 Wi-Fi 数据通道还通就继续用。
        notes.append("大疆相机：蓝牙连接已断开，继续使用 Wi-Fi")
    }

    private func startKeepalive() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1)
        let dl = datalink
        t.setEventHandler { dl.beat() }
        t.resume()
        keepalive = t
    }

    // MARK: CameraLibrary

    public var deviceInfo: CameraDeviceInfo? {
        get async { CameraDeviceInfo(manufacturer: "DJI", model: model, version: "", serialNumber: ssid) }
    }

    public var listingNotes: [String] { get async { notes } }

    public func folders() async throws -> [CameraFolder] {
        [CameraFolder(id: 1, storageID: 0x0001_0001, name: model, isVideo: false, isFlat: true)]
    }

    public func handles(in folder: CameraFolder) async throws -> [UInt32] {
        if let listed { return listed }
        let dl = datalink, id = identifier
        let all: [DJIManifest.Record]
        do {
            all = try await onQueue { try dl.listAll() }
        } catch DJIDatalink.Failure.listUnanswered {
            // Pocket 3 / 4 可能还挂着上一次的会话：握手成功但不回列表。重新建立一次。
            notes.append("大疆相机：文件列表无响应，重新建立数据连接")
            all = try await onQueue { dl.close(); try dl.open(identifier: id); dl.register(); dl.enterPlayback(); return try dl.listAll() }
        }
        var hs: [UInt32] = []
        records = [:]; proxies = [:]
        for (i, r) in all.enumerated() {
            // 句柄在两个存储之间可能相同，用列表序号做本地句柄。
            let h = UInt32(i + 1)
            records[h] = r
            hs.append(h)
        }
        notes.append("大疆相机 \(model)：\(hs.count) 个文件")
        if let free = dl.status.cardFreeMiB, let total = dl.status.cardTotalMiB { notes.append("存储卡剩余 \(free) / \(total) MiB") }
        listed = hs
        return hs
    }

    public func refresh() async { listed = nil; thumbs = [:] }

    private func record(_ h: UInt32) throws -> DJIManifest.Record {
        guard let r = records[h & 0x7FFF_FFFF] else { throw CocoaError(.fileNoSuchFile) }
        return r
    }

    public func item(_ handle: UInt32) async throws -> CameraContentItem {
        if let p = proxies[handle] { return p }
        return Self.item(handle, try record(handle))
    }

    static func item(_ h: UInt32, _ r: DJIManifest.Record) -> CameraContentItem {
        let raw = LocalCardLibrary.djiClock(r.name) ?? r.captureDateRaw ?? ""
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX"); fmt.timeZone = .current; fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        return CameraContentItem(id: h, storageID: UInt32(0x0001_0001 + r.store), filename: r.name,
                                 format: LocalCardLibrary.format(for: r.name) ?? 0, size: UInt64(r.size), sizeKnown: r.size > 0,
                                 captureDate: fmt.date(from: raw), captureDateRaw: raw, width: 0, height: 0)
    }

    public func kinds(in folder: CameraFolder) async -> [UInt32: CameraContentItem.Kind]? {
        guard let listed else { return nil }
        var map: [UInt32: CameraContentItem.Kind] = [:]
        for h in listed { if let r = records[h] { map[h] = Self.item(h, r).kind } }
        return map
    }

    public func sourcePath(_ handle: UInt32) async -> String? {
        if proxies[handle] != nil, let r = try? record(handle) { return r.proxyPath }
        return (try? record(handle))?.filePath
    }

    public func proxy(of handle: UInt32) async -> CameraContentItem? {
        let h = handle | 0x8000_0000
        if let p = proxies[h] { return p }
        guard let r = try? record(handle), let path = r.proxyPath else { return nil }
        var size = UInt64(r.proxySize)
        if size == 0 {
            // 列表里没有代理大小（Pocket 3）：问一下相机，404 就是没有代理（例如关了代理录制）。
            var req = URLRequest(url: url(store: r.store, path: path)); req.httpMethod = "HEAD"
            guard let (_, resp) = try? await session.data(for: req), let http = resp as? HTTPURLResponse,
                  http.statusCode == 200, http.expectedContentLength > 0 else { return nil }
            size = UInt64(http.expectedContentLength)
        }
        let base = Self.item(handle, r)
        let p = CameraContentItem(id: h, storageID: base.storageID, filename: (path as NSString).lastPathComponent,
                                  format: 0, size: size, captureDate: base.captureDate,
                                  captureDateRaw: base.captureDateRaw, width: 0, height: 0)
        proxies[h] = p
        return p
    }

    private func url(store: Int, path: String) -> URL {
        var c = URLComponents()
        c.scheme = "http"; c.host = host; c.port = httpPort; c.path = "/v2"
        c.queryItems = [URLQueryItem(name: "storage", value: String(store)), URLQueryItem(name: "path", value: path)]
        return c.url!
    }

    public func thumbnail(_ handle: UInt32) async throws -> Data? {
        if let d = thumbs[handle] { return d }
        let r = try record(handle)
        guard let path = r.thumbPath else { return nil }
        let (data, resp) = try await session.data(from: url(store: r.store, path: path))
        guard (resp as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        thumbs[handle] = data
        return data
    }

    public func exif(_ handle: UInt32) async -> ShotExif? { nil }

    public func download(_ item: CameraContentItem, to dest: URL, from offset: UInt64,
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        let r = try record(item.id)
        guard let path = proxies[item.id] != nil ? r.proxyPath : r.filePath else { throw CocoaError(.fileNoSuchFile) }
        let source = url(store: r.store, path: path)
        let (fh, start) = try openForResume(dest, offset: offset)
        var pos = start
        defer { try? fh.close() }
        // ≥ 4 GB 的片段列表里大小是 0：以 HTTP 回复的长度为准，传输中断时才能接着续传而不是当成完成。
        var expected = item.size
        var attempts = 0
        // 长传输中途出现 404 / 500 或断开是相机的已知行为：带 Range 续传，最多重试 6 次。
        while true {
            try Task.checkCancellation()
            do {
                var req = URLRequest(url: source)
                if pos > 0 { req.setValue("bytes=\(pos)-", forHTTPHeaderField: "Range") }
                let (bytes, resp) = try await session.bytes(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 200, pos > 0 {
                    // 相机忽略了 Range：从头来。
                    try fh.truncate(atOffset: 0); try fh.seek(toOffset: 0); pos = 0
                } else if code != 200, code != 206 {
                    throw URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "相机返回 HTTP \(code)"])
                }
                if expected == 0, resp.expectedContentLength > 0 { expected = pos + UInt64(resp.expectedContentLength) }
                var buf = Data(); buf.reserveCapacity(1 << 20)
                for try await b in bytes {
                    buf.append(b)
                    if buf.count >= 1 << 20 {
                        try fh.write(contentsOf: buf); pos += UInt64(buf.count); buf.removeAll(keepingCapacity: true)
                        progress(pos, expected)
                        try Task.checkCancellation()
                    }
                }
                if !buf.isEmpty { try fh.write(contentsOf: buf); pos += UInt64(buf.count); progress(pos, expected) }
                if expected == 0 || pos >= expected { break }
                throw URLError(.networkConnectionLost)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                attempts += 1
                if attempts > 6 { throw error }
                try await Task.sleep(for: .seconds(min(2 * attempts, 8)))
            }
        }
        if expected > 0, pos != expected {
            throw URLError(.cannotDecodeContentData, userInfo: [NSLocalizedDescriptionKey: "大小不符：收到 \(pos)，应为 \(expected)"])
        }
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        keepalive?.cancel(); keepalive = nil
        let dl = datalink
        _ = try? await onQueue { dl.close() }
        bluetooth?.disconnect()
        session.invalidateAndCancel()
        await onClose()
        lostContinuation.finish()
    }

    /// 上层发现 Wi-Fi 断了时调用。
    public func markLost() {
        lostContinuation.yield()
        lostContinuation.finish()
    }
}
