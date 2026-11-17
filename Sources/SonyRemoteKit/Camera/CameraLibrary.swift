import Foundation

/// 存储卡上的一个文件。
public struct CameraContentItem: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable { case jpeg, heif, raw, video, other }

    public let id: UInt32            // PTP 对象句柄
    public let storageID: UInt32
    public let filename: String
    public let format: UInt16
    /// 字节数；sizeKnown 为 false 时（≥4GB 的视频）是 0。
    public let size: UInt64
    public let sizeKnown: Bool
    public let captureDate: Date?
    /// 相机给的原始日期字符串（不受手机时区影响，用来做下载记录的键）。
    public let captureDateRaw: String
    public let width: Int
    public let height: Int

    public init(id: UInt32, storageID: UInt32, filename: String, format: UInt16, size: UInt64, sizeKnown: Bool = true,
                captureDate: Date?, captureDateRaw: String = "", width: Int, height: Int) {
        self.id = id
        self.storageID = storageID
        self.filename = filename
        self.format = format
        self.size = size
        self.sizeKnown = sizeKnown
        self.captureDate = captureDate
        self.captureDateRaw = captureDateRaw
        self.width = width
        self.height = height
    }

    public init(handle: UInt32, info: PTPObjectInfo) {
        // PTP 规定 ≥4GB 的对象大小填 0xFFFFFFFF。
        let known = info.size != 0xFFFF_FFFF && info.size != 0
        self.init(id: handle, storageID: info.storageID, filename: info.filename, format: info.format,
                  size: known ? UInt64(info.size) : 0, sizeKnown: known,
                  captureDate: info.captureDateValue,
                  captureDateRaw: info.captureDate.isEmpty ? info.modificationDate : info.captureDate,
                  width: Int(info.imageWidth), height: Int(info.imageHeight))
    }

    public var kind: Kind {
        switch format {
        case PTPObjectFormat.jpeg, PTPObjectFormat.mpo: return .jpeg
        case PTPObjectFormat.heif: return .heif
        case PTPObjectFormat.sonyARW, PTPObjectFormat.dng, CanonWiFi.formatCR3, CanonWiFi.formatCR2: return .raw
        case PTPObjectFormat.mp4, PTPObjectFormat.mov, PTPObjectFormat.avi, CanonWiFi.formatMOV: return .video
        default:
            switch (filename as NSString).pathExtension.uppercased() {
            case "JPG", "JPEG": return .jpeg
            case "HIF", "HEIF", "HEIC": return .heif
            case "ARW", "DNG", "NEF", "NRW", "CR3", "CR2", "CRW", "RAF": return .raw
            // CRM：佳能 Cinema RAW Light。
            case "MP4", "MOV", "MTS", "AVI", "CRM": return .video
            default: return .other
            }
        }
    }

    /// 同一次拍摄的 RAW + JPEG 共享文件名主体（DSC01234.ARW / DSC01234.JPG）。
    public var baseName: String { (filename as NSString).deletingPathExtension }
}

public extension CameraLibrary {
    func sourcePath(_ handle: UInt32) async -> String? { nil }
    func clipInfo(_ handle: UInt32) async -> ClipInfo? { nil }
    func clipXML(_ handle: UInt32) async -> Data? { nil }
    func proxy(of handle: UInt32) async -> CameraContentItem? { nil }
    func rating(_ handle: UInt32) async -> Int? { nil }
    func refresh() async {}
}

/// 照片星级：索尼把它写在文件开头的 XMP 里（ARW 约第 600 字节，HIF 约第 4300 字节）。
public enum PhotoRating {
    /// 读文件开头多少字节。
    public static let headLength = 16 * 1024

    /// 读本地文件开头的星级。
    public static func read(fileAt url: URL) -> Int? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        return (try? h.read(upToCount: headLength)).flatMap(parse)
    }

    public static func parse(_ head: Data) -> Int? {
        let s = String(decoding: head.prefix(headLength), as: UTF8.self)
        for pattern in ["<xmp:Rating>", "xmp:Rating=\""] {
            guard let r = s.range(of: pattern) else { continue }
            let digits = s[r.upperBound...].prefix { $0 == "-" || $0.isNumber }
            if let v = Int(digits) { return v }
        }
        return nil
    }
}

public struct CameraFolder: Identifiable, Hashable, Sendable {
    public let id: UInt32
    public let storageID: UInt32
    public let name: String
    public let isVideo: Bool
    /// 不分文件夹、整张卡平铺（相机不支持按文件夹列目录时的退路）。
    public var isFlat: Bool = false

