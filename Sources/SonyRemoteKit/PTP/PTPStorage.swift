import Foundation

extension PTPOperation {
    public static let getStorageInfo: UInt16 = 0x1005
    public static let getNumObjects: UInt16 = 0x1006
    public static let getThumb: UInt16 = 0x100A
    public static let getPartialObject: UInt16 = 0x101B
}

/// 标准 PTP 对象格式码（只列出用得到的）。
public enum PTPObjectFormat {
    public static let association: UInt16 = 0x3001   // 文件夹
    public static let jpeg: UInt16 = 0x3801
    public static let tiff: UInt16 = 0x380D
    public static let heif: UInt16 = 0xB110
    public static let sonyARW: UInt16 = 0xB101
    public static let dng: UInt16 = 0x3811
    /// 未定义格式：尼康 NEF 用它。
    public static let undefined: UInt16 = 0x3000
    public static let mpo: UInt16 = 0xB301
    public static let mp4: UInt16 = 0xB982
    public static let mov: UInt16 = 0x300D
    public static let avi: UInt16 = 0x300A
}

/// 根目录的父句柄。
public let ptpRootParent: UInt32 = 0xFFFF_FFFF

public struct PTPStorageInfo: Sendable, Equatable {
    public let storageType: UInt16
    public let filesystemType: UInt16
    public let accessCapability: UInt16
    public let maxCapacity: UInt64
    public let freeSpace: UInt64
    public let freeSpaceInImages: UInt32
    public let description: String
    public let volumeLabel: String

    public init(storageType: UInt16, filesystemType: UInt16, accessCapability: UInt16, maxCapacity: UInt64,
                freeSpace: UInt64, freeSpaceInImages: UInt32, description: String, volumeLabel: String) {
        self.storageType = storageType
        self.filesystemType = filesystemType
        self.accessCapability = accessCapability
        self.maxCapacity = maxCapacity
        self.freeSpace = freeSpace
        self.freeSpaceInImages = freeSpaceInImages
        self.description = description
        self.volumeLabel = volumeLabel
    }

    public static func parse(_ data: Data) throws -> PTPStorageInfo {
        var r = PTPReader(data)
        return PTPStorageInfo(storageType: try r.u16(), filesystemType: try r.u16(), accessCapability: try r.u16(),
                              maxCapacity: try r.u64(), freeSpace: try r.u64(), freeSpaceInImages: try r.u32(),
                              description: try r.ptpString(), volumeLabel: try r.ptpString())
    }

    public func encoded() -> Data {
        var w = PTPWriter()
        w.u16(storageType); w.u16(filesystemType); w.u16(accessCapability)
        w.u64(maxCapacity); w.u64(freeSpace); w.u32(freeSpaceInImages)
        w.ptpString(description); w.ptpString(volumeLabel)
        return w.data
    }
}

/// 完整的 PTP ObjectInfo。
public struct PTPObjectInfo: Sendable, Equatable {
    public var storageID: UInt32
    public var format: UInt16
    public var protection: UInt16
    public var size: UInt32
    public var thumbFormat: UInt16
    public var thumbSize: UInt32
    public var thumbWidth: UInt32
    public var thumbHeight: UInt32
    public var imageWidth: UInt32
    public var imageHeight: UInt32
    public var bitDepth: UInt32
    public var parent: UInt32
    public var associationType: UInt16
    public var associationDesc: UInt32
    public var sequenceNumber: UInt32
    public var filename: String
    public var captureDate: String
    public var modificationDate: String
    public var keywords: String

