import Foundation

extension SonyOperation {
    /// 远程传输（遥控会话里读卡，相机界面不锁）：p1 卡槽 → u32 n + n × u64 拍摄日期（毫秒）。
    public static let getCapturedDateList: UInt16 = 0x923B
    /// p1/p2 游标（创建时间 UTC 毫秒，低/高），p3 每页数量（100），p4 卡槽，p5 0 → 内容列表。
    public static let getContentsInfoList: UInt16 = 0x923C
    /// p1 内容 ID，p2 卡槽<<24 | 文件 ID，p3/p4 偏移低/高，p5 字节数 | 最后一块<<31 → 文件数据。
    public static let getContentsData: UInt16 = 0x923D
    /// p1 内容 ID，p2 卡槽<<24 | 文件 ID，p3 1 缩略图 / 2 大预览图 → 图片。
    public static let getContentsCompressedData: UInt16 = 0x923E
}

/// 0x923C 返回的一次拍摄（RAW + JPEG 是同一个内容里的两个文件）。
public struct SonyContent: Sendable, Equatable {
    public struct File: Sendable, Equatable {
        public var id: UInt16
        public var path: String
        public var format: UInt32
        public var size: UInt64
        public var width: UInt32
        public var height: UInt32

        public init(id: UInt16, path: String, format: UInt32, size: UInt64, width: UInt32 = 0, height: UInt32 = 0) {
            self.id = id; self.path = path; self.format = format; self.size = size; self.width = width; self.height = height
        }
    }

    public var type: UInt32
    public var id: UInt32
    public var createdUTC: UInt64     // 毫秒
    public var createdLocal: UInt64   // 相机本地时间，按 UTC 编码
    public var files: [File]

    public init(type: UInt32 = 1, id: UInt32, createdUTC: UInt64, createdLocal: UInt64, files: [File]) {
        self.type = type; self.id = id; self.createdUTC = createdUTC; self.createdLocal = createdLocal; self.files = files
    }

    static let listHeader = 0x90
    static let pageSize: UInt32 = 100

    /// 解析 0x923C 的回复。
    public static func parseList(_ data: Data) throws -> [SonyContent] {
        var r = PTPReader(data)
        guard r.remaining >= listHeader + 4 else { throw PTPDecodeError.truncated(needed: listHeader + 4, available: r.remaining) }
        try r.seek(to: listHeader)
        let n = Int(try r.u32())
        guard n <= 10_000 else { throw PTPDecodeError.invalid("内容数量 \(n) 不合理") }
        var out: [SonyContent] = []
        for _ in 0..<n {
            let type = try r.u32(), id = try r.u32()
            try r.skip(4 * 5)                 // 目录号、文件号、分组类型、分组 ID、代表
            let createdUTC = try r.u64()
            _ = try r.u64()                   // 修改时间 UTC
            let createdLocal = try r.u64()
            _ = try r.u64()                   // 修改时间（本地）
            try r.skip(4 * 3)                 // 评分、保护、占位
            let marks = Int(try r.u32())
            try r.skip(marks)
            let fileCount = Int(try r.u32())
            guard fileCount <= 64 else { throw PTPDecodeError.invalid("文件数量 \(fileCount) 不合理") }
            var files: [File] = []
            for _ in 0..<fileCount {
                let fid = UInt16(truncatingIfNeeded: try r.u32())   // u16 + 2 字节填充
                let len = Int(try r.u32())
                let raw = try r.raw(len)
                let path = String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                let format = try r.u32()
                let size = try r.u64()
                try r.skip(32)                // UMID
                var w: UInt32 = 0, h: UInt32 = 0
                if try r.u32() != 0 { w = try r.u32(); h = try r.u32() }
                if try r.u32() != 0 { try r.skip(0x4C) }   // 视频参数
                if try r.u32() != 0 { try r.skip(0x10) }   // 音频参数
                files.append(File(id: fid, path: path, format: format, size: size, width: w, height: h))
            }
            out.append(SonyContent(type: type, id: id, createdUTC: createdUTC, createdLocal: createdLocal, files: files))
        }
        return out
    }