    public init(id: UInt32, storageID: UInt32, name: String, isVideo: Bool, isFlat: Bool = false) {
        self.id = id
        self.storageID = storageID
        self.name = name
        self.isVideo = isVideo
        self.isFlat = isFlat
    }
}

/// 浏览、下载存储卡内容的接口。
public protocol CameraLibrary: AnyObject, Sendable {
    /// 所有含照片 / 视频的文件夹，新的在前。
    func folders() async throws -> [CameraFolder]
    /// 文件夹里的文件句柄，新的在前。只返回句柄，详细信息按需加载。
    func handles(in folder: CameraFolder) async throws -> [UInt32]
    func item(_ handle: UInt32) async throws -> CameraContentItem
    /// Exact known file path, without additional transport requests.
    func sourcePath(_ handle: UInt32) async -> String?
    func thumbnail(_ handle: UInt32) async throws -> Data?
    /// 大图预览（约 1600 px）；没有时返回缩略图。
    func preview(_ handle: UInt32) async throws -> Data?
    /// 拍摄参数。能直接读原文件的（读卡器）读原文件；做不到的返回 nil，上层从预览图里读。
    func exif(_ handle: UInt32) async -> ShotExif?
    /// 型号、序列号；拿不到时为 nil。
    var deviceInfo: CameraDeviceInfo? { get async }
    /// 用「按格式列文件」一次性得到文件夹里每个文件的类型；相机不支持时返回 nil。
    func kinds(in folder: CameraFolder) async -> [UInt32: CameraContentItem.Kind]?
    /// 下载到文件。`offset` > 0 时接着 `url` 里已有的前 `offset` 个字节往后写（断点续传）；
    /// 做不到续传的方式会忽略它，从头写。`progress` 报告的已完成字节数包含 `offset`。
    func download(_ item: CameraContentItem, to url: URL, from offset: UInt64,
                  progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws
    /// 视频片段的拍摄信息（M01.XML，或 MP4 末尾内嵌的同一份 XML）；拿不到时 nil。
    func clipInfo(_ handle: UInt32) async -> ClipInfo?
    /// 视频片段的 XML 原文（和卡上的 M01.XML 一字不差）；拿不到时 nil。
    func clipXML(_ handle: UInt32) async -> Data?
    /// 视频片段的代理（相机列表里和原片同一次拍摄的 SUB/C0001S03.MP4），用来下载；没有时 nil。
    func proxy(of handle: UInt32) async -> CameraContentItem?
    /// 照片在相机里打的星级（文件开头 XMP 的 xmp:Rating，0 = 没打星，-1 = 删除标记）；读不到时 nil。
    func rating(_ handle: UInt32) async -> Int?
    /// 丢掉列表缓存，下次 handles(in:) 重新读（相机里新拍的才会出现）。之前的句柄作废。
    func refresh() async
    /// 连接断开时发出一次。
    var connectionLost: AsyncStream<Void> { get }
    /// 列目录过程的诊断信息。
    var listingNotes: [String] { get async }
    func close() async
}

/// 基于标准 PTP 存储操作的实现。
public extension CameraLibrary {
    /// 从头下载。
    func download(_ item: CameraContentItem, to url: URL,
                  progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        try await download(item, to: url, from: 0, progress: progress)
    }
}

/// 打开要写入的文件：`offset` > 0 且文件里确实有这么多字节时，截到 `offset` 并定位到末尾；否则清空重写。
/// 返回实际的起点。
func openForResume(_ url: URL, offset: UInt64) throws -> (FileHandle, UInt64) {
    let existing = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? UInt64 ?? 0
    let start = offset > 0 && existing >= offset ? offset : 0
    if start == 0 || !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    let fh = try FileHandle(forWritingTo: url)
    try fh.truncate(atOffset: start)
    try fh.seek(toOffset: start)
    return (fh, start)
}

public actor PTPCameraLibrary: CameraLibrary {
    public func refresh() async { infoCache = [:] }
    private let client: PTPIPClient
    private let largeObjectReads: Bool
    private let fixedChunk: UInt32?
    private let onClose: @Sendable () async -> Void
    private var infoCache: [UInt32: PTPObjectInfo] = [:]
    public nonisolated let connectionLost: AsyncStream<Void>

    private let info: CameraDeviceInfo?
    public var deviceInfo: CameraDeviceInfo? { get async { info } }

    /// - largeObjectReads: 用索尼 0x9211 分块下载（内容传输模式下可用，支持 ≥4GB）。
    /// - deviceInfo: 连接时读到的型号和序列号（尼康等），没有时 nil。
    /// - chunkSize: 固定的分块下载大小（佳能要 1 MB）；nil 时按 contentChunkMB，默认 16 MB。
    public init(client: PTPIPClient, largeObjectReads: Bool = false, deviceInfo: CameraDeviceInfo? = nil,
                chunkSize: UInt32? = nil, onClose: @escaping @Sendable () async -> Void = {}) {
        self.info = deviceInfo
        self.fixedChunk = chunkSize
        self.client = client
        self.largeObjectReads = largeObjectReads
        self.onClose = onClose
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        connectionLost = stream
        // 事件流结束 = 连接断开（PTPIPClient 拆连接时会结束它）。
        let events = client.events
        Task {
            for await _ in events {}
            cont.yield()
            cont.finish()
        }
    }

    private func info(_ handle: UInt32) async throws -> PTPObjectInfo {
        if let cached = infoCache[handle] { return cached }
        let i = try await client.objectInfo(handle)
        infoCache[handle] = i
        return i
    }

    private func children(_ storage: UInt32, _ parent: UInt32) async throws -> [(UInt32, PTPObjectInfo)] {
        var out: [(UInt32, PTPObjectInfo)] = []
        for h in try await client.objectHandles(storage: storage, parent: parent) {
            out.append((h, try await info(h)))
        }
        return out
    }

    private func subfolder(_ items: [(UInt32, PTPObjectInfo)], named name: String) -> UInt32? {
        items.first { $0.1.isFolder && $0.1.filename.uppercased() == name }?.0
    }

    /// 最近一次列目录时的诊断信息（用了哪种方式、遇到什么错误）。
    public private(set) var listingNotes: [String] = []

    public func folders() async throws -> [CameraFolder] {
        listingNotes = []
        let storages = try await client.storageIDs()
        listingNotes.append("存储卡：\(storages.map { String(format: "0x%08X", $0) })")
        var hierarchical: [CameraFolder] = []
        var hierarchyError: Error?
        do {
            hierarchical = try await hierarchicalFolders(storages)
        } catch let e as PTPError {
            hierarchyError = e
            listingNotes.append("按文件夹读取失败：\(e.localizedDescription)")
        }
        if !hierarchical.isEmpty {
            listingNotes.append("按文件夹读取：\(hierarchical.map(\.name))")
            return hierarchical
        }
        // 退路：整张卡平铺列出（索尼相关开源实现都是这么做的）。
        var flat: [CameraFolder] = []
        for storage in storages {
            do {
                let all = try await client.objectHandles(storage: storage, parent: 0)
                listingNotes.append(String(format: "平铺读取 0x%08X：%d 个对象", storage, all.count))
                if !all.isEmpty {
                    let prefix = storages.count > 1 ? "卡槽\(storage >> 16) · " : ""
                    flat.append(CameraFolder(id: 0, storageID: storage, name: prefix + "全部文件", isVideo: false, isFlat: true))
                }
            } catch let e as PTPError {
                listingNotes.append(String(format: "平铺读取 0x%08X 失败：", storage) + e.localizedDescription)
                if storages.count == 1 { throw hierarchyError ?? e }
            }
        }
        return flat
    }

    private func hierarchicalFolders(_ storages: [UInt32]) async throws -> [CameraFolder] {
        var result: [CameraFolder] = []
        for storage in storages {
            // 双卡槽时在名字前标出卡槽（StorageID 高 16 位是物理卡槽号）。
            let prefix = storages.count > 1 ? "卡槽\(storage >> 16) · " : ""
            var local: [CameraFolder] = []
            let root = try await children(storage, ptpRootParent)
            // 照片：DCIM/100MSDCF、101MSDCF…
            if let dcim = subfolder(root, named: "DCIM") {
                let folders = try await children(storage, dcim).filter { $0.1.isFolder }
                local += folders.map { CameraFolder(id: $0.0, storageID: storage, name: prefix + $0.1.filename, isVideo: false) }
            }
            // 视频：PRIVATE/M4ROOT/CLIP
            if let priv = subfolder(root, named: "PRIVATE"),
               let m4 = subfolder(try await children(storage, priv), named: "M4ROOT"),
               let clip = subfolder(try await children(storage, m4), named: "CLIP") {
                local.append(CameraFolder(id: clip, storageID: storage, name: prefix + "视频", isVideo: true))
            }
            // 不符合 DCF 结构的卡（或相机平铺显示）：把根目录当一个文件夹。
            if local.isEmpty && root.contains(where: { !$0.1.isFolder }) {
                local.append(CameraFolder(id: ptpRootParent, storageID: storage, name: prefix + "根目录", isVideo: false))
            }
            result += local
        }
        // 文件夹名里的数字越大越新（105MSDCF 比 100MSDCF 新）；视频文件夹放最后。
        return result.sorted { a, b in
            if a.isVideo != b.isVideo { return !a.isVideo }
            return a.name.localizedStandardCompare(b.name) == .orderedDescending
        }
    }

    public func handles(in folder: CameraFolder) async throws -> [UInt32] {
        // 平铺模式：parent 传 0 表示整张卡的所有对象（文件夹本身会被界面当作非媒体文件隐藏）。
        let hs = try await client.objectHandles(storage: folder.storageID, parent: folder.isFlat ? 0 : folder.id)
        // 句柄通常随文件编号递增，倒序即新的在前。
        return hs.reversed()
    }

    public func item(_ handle: UInt32) async throws -> CameraContentItem {
        CameraContentItem(handle: handle, info: try await info(handle))
    }

    public func sourcePath(_ handle: UInt32) async -> String? {
        var current = handle
        var names: [String] = []
        var seen: Set<UInt32> = []
        while current != 0 && current != 0xFFFF_FFFF {
            guard seen.insert(current).inserted, let object = infoCache[current] else { return nil }
            names.append(object.filename)
            current = object.parent
        }
        return names.isEmpty ? nil : "/" + names.reversed().joined(separator: "/")
    }

    private var getThumbWorks: Bool?   // nil = 还没试过
    private var noteCount = 0

    private func note(_ s: String) {
        if noteCount < 30 { listingNotes.append(s); noteCount += 1 }
    }

    /// 缩略图：先用标准 GetThumb（索尼可能返回 JPEG 或 HEIF）；拿不到就读文件开头一段，取出嵌在 JPEG / RAW 里的小预览图。
    public func thumbnail(_ handle: UInt32) async throws -> Data? {
        let i = try await info(handle)
        let item = CameraContentItem(handle: handle, info: i)
        if getThumbWorks != false {
            do {
                let data = try await client.thumbnail(handle)
                if let image = Self.decodableImage(data) {
                    if getThumbWorks == nil {
                        note("缩略图：GetThumb 可用（\(Self.imageKind(image))，\(data.count) 字节，开头 \(Self.hexPrefix(data))）")
                    }
                    getThumbWorks = true
                    return image
                }
                if getThumbWorks == nil {
                    note("缩略图：GetThumb 返回 \(data.count) 字节，无法识别（开头 \(Self.hexPrefix(data))），改读文件内嵌预览")
                    getThumbWorks = false
                }
            } catch let e as PTPError {
                if getThumbWorks == nil {
                    note("缩略图：GetThumb 失败（\(e.localizedDescription)），改读文件内嵌预览")
                    getThumbWorks = false
                }
            }
        }
        guard item.kind == .jpeg || item.kind == .raw else { return nil }
        let headLength: UInt32 = 256 * 1024
        let head: Data
        if largeObjectReads {
            head = try await client.transaction(SonyOperation.getPartialLargeObject, [handle, 0, 0, headLength]).data
        } else {
            head = try await client.partialObject(handle, offset: 0, length: headLength)
        }
        let thumb = Self.embeddedJPEG(in: head)
        if thumb == nil { note("缩略图：\(i.filename) 开头 \(head.count) 字节里没找到内嵌预览") }
        return thumb
    }

    static func hexPrefix(_ d: Data) -> String {
        d.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    /// 能直接显示的图片数据：JPEG、HEIF/HEIC（ftyp 盒子）、PNG、TIFF；带了头部的话在里面找 JPEG。
    static func decodableImage(_ d: Data) -> Data? {
        let b = [UInt8](d.prefix(16))
        guard b.count >= 12 else { return nil }
        if b[0] == 0xFF && b[1] == 0xD8 { return d }
        if b[4] == 0x66 && b[5] == 0x74 && b[6] == 0x79 && b[7] == 0x70 { return d }   // "ftyp"
        if b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 { return d }   // PNG
        if (b[0] == 0x49 && b[1] == 0x49) || (b[0] == 0x4D && b[1] == 0x4D) { return d }  // TIFF
        // 有些相机在图片前加一段自己的头：找第一个完整的 JPEG。
        let bytes = [UInt8](d)
        if let start = (0..<max(0, bytes.count - 3)).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD8 && bytes[$0 + 2] == 0xFF }),
           let end = stride(from: bytes.count - 2, to: start, by: -1).first(where: { bytes[$0] == 0xFF && bytes[$0 + 1] == 0xD9 }) {
            return Data(bytes[start..<(end + 2)])
        }
        return nil
    }

