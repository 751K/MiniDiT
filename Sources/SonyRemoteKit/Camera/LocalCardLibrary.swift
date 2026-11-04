import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 读卡器 / 已挂载的存储卡：和 Wi-Fi 相机用同一套接口，上层不用区分来源。
/// 照片在 DCIM/ 下，索尼视频在 PRIVATE/M4ROOT/CLIP/ 下（缩略图在 PRIVATE/M4ROOT/THMBNL/）。
public actor LocalCardLibrary: CameraLibrary {
    private struct Entry {
        let url: URL
        let item: CameraContentItem
    }

    public nonisolated let root: URL
    public nonisolated let connectionLost: AsyncStream<Void>
    private nonisolated let lostContinuation: AsyncStream<Void>.Continuation
    public private(set) var listingNotes: [String] = []
    private var entries: [UInt32: Entry] = [:]
    private var listed: [UInt32]?

    /// 读卡器当作卡槽 1。
    public static let storageID: UInt32 = 1 << 16 | 1

    public init(root: URL) {
        self.root = root
        let (stream, cont) = AsyncStream.makeStream(of: Void.self)
        connectionLost = stream
        lostContinuation = cont
    }

    /// 这个文件夹（卷）看起来是不是相机存储卡。
    public static func looksLikeCard(_ url: URL) -> Bool {
        let fm = FileManager.default
        var dir: ObjCBool = false
        if fm.fileExists(atPath: url.appending(path: "DCIM").path, isDirectory: &dir), dir.boolValue { return true }
        return fm.fileExists(atPath: url.appending(path: "PRIVATE/M4ROOT/CLIP").path, isDirectory: &dir) && dir.boolValue
    }

    /// 卡被拔掉 / 推出时由上层调用。
    public nonisolated func markLost() {
        lostContinuation.yield()
        lostContinuation.finish()
    }

    public func folders() async throws -> [CameraFolder] {
        [CameraFolder(id: 1, storageID: Self.storageID, name: root.lastPathComponent, isVideo: false, isFlat: true)]
    }

    public func handles(in folder: CameraFolder) async throws -> [UInt32] {
        if let listed { return listed }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyyMMdd'T'HHmmss"
        var fromExif = 0
        // 拍摄时间用相机自己的钟（照片 EXIF / 视频 XML），和 Wi-Fi 读到的一致；
        // 文件修改时间经过时区换算，相机和 Mac 时区或夏令时设置不同时会差几个小时。
        var found: [(url: URL, date: Date, size: UInt64, raw: String)] = []
        for (url, date, size) in try Self.scan(root) {
            try Task.checkCancellation()
            if let raw = Self.cameraClock(url) {
                fromExif += 1
                found.append((url, date, size, raw))
            } else {
                found.append((url, date, size, date == .distantPast ? "" : fmt.string(from: date)))
            }
        }
        // 新的在前；同一时间按文件名，保证 RAW 和 JPEG 挨在一起。
        found.sort { $0.raw != $1.raw ? $0.raw > $1.raw : $0.url.lastPathComponent < $1.url.lastPathComponent }
        var hs: [UInt32] = []
        for (i, f) in found.enumerated() {
            let h = UInt32(i + 1)
            let item = CameraContentItem(id: h, storageID: Self.storageID, filename: f.url.lastPathComponent,
                                         format: Self.format(for: f.url.lastPathComponent) ?? 0, size: f.size,
                                         captureDate: f.date == .distantPast ? nil : f.date,
                                         captureDateRaw: f.raw, width: 0, height: 0)
            entries[h] = Entry(url: f.url, item: item)
            hs.append(h)
        }
        if fromExif < hs.count { listingNotes.append("存储卡：\(hs.count - fromExif) 个文件没有拍摄时间，用了文件修改时间") }
        listingNotes.append("存储卡 \(root.path)：\(hs.count) 个文件")
        listed = hs
        return hs
    }

    /// 相机记录的本地拍摄时间（yyyyMMdd'T'HHmmss）：照片读 EXIF，索尼视频读同名的 M01.XML。
    static func cameraClock(_ url: URL) -> String? {
        let ext = url.pathExtension.uppercased()
        var text: String?
        if ext == "MP4" || ext == "MOV" {
            // C0001.MP4 → C0001M01.XML：<CreationDate value="2026-10-17T16:58:49+01:00"/>
            let xml = url.deletingPathExtension().appendingPathExtension("XML")
            let named = url.deletingLastPathComponent().appending(path: url.deletingPathExtension().lastPathComponent + "M01.XML")
            for u in [named, xml] {
                guard let h = try? FileHandle(forReadingFrom: u), let d = try? h.read(upToCount: 8192),
                      let s = String(data: d, encoding: .utf8),
                      let r = s.range(of: #"CreationDate value="([0-9T:\-]{19})"#, options: .regularExpression) else { continue }
                text = String(s[r].suffix(19))
                break
            }
        } else {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
                  let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] else { return nil }
            text = (exif[kCGImagePropertyExifDateTimeOriginal] ?? exif[kCGImagePropertyExifDateTimeDigitized]) as? String
        }
        // 「2026:10:17 16:58:49」或「2026-10-17T16:58:49」→「20261017T165849」
        guard let t = text else { return nil }
        let digits = t.filter(\.isNumber)
        guard digits.count >= 14 else { return nil }
        return String(digits.prefix(8)) + "T" + String(digits.dropFirst(8).prefix(6))
    }

    /// 同步遍历（FileManager 的枚举器不能在 async 上下文里迭代）。
    static func scan(_ root: URL) throws -> [(URL, Date, UInt64)] {
        var found: [(URL, Date, UInt64)] = []
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        for sub in ["DCIM", "PRIVATE/M4ROOT/CLIP"] {
            let dir = root.appending(path: sub, directoryHint: .isDirectory)
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = e.nextObject() as? URL {
                if Task.isCancelled { throw CancellationError() }
                guard format(for: url.lastPathComponent) != nil,
                      let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                found.append((url, v.contentModificationDate ?? .distantPast, UInt64(v.fileSize ?? 0)))
            }
        }
        return found
    }

    static func format(for name: String) -> UInt16? {
        switch (name as NSString).pathExtension.uppercased() {
        case "JPG", "JPEG": PTPObjectFormat.jpeg
        case "HIF", "HEIF", "HEIC": PTPObjectFormat.heif
        case "ARW": PTPObjectFormat.sonyARW
        case "MP4": PTPObjectFormat.mp4
        case "MOV": PTPObjectFormat.mov
        default: nil
        }
    }

    private func entry(_ handle: UInt32) throws -> Entry {
        guard let e = entries[handle] else { throw CocoaError(.fileNoSuchFile) }
        return e
    }

    /// 卡上文件的位置（读卡器来源可以直接从这里复制）。
    public func fileURL(_ handle: UInt32) -> URL? { entries[handle]?.url }

    public func item(_ handle: UInt32) async throws -> CameraContentItem { try entry(handle).item }

    public func kinds(in folder: CameraFolder) async -> [UInt32: CameraContentItem.Kind]? {
        guard let listed else { return nil }
        var map: [UInt32: CameraContentItem.Kind] = [:]
        for h in listed { if let e = entries[h] { map[h] = e.item.kind } }
        return map
    }

    public func thumbnail(_ handle: UInt32) async throws -> Data? { try image(handle, maxPixel: 320) }

    public func preview(_ handle: UInt32) async throws -> Data? { try image(handle, maxPixel: 1800) }

    private func image(_ handle: UInt32, maxPixel: Int) throws -> Data? {
        let e = try entry(handle)
        var source = e.url
        if e.item.kind == .video {
            // C0001.MP4 → PRIVATE/M4ROOT/THMBNL/C0001T01.JPG
            let thumb = e.url.deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "THMBNL").appending(path: e.item.baseName + "T01.JPG")
            guard FileManager.default.fileExists(atPath: thumb.path) else { return nil }
            source = thumb
        }
        guard let src = CGImageSourceCreateWithURL(source as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return out as Data
    }

    public func download(_ item: CameraContentItem, to url: URL,
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        let e = try entry(item.id)
        let input = try FileHandle(forReadingFrom: e.url)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        let total = e.item.size
        var done: UInt64 = 0
        while true {
            try Task.checkCancellation()
            guard let chunk = try input.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            done += UInt64(chunk.count)
            progress(done, total)
        }
        guard done == total else { throw CocoaError(.fileReadCorruptFile) }
    }

    public func close() async {}
}
