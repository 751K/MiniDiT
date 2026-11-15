import Foundation

/// 大疆相机文件列表（0x00/0x26 请求，0x00/0x27 分块回复）的解析。
/// 资料来自 osmosis 的 MEDIA_PROTOCOL.md §1（MIT），见 THIRD_PARTY_NOTICES.md。
///
/// 回复的每块负载 = [10 字节子头][数据]：子头 +0 = 0x4A，+1 = 0x04 开始 / 0x01 数据 / 0x03 结束，
/// +4 = 请求里第 4 字节的计数（用来区分 SD 卡和内置存储两个查询）。拼起来的数据是 TLV 记录：
///   0d <len> "<base>.<ext>"                 文件名（只用来取扩展名）
///   1a <total> 00 00 00 01 "DCIM/…"         原片路径，不带扩展名
///   1a <total> 00 00 00 02 "MISC/THM/…"     缩略图路径
/// 每条记录有一个 `19 06` 标记，记它的位置为 T：句柄 u32 @ T−10，大小 u32 @ T−14，
/// FAT 时间 u32 @ T−18，时长 u16 @ T−6（秒），类型 u8 @ T−2，代理（.LRF）大小 u32 @ T+28。
public enum DJIManifest {
    public struct Record: Sendable, Equatable {
        /// 「DJI_20251115143000_0001_D.MP4」
        public var name: String
        /// 「DCIM/DJI_001/DJI_20251115143000_0001_D」，下载时补上扩展名。
        public var mediaPath: String
        /// 「MISC/THM/DJI_001/DJI_…」，缩略图，可能没有。
        public var thumbPath: String?
        public var handle: UInt32
        /// 0 = 不知道（≥ 4 GB 的片段这一栏是 0）。
        public var size: UInt32
        /// 0 = 列表里没有（Pocket 3 就没有），下载前用 HEAD 问。
        public var proxySize: UInt32
        /// FAT 打包的本地时间（2 秒精度）。
        public var fatTime: UInt32
        public var durationSeconds: UInt16
        /// 0 = SD 卡，1 = 内置存储（也是 HTTP /v2?storage= 的值）。
        public var store: Int

        public var ext: String { (name as NSString).pathExtension.uppercased() }
        public var isVideo: Bool { ext == "MP4" || ext == "MOV" }
        /// 下载路径：原片路径 + 扩展名。
        public var filePath: String { ext.isEmpty ? mediaPath : mediaPath + "." + (name as NSString).pathExtension }
        /// 代理和原片同名，扩展名换成 .LRF；列表里不单独出现。
        public var proxyPath: String? { isVideo ? mediaPath + ".LRF" : nil }

        /// FAT 时间 → yyyyMMdd'T'HHmmss（相机的本地时间）。
        public var captureDateRaw: String? {
            guard fatTime != 0 else { return nil }
            let date = fatTime >> 16, time = fatTime & 0xFFFF
            let y = 1980 + Int(date >> 9), mo = Int((date >> 5) & 0xF), d = Int(date & 0x1F)
            let h = Int(time >> 11), mi = Int((time >> 5) & 0x3F), s = Int(time & 0x1F) * 2
            guard (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 60 else { return nil }
            return String(format: "%04d%02d%02dT%02d%02d%02d", y, mo, d, h, mi, s)
        }
    }

    /// 某个计数（SD = 1，内置 = 2）对应的回复数据块按到达顺序拼起来；`counter` 为 nil 时不区分。
    public static func reassemble(_ frames: [DUMLFrame], counter: UInt8? = nil) -> [UInt8] {
        var out: [UInt8] = []
        for f in frames where f.matches(0x00, 0x27) {
            let p = f.payload
            guard p.count > 10, p[0] == 0x4A, p[1] == 0x01 else { continue }
            if let counter, p[4] != counter { continue }
            out += p[10...]
        }
        return out
    }

    /// 这个计数的回复是否已经收完：收到了结束块，或者开了头却一块数据都没有（空的存储会这样）。
    public static func ended(_ frames: [DUMLFrame], counter: UInt8) -> (answered: Bool, ended: Bool) {
        var start = false, data = false, end = false
        for f in frames where f.matches(0x00, 0x27) && f.payload.count > 4 && f.payload[0] == 0x4A && f.payload[4] == counter {
            switch f.payload[1] { case 0x04: start = true; case 0x01: data = true; case 0x03: end = true; default: break }
        }
        return (start || data || end, end)
    }

    /// 最后一页的标记：最后一条记录的文件名字段前有一个 `0c 01`。
    public static func hasEndMarker(_ buf: [UInt8]) -> Bool {
        guard buf.count >= 3 else { return false }
        for i in 0..<(buf.count - 2) where buf[i] == 0x0C && buf[i + 1] == 0x01 && buf[i + 2] == 0x0D { return true }
        return false
    }