    static func imageKind(_ d: Data) -> String {
        let b = [UInt8](d.prefix(12))
        if b.count >= 2 && b[0] == 0xFF && b[1] == 0xD8 { return "JPEG" }
        if b.count >= 12 && b[4] == 0x66 && b[5] == 0x74 { return "HEIF（\(String(decoding: b[8..<12], as: UTF8.self))）" }
        return "其他"
    }

    static func isJPEG(_ d: Data) -> Bool { d.count > 4 && d[d.startIndex] == 0xFF && d[d.startIndex + 1] == 0xD8 }

    /// 在文件开头找内嵌的 JPEG（EXIF 缩略图 / RAW 里的小预览）：跳过文件本身的 FFD8，找下一个完整的 FFD8…FFD9。
    static func embeddedJPEG(in data: Data) -> Data? {
        let b = [UInt8](data)
        var i = 2
        while i + 3 < b.count {
            if b[i] == 0xFF && b[i + 1] == 0xD8 && b[i + 2] == 0xFF {
                var j = i + 2
                while j + 1 < b.count {
                    if b[j] == 0xFF && b[j + 1] == 0xD9 {
                        if j + 2 - i > 1000 { return Data(b[i..<(j + 2)]) }
                        break
                    }
                    j += 1
                }
                i = j
            }
            i += 1
        }
        return nil
    }

