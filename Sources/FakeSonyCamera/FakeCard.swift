import Foundation
import SonyRemoteKit

/// 模拟的存储卡：DCIM/100MSDCF、101MSDCF 里的照片，PRIVATE/M4ROOT/CLIP 里的视频。
public final class FakeCard: @unchecked Sendable {
    public struct Object: Sendable {
        public var info: PTPObjectInfo
        public var data: Data
        public var thumb: Data
    }

    public static let storageID: UInt32 = 0x0001_0001
    private let lock = NSLock()
    private var objects: [UInt32: Object] = [:]
    private var order: [UInt32] = []
    private var nextHandle: UInt32 = 1
    public private(set) var partialReads = 0
    /// 为 true 时模拟只支持平铺列目录的相机：按文件夹列（parent ≠ 0）返回 InvalidParameter。
    public var rejectHierarchicalListing = false
    /// 为 true 时模拟忽略格式参数的相机：按格式列文件也返回全部对象。
    public var ignoreFormatFilter = false

    public init() {}

    @discardableResult
    public func add(_ info: PTPObjectInfo, data: Data = Data(), thumb: Data = Data(), reportedSize: UInt32? = nil) -> UInt32 {
        lock.withLock {
            let h = nextHandle
            nextHandle += 1
            var i = info
            i.storageID = Self.storageID
            i.size = reportedSize ?? UInt32(data.count)
            i.thumbSize = UInt32(thumb.count)
            if !thumb.isEmpty { i.thumbFormat = PTPObjectFormat.jpeg }
            objects[h] = Object(info: i, data: data, thumb: thumb)
            order.append(h)
            return h
        }
    }

    public func folder(_ name: String, parent: UInt32) -> UInt32 {
        add(PTPObjectInfo(format: PTPObjectFormat.association, size: 0, parent: parent, filename: name, associationType: 1))
    }

    /// 生成一张典型的卡：两个照片文件夹（含 RAW+JPEG）和一个视频文件夹。
    public static func sample(photo: @escaping (String) -> Data, thumb: @escaping (String) -> Data,
                              photosPerFolder: Int = 6) -> FakeCard {
        let card = FakeCard()
        let dcim = card.folder("DCIM", parent: 0)
        var n = 1
        for folderName in ["100MSDCF", "101MSDCF"] {
            let f = card.folder(folderName, parent: dcim)
            for i in 0..<photosPerFolder {
                let name = String(format: "DSC%05d", n)
                let date = String(format: "202611%02dT%02d%02d00", 1 + n / 10, 9 + i, n % 60)
                if i % 3 == 0 {
                    card.add(PTPObjectInfo(format: PTPObjectFormat.sonyARW, size: 0, parent: f, filename: name + ".ARW",
                                           captureDate: date, imageWidth: 7008, imageHeight: 4672),
                             data: Data(repeating: UInt8(n), count: 300_000), thumb: thumb(name))
                }
                card.add(PTPObjectInfo(format: PTPObjectFormat.jpeg, size: 0, parent: f, filename: name + ".JPG",
                                       captureDate: date, imageWidth: 7008, imageHeight: 4672),
                         data: photo(name), thumb: thumb(name))
                n += 1
            }
        }
        let priv = card.folder("PRIVATE", parent: 0)
        let m4 = card.folder("M4ROOT", parent: priv)
        let clip = card.folder("CLIP", parent: m4)
        card.add(PTPObjectInfo(format: PTPObjectFormat.mp4, size: 0, parent: clip, filename: "C0001.MP4",
                               captureDate: "20261103T180000", imageWidth: 3840, imageHeight: 2160),
                 data: Data(repeating: 0x42, count: 500_000), thumb: thumb("C0001"))
        return card
    }

    /// 远程传输视角：同名（不含扩展名）的文件合成一次拍摄，按创建时间排序。
    private func contents() -> [(content: SonyContent, handles: [UInt32])] {
        var groups: [String: [UInt32]] = [:]
        var keys: [String] = []
        for h in order {
            guard let o = objects[h], o.info.format != PTPObjectFormat.association else { continue }
            let key = "\(o.info.parent)/\((o.info.filename as NSString).deletingPathExtension)"
            if groups[key] == nil { keys.append(key) }
            groups[key, default: []].append(h)
        }
        var out: [(SonyContent, [UInt32])] = []
        for (i, key) in keys.enumerated() {
            let hs = groups[key]!
            let first = objects[hs[0]]!.info
            let base = PTPObjectInfo.parseDate(first.captureDate).map { UInt64($0.timeIntervalSince1970 * 1000) } ?? 1_700_000_000_000
            let created = base + UInt64(i)   // 保证每次拍摄的时间不同
            let files = hs.enumerated().map { j, h in
                let o = objects[h]!
                return SonyContent.File(id: UInt16(j + 1), path: "A:/DCIM/100MSDCF/" + o.info.filename,
                                        format: UInt32(o.info.format), size: UInt64(o.data.count),
                                        width: o.info.imageWidth, height: o.info.imageHeight)
            }
            out.append((SonyContent(id: 0x0002_0000 + UInt32(i + 1), createdUTC: created, createdLocal: created, files: files), hs))
        }
        return out.sorted { $0.0.createdUTC < $1.0.createdUTC }
    }