    /// 生成 0x923C 回复（模拟相机和测试用）。
    public static func encodeList(_ contents: [SonyContent]) -> Data {
        var w = PTPWriter()
        w.u32(100)
        for _ in 0..<((listHeader - 4) / 4) { w.u32(0) }
        w.u32(UInt32(contents.count))
        for c in contents {
            for v in [c.type, c.id, 100, 0, 0, 0, 1] { w.u32(v) }
            for t in [c.createdUTC, c.createdUTC, c.createdLocal, c.createdLocal] { w.u64(t) }
            for v: UInt32 in [0, 0, 0, 0] { w.u32(v) }   // 评分、保护、占位、标记数
            w.u32(UInt32(c.files.count))
            for f in c.files {
                w.u32(UInt32(f.id))
                let p = Array(f.path.utf8) + [0]
                w.u32(UInt32(p.count)); p.forEach { w.u8($0) }
                w.u32(f.format); w.u64(f.size)
                for _ in 0..<8 { w.u32(0) }               // UMID
                if f.width > 0 { w.u32(1); w.u32(f.width); w.u32(f.height) } else { w.u32(0) }
                w.u32(0); w.u32(0)
            }
        }
        return w.data
    }
}

public enum SonyRemoteTransferError: Error, LocalizedError, Sendable {
    case notSupported
    case cardsUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .notSupported: return "相机不支持远程传输"
        case .cardsUnavailable(let s): return "相机暂时不开放存储卡（\(s)）"
        }
    }
}