    public func kinds(in folder: CameraFolder) async -> [UInt32: CameraContentItem.Kind]? {
        let parent = folder.isFlat ? 0 : folder.id
        guard let all = try? await client.objectHandles(storage: folder.storageID, parent: parent), !all.isEmpty else { return nil }
        let formats: [(UInt16, CameraContentItem.Kind)] = [
            (PTPObjectFormat.jpeg, .jpeg), (PTPObjectFormat.mpo, .jpeg), (PTPObjectFormat.heif, .heif),
            (PTPObjectFormat.sonyARW, .raw), (PTPObjectFormat.mp4, .video), (PTPObjectFormat.mov, .video),
            (CanonWiFi.formatCR3, .raw), (CanonWiFi.formatCR2, .raw), (CanonWiFi.formatMOV, .video),
        ]
        var map: [UInt32: CameraContentItem.Kind] = [:]
        var lists: [[UInt32]] = []
        for (format, kind) in formats {
            guard let hs = try? await client.objectHandles(storage: folder.storageID, format: format, parent: parent) else { continue }
            lists.append(hs)
            for h in hs { map[h] = kind }
        }
        // 相机忽略了格式参数（每种格式都返回全部文件）就不能用。
        let ignored = lists.filter { !$0.isEmpty }.count > 1 && lists.filter { !$0.isEmpty }.allSatisfy { $0.count == all.count }
        if ignored || map.isEmpty {
            note("按格式列文件：相机不支持（\(ignored ? "忽略了格式参数" : "全部为空")），改为逐个读取文件信息")
            return nil
        }
        note("按格式列文件：\(map.count)/\(all.count) 个媒体文件")
        return map
    }

    public func download(_ item: CameraContentItem, to url: URL, from offset: UInt64,
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        // 内容传输的分块大小（MB）。实测 a7 V：3 MB 17.1 MB/s，16 MB 18.3 MB/s，32 MB 18.6 MB/s；
        // 16 MB 在取消响应（约 0.9 秒）和吞吐之间比较平衡。可用 contentChunkMB 覆盖。
        let mb = UserDefaults.standard.integer(forKey: "contentChunkMB")
        let chunk = fixedChunk ?? UInt32((1...64).contains(mb) ? mb : 16) * 1024 * 1024
        try await client.download(item.id, size: item.sizeKnown ? item.size : nil, to: url, from: offset,
                                  largeObjectReads: largeObjectReads, chunkSize: chunk, progress: progress)
    }

    public func close() async {
        await onClose()
    }
}

public extension CameraLibrary {
    func exif(_ handle: UInt32) async -> ShotExif? { nil }
}