    public init(storageID: UInt32 = 0x0001_0001, format: UInt16, size: UInt32, parent: UInt32, filename: String,
                captureDate: String = "", thumbFormat: UInt16 = 0, thumbSize: UInt32 = 0,
                imageWidth: UInt32 = 0, imageHeight: UInt32 = 0, associationType: UInt16 = 0) {
        self.storageID = storageID
        self.format = format
        self.protection = 0
        self.size = size
        self.thumbFormat = thumbFormat
        self.thumbSize = thumbSize
        self.thumbWidth = thumbSize > 0 ? 160 : 0
        self.thumbHeight = thumbSize > 0 ? 120 : 0
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.bitDepth = 0
        self.parent = parent
        self.associationType = associationType
        self.associationDesc = 0
        self.sequenceNumber = 0
        self.filename = filename
        self.captureDate = captureDate
        self.modificationDate = captureDate
        self.keywords = ""
    }

    public var isFolder: Bool { format == PTPObjectFormat.association }

    public static func parse(_ data: Data) throws -> PTPObjectInfo {
        var r = PTPReader(data)
        var o = PTPObjectInfo(format: 0, size: 0, parent: 0, filename: "")
        o.storageID = try r.u32()
        o.format = try r.u16()
        o.protection = try r.u16()
        o.size = try r.u32()
        o.thumbFormat = try r.u16()
        o.thumbSize = try r.u32()
        o.thumbWidth = try r.u32()
        o.thumbHeight = try r.u32()
        o.imageWidth = try r.u32()
        o.imageHeight = try r.u32()
        o.bitDepth = try r.u32()
        o.parent = try r.u32()
        o.associationType = try r.u16()
        o.associationDesc = try r.u32()
        o.sequenceNumber = try r.u32()
        o.filename = try r.ptpString()
        // 日期和关键字可能缺省。
        o.captureDate = (try? r.ptpString()) ?? ""
        o.modificationDate = (try? r.ptpString()) ?? ""
        o.keywords = (try? r.ptpString()) ?? ""
        return o
    }

    public func encoded() -> Data {
        var w = PTPWriter()
        w.u32(storageID); w.u16(format); w.u16(protection); w.u32(size)
        w.u16(thumbFormat); w.u32(thumbSize); w.u32(thumbWidth); w.u32(thumbHeight)
        w.u32(imageWidth); w.u32(imageHeight); w.u32(bitDepth); w.u32(parent)
        w.u16(associationType); w.u32(associationDesc); w.u32(sequenceNumber)
        w.ptpString(filename); w.ptpString(captureDate); w.ptpString(modificationDate); w.ptpString(keywords)
        return w.data
    }

    /// PTP 日期：YYYYMMDDThhmmss[.s][Z|±hhmm]。没有时区时按本地时间。
    public var captureDateValue: Date? { Self.parseDate(captureDate.isEmpty ? modificationDate : captureDate) }

    public static func parseDate(_ s: String) -> Date? {
        let digits = s.prefix(15)
        guard digits.count == 15 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        let rest = s.dropFirst(15).drop { $0 == "." || $0.isNumber }
        if rest.hasPrefix("Z") {
            f.timeZone = TimeZone(identifier: "UTC")
        } else if let sign = rest.first, sign == "+" || sign == "-", rest.count >= 5,
                  let hh = Int(rest.dropFirst().prefix(2)), let mm = Int(rest.dropFirst(3).prefix(2)) {
            f.timeZone = TimeZone(secondsFromGMT: (sign == "-" ? -1 : 1) * (hh * 3600 + mm * 60))
        }
        return f.date(from: String(digits))
    }
}

extension PTPTransport {
    public func storageIDs() async throws -> [UInt32] {
        var r = PTPReader(try await transaction(PTPOperation.getStorageIDs).data)
        // 0x00010000 这类低 16 位为 0 的 ID 表示「卡槽空 / 不可用」。
        return try r.array { try $0.u32() }.filter { $0 & 0xFFFF != 0 }
    }

    public func storageInfo(_ id: UInt32) async throws -> PTPStorageInfo {
        try PTPStorageInfo.parse(try await transaction(PTPOperation.getStorageInfo, [id]).data)
    }

    /// 列出某个文件夹下的对象。parent 传 ptpRootParent 表示根目录。
    public func objectHandles(storage: UInt32, format: UInt16 = 0, parent: UInt32) async throws -> [UInt32] {
        var r = PTPReader(try await transaction(PTPOperation.getObjectHandles, [storage, UInt32(format), parent]).data)
        return try r.array { try $0.u32() }
    }