    private static func path(_ buf: [UInt8], _ i: Int, sub: UInt8, prefix: String) -> (String, Int)? {
        guard i + 6 <= buf.count, buf[i] == 0x1A, buf[i + 2] == 0, buf[i + 3] == 0, buf[i + 4] == 0, buf[i + 5] == sub else { return nil }
        let len = Int(buf[i + 1]) - 6
        guard len >= prefix.utf8.count, i + 6 + len <= buf.count else { return nil }
        let s = String(decoding: buf[(i + 6)..<(i + 6 + len)], as: UTF8.self)
        return s.hasPrefix(prefix) ? (s, i + 6 + len) : nil
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 {
        guard i >= 0, i + 2 <= b.count else { return 0 }
        return UInt16(b[i]) | UInt16(b[i + 1]) << 8
    }

    /// 以每条记录的原片路径为锚，其余字段只在这条记录的范围内找（两种字段顺序都有，越界会读到相邻记录）。
    public static func decode(_ buf: [UInt8], store: Int = 0) -> [Record] {
        var anchors: [(pos: Int, end: Int, path: String)] = []
        var i = 0
        while i < buf.count {
            if let (p, end) = path(buf, i, sub: 1, prefix: "DCIM/") { anchors.append((i, end, p)); i = end } else { i += 1 }
        }
        var out: [Record] = []
        for (k, a) in anchors.enumerated() {
            let lo = k > 0 ? anchors[k - 1].end : 0
            let hi = k + 1 < anchors.count ? anchors[k + 1].pos : buf.count
            let base = String(a.path.split(separator: "/").last ?? "")

            // 扩展名：0d 文件名字段里「<base>.」后面的部分。
            var ext = ""
            let needle = Array((base + ".").utf8)
            var j = lo
            while j + 2 + needle.count <= hi {
                if buf[j] == 0x0D, Array(buf[(j + 2)..<(j + 2 + needle.count)]) == needle {
                    let end = min(j + 2 + Int(buf[j + 1]), buf.count)
                    if end > j + 2 + needle.count { ext = String(decoding: buf[(j + 2 + needle.count)..<end], as: UTF8.self) }
                    break
                }
                j += 1
            }

            // 缩略图路径紧跟在原片路径后面（两种字段顺序都是），从原片路径的末尾开始找。
            var thumb: String?
            var t = a.end
            while t < hi {
                if let (p, _) = path(buf, t, sub: 2, prefix: "MISC/") { thumb = p; break }
                t += 1
            }

            // `19 06` 标记：Pocket 3 等原片路径紧跟在 T 后面的机型，T = 路径字段 − 7；
            // 其他机型在记录范围内找前一字节是 fe / ff 的 `19 06`。
            var tag: Int?
            let q = a.pos - 7
            if q >= 18, buf[q] == 0x19, buf[q + 1] == 0x06 { tag = q }
            else {
                var p = max(lo, 1)
                while p < a.pos - 1 {
                    if buf[p] == 0x19, buf[p + 1] == 0x06, buf[p - 1] == 0xFE || buf[p - 1] == 0xFF { tag = p; break }
                    p += 1
                }
            }
            var r = Record(name: ext.isEmpty ? base : base + "." + ext, mediaPath: a.path, thumbPath: thumb,
                           handle: 0, size: 0, proxySize: 0, fatTime: 0, durationSeconds: 0, store: store)
            if let T = tag {
                r.handle = u32(buf, T - 10)
                r.size = u32(buf, T - 14)
                r.fatTime = u32(buf, T - 18)
                if r.isVideo {
                    r.durationSeconds = u16(buf, T - 6)
                    // 代理大小在 T+28，只适用于枚举块紧跟 T 的机型；Pocket 3 的 T+7 就是原片路径，T+28 落在路径里。
                    if T + 32 <= hi, T + 7 < buf.count, buf[T + 7] != 0x1A { r.proxySize = u32(buf, T + 28) }
                }
            }
            out.append(r)
        }
        return out
    }

    /// 文件列表请求。`counter` 放在第 4 字节（回复的子头带回来），`cursor` = 1（SD 最新一页）、
    /// 0x40000001（内置最新一页），或上一页里最旧的句柄（再往前一页）。每页 45 条。
    public static func listQuery(counter: UInt8, cursor: UInt32) -> [UInt8] {
        var p: [UInt8] = [0x4A, 0x00, 0x2A, 0x10, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x2D, 0x00,
                          0x0D, 0x01, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x01, 0x00, 0x00, 0x00,
                          0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
        p[4] = counter
        p[10] = UInt8(cursor & 0xFF); p[11] = UInt8((cursor >> 8) & 0xFF)
        p[12] = UInt8((cursor >> 16) & 0xFF); p[13] = UInt8(cursor >> 24)
        return p
    }

    /// 两个查询之间的触发帧。
    public static let listTrigger: [UInt8] = [0x4A, 0x04, 0x0E, 0x10, 0x01, 0, 0, 0, 0, 0, 0x01, 0, 0, 0]
}