/// 「远程传输」方式浏览存储卡：普通遥控会话里用 0x923B–0x923E 按卡槽读取，
/// 可以随时在卡 1 / 卡 2 之间切换，相机界面也不会被锁住。
public actor SonyRemoteTransferLibrary: CameraLibrary {
    private struct Entry {
        let slot: UInt32
        let contentID: UInt32
        let fileID: UInt16
        let item: CameraContentItem
    }

    private let client: PTPIPClient
    private let slots: [UInt32]
    private var entries: [UInt32: Entry] = [:]
    private var slotHandles: [UInt32: [UInt32]] = [:]
    private var nextHandle: UInt32 = 1
    public nonisolated let connectionLost: AsyncStream<Void>
    public private(set) var listingNotes: [String] = []
    private var thumbNoted = false
    public let deviceInfo: CameraDeviceInfo?

    init(client: PTPIPClient, slots: [UInt32], notes: [String], deviceInfo: CameraDeviceInfo? = nil) {
        self.client = client
        self.deviceInfo = deviceInfo
        self.slots = slots
        self.listingNotes = notes
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        connectionLost = stream
        let events = client.events
        Task {
            for await _ in events {}
            cont.yield()
            cont.finish()
        }
    }

    /// 连接相机并检查远程传输是否可用；不可用时抛错（调用方可以退回内容传输模式）。
    public static func open(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity,
                            tunnel: CameraSSHTunnel? = nil,
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SonyRemoteTransferLibrary {
        let client = PTPIPClient(host: host, port: port, identity: identity, tunnel: tunnel)
        progress(tunnel == nil ? "正在建立 PTP/IP 连接…" : "正在通过加密通道建立 PTP/IP 连接…")
        try await client.connect()
        do {
            var notes: [String] = []
            let info = await fetchDeviceInfo(client)
            let ops = info?.operations ?? []
            if let info { notes.append("相机：\(info.manufacturer) \(info.model)，固件 \(info.version)，序列号 \(info.serialNumber.isEmpty ? "无" : "有")") }
            notes.append("远程传输：相机列出 \(ops.count) 个操作，" +
                         "0x923B–0x923E \([SonyOperation.getCapturedDateList, SonyOperation.getContentsInfoList, SonyOperation.getContentsData, SonyOperation.getContentsCompressedData].allSatisfy(ops.contains) ? "都有" : "不全")")

            progress("正在打开会话…")
            try await SonySDIO.openSession(client, mode: nil)
            progress("正在进行索尼 SDIO 握手…")
            _ = try await SonySDIO.handshake(client)

            // 操作列表拿到了却没有远程传输操作：不要乱发（猜错参数可能让相机死机）。
            if !ops.isEmpty && !(ops.contains(SonyOperation.getCapturedDateList) && ops.contains(SonyOperation.getContentsInfoList)) {
                throw SonyRemoteTransferError.notSupported
            }

            progress("正在检查卡槽…")
            var available: [UInt32] = []
            var failures: [String] = []
            for slot: UInt32 in [1, 2] {
                let r = try await client.transaction(SonyOperation.getCapturedDateList, [slot], requireOK: false)
                if r.code == PTPResponse.ok {
                    let n = Self.count(r.data)
                    notes.append("卡槽 \(slot)：\(n) 个日期")
                    available.append(slot)
                } else {
                    let e = PTPError(operation: SonyOperation.getCapturedDateList, code: r.code)
                    notes.append("卡槽 \(slot)：\(e.localizedDescription)")
                    failures.append(e.localizedDescription)
                    if r.code == PTPResponse.operationNotSupported && slot == 1 && ops.isEmpty {
                        throw SonyRemoteTransferError.notSupported
                    }
                }
            }
            guard !available.isEmpty else { throw SonyRemoteTransferError.cardsUnavailable(failures.joined(separator: "；")) }
            return SonyRemoteTransferLibrary(client: client, slots: available, notes: notes, deviceInfo: info)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// GetDeviceInfo（失败返回 nil）。
    static func fetchDeviceInfo(_ client: PTPIPClient) async -> CameraDeviceInfo? {
        guard let r = try? await client.transaction(PTPOperation.getDeviceInfo, requireOK: false),
              r.code == PTPResponse.ok else { return nil }
        return CameraDeviceInfo.parse(r.data)
    }


    /// 0x923B 回复开头的 u32 数量。
    static func count(_ data: Data) -> UInt32 {
        var r = PTPReader(data)
        return (try? r.u32()) ?? 0
    }

    public static func storageID(slot: UInt32) -> UInt32 { slot << 16 | 1 }

    public func folders() async throws -> [CameraFolder] {
        slots.map { CameraFolder(id: $0, storageID: Self.storageID(slot: $0), name: "卡槽 \($0)", isVideo: false, isFlat: true) }
    }

    public func handles(in folder: CameraFolder) async throws -> [UInt32] {
        let slot = folder.id
        if let cached = slotHandles[slot] { return cached }
        // 先问日期列表：空卡槽直接问内容列表的话，相机会一直不回、拖死整个会话。
        let dates = try await client.transaction(SonyOperation.getCapturedDateList, [slot])
        guard Self.count(dates.data) > 0 else { slotHandles[slot] = []; return [] }

        var contents: [SonyContent] = []
        var seen = Set<UInt32>()
        var cursor: UInt64 = 0
        for _ in 0..<2000 {
            try Task.checkCancellation()
            let r = try await client.transaction(SonyOperation.getContentsInfoList,
                                                 [UInt32(cursor & 0xFFFF_FFFF), UInt32(cursor >> 32), SonyContent.pageSize, slot, 0])
            let page = try SonyContent.parseList(r.data)
            for c in page where seen.insert(c.id).inserted { contents.append(c) }
            guard page.count >= Int(SonyContent.pageSize), let last = page.last else { break }
            if last.createdUTC <= cursor {
                listingNotes.append("卡槽 \(slot)：列表游标停在 \(cursor)，只读到 \(contents.count) 个")
                break
            }
            cursor = last.createdUTC
        }

        var made: [(UInt64, UInt32)] = []
        for c in contents {
            for f in c.files {
                let item = Self.makeItem(handle: nextHandle, slot: slot, content: c, file: f)
                guard item.kind != .other else { continue }   // XML 附属文件等
                entries[nextHandle] = Entry(slot: slot, contentID: c.id, fileID: f.id, item: item)
                made.append((c.createdUTC, nextHandle))
                nextHandle += 1
            }
        }
        // 新的在前；同一次拍摄里保持文件原顺序。
        let hs = made.enumerated().sorted { a, b in
            a.element.0 != b.element.0 ? a.element.0 > b.element.0 : a.offset < b.offset
        }.map(\.element.1)
        listingNotes.append("卡槽 \(slot)：\(contents.count) 次拍摄，\(hs.count) 个文件")
        slotHandles[slot] = hs
        return hs
    }

    static func makeItem(handle: UInt32, slot: UInt32, content c: SonyContent, file f: SonyContent.File) -> CameraContentItem {
        let name = f.path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? f.path
        let date = c.createdUTC > 0 ? Date(timeIntervalSince1970: Double(c.createdUTC) / 1000) : nil
        var raw = ""
        if c.createdLocal > 0 {
            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "UTC")
            fmt.dateFormat = "yyyyMMdd'T'HHmmss"
            raw = fmt.string(from: Date(timeIntervalSince1970: Double(c.createdLocal) / 1000))
        }
        return CameraContentItem(id: handle, storageID: storageID(slot: slot), filename: name,
                                 format: UInt16(truncatingIfNeeded: f.format), size: f.size, sizeKnown: true,
                                 captureDate: date, captureDateRaw: raw, width: Int(f.width), height: Int(f.height))
    }

    private func entry(_ handle: UInt32) throws -> Entry {
        guard let e = entries[handle] else { throw PTPError(operation: SonyOperation.getContentsInfoList, code: PTPResponse.invalidObjectHandle) }
        return e
    }

    public func item(_ handle: UInt32) async throws -> CameraContentItem { try entry(handle).item }

    public func kinds(in folder: CameraFolder) async -> [UInt32: CameraContentItem.Kind]? {
        guard let hs = slotHandles[folder.id] else { return nil }
        var map: [UInt32: CameraContentItem.Kind] = [:]
        for h in hs { if let e = entries[h] { map[h] = e.item.kind } }
        return map
    }

    public func thumbnail(_ handle: UInt32) async throws -> Data? {
        let e = try entry(handle)
        let r = try await client.transaction(SonyOperation.getContentsCompressedData,
                                             [e.contentID, e.slot << 24 | UInt32(e.fileID), 1], requireOK: false)
        guard r.code == PTPResponse.ok else {
            if !thumbNoted { thumbNoted = true; listingNotes.append("缩略图：0x923E 失败 \(String(format: "0x%04X", r.code))") }
            return nil
        }
        let image = PTPCameraLibrary.decodableImage(r.data)
        if !thumbNoted {
            thumbNoted = true
            listingNotes.append("缩略图：0x923E \(image.map(PTPCameraLibrary.imageKind) ?? "无法识别")，\(r.data.count) 字节，开头 \(PTPCameraLibrary.hexPrefix(r.data))")
        }
        return image
    }

    /// 0x923E 参数 2：screennail（约 1616 px 的 JPEG）。
    public func preview(_ handle: UInt32) async throws -> Data? {
        let e = try entry(handle)
        let r = try await client.transaction(SonyOperation.getContentsCompressedData,
                                             [e.contentID, e.slot << 24 | UInt32(e.fileID), 2], requireOK: false)
        guard r.code == PTPResponse.ok, let image = PTPCameraLibrary.decodableImage(r.data) else { return try await thumbnail(handle) }
        return image
    }

    public func download(_ item: CameraContentItem, to url: URL,
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        let e = try entry(item.id)
        let size = e.item.size
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fh = try FileHandle(forWritingTo: url)
        defer { try? fh.close() }
        let chunk: UInt64 = 4 * 1024 * 1024
        var done: UInt64 = 0
        while done < size {
            try Task.checkCancellation()
            let want = UInt32(min(chunk, size - done))
            let last: UInt32 = done + UInt64(want) >= size ? 1 << 31 : 0
            let r = try await client.transaction(SonyOperation.getContentsData,
                                                 [e.contentID, e.slot << 24 | UInt32(e.fileID),
                                                  UInt32(done & 0xFFFF_FFFF), UInt32(done >> 32), want | last])
            guard !r.data.isEmpty else { throw PTPDecodeError.invalid("相机返回了空数据块") }
            guard r.data.count <= Int(want) else { throw PTPDecodeError.invalid("相机多发了数据：\(r.data.count)/\(want)") }
            try fh.write(contentsOf: r.data)
            done += UInt64(r.data.count)
            progress(done, size)
        }
    }

    public func close() async {
        await client.shutdown()
    }
}