    public func objectInfo(_ handle: UInt32) async throws -> PTPObjectInfo {
        try PTPObjectInfo.parse(try await transaction(PTPOperation.getObjectInfo, [handle]).data)
    }

    public func thumbnail(_ handle: UInt32) async throws -> Data {
        try await transaction(PTPOperation.getThumb, [handle]).data
    }

    public func partialObject(_ handle: UInt32, offset: UInt32, length: UInt32) async throws -> Data {
        try await transaction(PTPOperation.getPartialObject, [handle, offset, length]).data
    }

    /// 下载对象到文件。
    /// - size: ObjectInfo 里的大小；nil 表示未知（≥4GB 的文件在 ObjectInfo 里是 0xFFFFFFFF）。
    /// - largeObjectReads: 相机支持索尼 0x9211（64 位偏移）时用它分块，任何大小都安全。
    /// 每块之间让出命令通道，取景、缩略图等请求可以插进来；也在块之间响应取消。
    /// - from: 断点续传的起点（`url` 里已有的字节数）；只有分块读取的方式能续传，整体读取时从头来。
    public func download(_ handle: UInt32, size: UInt64?, to url: URL, from resume: UInt64 = 0, largeObjectReads: Bool = false,
                         chunkSize: UInt32 = 3 * 1024 * 1024,
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void = { _, _ in }) async throws {
        let chunked = largeObjectReads || (size.map { $0 > 0 && $0 < UInt64(UInt32.max) } ?? false)
        let (fh, start) = try openForResume(url, offset: chunked ? resume : 0)
        defer { try? fh.close() }

        if largeObjectReads {
            var offset: UInt64 = start
            while size.map({ offset < $0 }) ?? true {
                try Task.checkCancellation()
                let want = size.map { UInt32(min(UInt64(chunkSize), $0 - offset)) } ?? chunkSize
                let r = try await transaction(SonyOperation.getPartialLargeObject,
                                              [handle, UInt32(offset & 0xFFFF_FFFF), UInt32(offset >> 32), want])
                try fh.write(contentsOf: r.data)
                offset += UInt64(r.data.count)
                progress(offset, max(size ?? offset, offset))
                // 大小未知时，读到的比要的少就说明到头了。
                if r.data.count < Int(want) {
                    if size == nil || r.data.isEmpty { break }
                }
            }
            if let size, offset < size { throw PTPDecodeError.invalid("文件不完整：\(offset)/\(size) 字节") }
            return
        }

        if let size, size > 0, size < UInt64(UInt32.max) {
            var offset: UInt64 = start
            while offset < size {
                try Task.checkCancellation()
                let want = UInt32(min(UInt64(chunkSize), size - offset))
                let chunk = try await partialObject(handle, offset: UInt32(offset), length: want)
                guard !chunk.isEmpty else { throw PTPDecodeError.invalid("相机返回了空数据块") }
                try fh.write(contentsOf: chunk)
                offset += UInt64(chunk.count)
                progress(offset, size)
            }
            return
        }

        // 大小未知：GetObject 边收边写盘，内存占用与文件大小无关；总大小取 StartData 里的 64 位长度。
        let counter = StreamCounter()
        try await streamingTransaction(PTPOperation.getObject, [handle], onStart: { counter.setTotal($0) }) { chunk in
            try Task.checkCancellation()
            try fh.write(contentsOf: chunk)
            let (done, total) = counter.add(UInt64(chunk.count))
            progress(done, max(total, done))
        }
    }
}

/// 流式下载时记录总大小和已写字节数。
private final class StreamCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: UInt64 = 0
    private var done: UInt64 = 0
    func setTotal(_ t: UInt64) { lock.withLock { total = t } }
    func add(_ n: UInt64) -> (UInt64, UInt64) { lock.withLock { done += n; return (done, total) } }
}