    public private(set) var remoteListRequests = 0

    func remoteTransfer(_ code: UInt16, _ params: [UInt32]) -> FakeCamera.Reply? {
        lock.withLock {
            let all = contents()
            switch code {
            case SonyOperation.getCapturedDateList:
                var w = PTPWriter(); w.u32(UInt32(all.count)); all.forEach { w.u64($0.content.createdUTC) }
                return .init(data: w.data)
            case SonyOperation.getContentsInfoList:
                guard params.count >= 5, !all.isEmpty else { return nil }
                remoteListRequests += 1
                let cursor = UInt64(params[0]) | UInt64(params[1]) << 32
                let page = all.filter { $0.content.createdUTC > cursor }.prefix(Int(params[2])).map(\.content)
                return .init(data: SonyContent.encodeList(Array(page)))
            case SonyOperation.getContentsData, SonyOperation.getContentsCompressedData:
                guard params.count >= 3, let c = all.first(where: { $0.content.id == params[0] }) else { return nil }
                let fid = Int(params[1] & 0xFFFF)
                guard fid >= 1, fid <= c.handles.count, let o = objects[c.handles[fid - 1]] else { return nil }
                if code == SonyOperation.getContentsCompressedData {
                    // 参数 2 = screennail：模拟相机直接给原图（图本身不大）。
                    if params[2] == 2, o.data.starts(with: [0xFF, 0xD8]) { return .init(data: o.data) }
                    return o.thumb.isEmpty ? .init(code: 0x2010) : .init(data: o.thumb)
                }
                guard params.count >= 5 else { return nil }
                partialReads += 1
                let offset = Int(UInt64(params[2]) | UInt64(params[3]) << 32)
                let start = min(offset, o.data.count)
                let end = min(o.data.count, start + Int(params[4] & 0x7FFF_FFFF))
                return .init(data: o.data.subdata(in: start..<end))
            default:
                return nil
            }
        }
    }

    func handle(_ code: UInt16, _ params: [UInt32]) -> FakeCamera.Reply? {
        lock.withLock {
            switch code {
            case PTPOperation.getStorageIDs:
                var w = PTPWriter(); w.u32(1); w.u32(Self.storageID)
                return .init(data: w.data)
            case PTPOperation.getStorageInfo:
                let info = PTPStorageInfo(storageType: 4, filesystemType: 2, accessCapability: 0,
                                          maxCapacity: 128_000_000_000, freeSpace: 64_000_000_000,
                                          freeSpaceInImages: 2000, description: "SLOT1", volumeLabel: "")
                return .init(data: info.encoded())
            case PTPOperation.getObjectHandles:
                let parent = params.count > 2 ? params[2] : 0
                let format = params.count > 1 ? UInt16(params[1]) : 0
                if rejectHierarchicalListing && parent != 0 { return .init(code: 0x201D) }
                // PTP：parent 0 = 全部对象；0xFFFFFFFF = 根目录；其他 = 该文件夹的直接子项。
                let hs = order.filter {
                    guard let o = objects[$0] else { return false }
                    let inParent: Bool
                    switch parent {
                    case 0: inParent = true
                    case ptpRootParent: inParent = o.info.parent == 0
                    default: inParent = o.info.parent == parent
                    }
                    return inParent && (format == 0 || ignoreFormatFilter || o.info.format == format)
                }
                var w = PTPWriter(); w.u32(UInt32(hs.count)); hs.forEach { w.u32($0) }
                return .init(data: w.data)
            case PTPOperation.getObjectInfo:
                guard let h = params.first, let o = objects[h] else { return nil }
                return .init(data: o.info.encoded())
            case PTPOperation.getThumb:
                guard let h = params.first, let o = objects[h] else { return nil }
                return o.thumb.isEmpty ? .init(code: 0x2010) : .init(data: o.thumb)  // NoThumbnailPresent
            case PTPOperation.getPartialObject:
                guard params.count >= 3, let o = objects[params[0]] else { return nil }
                partialReads += 1
                let start = min(Int(params[1]), o.data.count)
                let end = min(o.data.count, start + Int(params[2]))
                return .init(data: o.data.subdata(in: start..<end))
            case SonyOperation.getPartialLargeObject:
                guard params.count >= 4, let o = objects[params[0]] else { return nil }
                guard params[3] != 0xFFFF_FFFF else { return .init(code: 0x201D) }  // 索尼不支持「读到底」
                partialReads += 1
                let offset = Int(UInt64(params[1]) | (UInt64(params[2]) << 32))
                let start = min(offset, o.data.count)
                let end = min(o.data.count, start + Int(params[3]))
                return .init(params: [UInt32(end - start)], data: o.data.subdata(in: start..<end))
            case PTPOperation.getObject:
                guard let h = params.first, let o = objects[h] else { return nil }
                return .init(data: o.data)
            default:
                return nil
            }
        }
    }
}
