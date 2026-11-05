import Foundation
import ImageIO

/// 索尼的「创意外观」（Creative Look）：拍摄时选的 ST / PT / FL…，记在 RAW 文件厂商信息（MakerNote）的 0xb020 里。
/// 这一项是明文（不在加密的那部分里），老机型叫「创意风格」，值是英文全称（Standard、Vivid…），新的外观直接写代号。
enum CreativeLook {
    /// 0xb020 里的原文 → 外观代号（和 ICC 配置文件名里的「Look-ST」对应）。
    private static let codes: [String: String] = [
        "Standard": "ST", "Portrait": "PT", "Neutral": "NT", "Vivid": "VV", "BW": "BW", "Sepia": "SE",
        "VV2": "VV2", "FL": "FL", "FL2": "FL2", "FL3": "FL3", "IN": "IN", "SH": "SH",
        "ST": "ST", "PT": "PT", "NT": "NT", "VV": "VV", "SE": "SE",
    ]
    static let all = ["ST", "PT", "NT", "VV", "VV2", "FL", "FL2", "FL3", "IN", "SH", "BW", "SE"]

    /// 读 RAW（TIFF 结构的 ARW）里的外观代号。读不到、不认识时为 nil。
    static func code(ofRaw url: URL) -> String? {
        raw(url).flatMap { codes[$0] }
    }

    /// 0xb020 的原文（日志用）。
    static func raw(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 2_000_000), d.count > 16 else { return nil }
        return parse([UInt8](d))
    }

    private static func parse(_ d: [UInt8]) -> String? {
        let little: Bool
        if d[0] == 0x49, d[1] == 0x49 { little = true } else if d[0] == 0x4D, d[1] == 0x4D { little = false } else { return nil }
        func u16(_ o: Int) -> Int? {
            guard o >= 0, o + 2 <= d.count else { return nil }
            return little ? Int(d[o]) | Int(d[o + 1]) << 8 : Int(d[o]) << 8 | Int(d[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard o >= 0, o + 4 <= d.count else { return nil }
            let b = (0..<4).map { Int(d[o + $0]) }
            return little ? b[0] | b[1] << 8 | b[2] << 16 | b[3] << 24 : b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]
        }
        /// 一个 IFD 里某个标签的（类型、个数、值或偏移所在位置）。
        func entry(_ ifd: Int, _ tag: Int) -> (type: Int, count: Int, at: Int)? {
            guard let n = u16(ifd), n < 1000 else { return nil }
            for i in 0..<n {
                let p = ifd + 2 + 12 * i
                if u16(p) == tag, let t = u16(p + 2), let c = u32(p + 4) { return (t, c, p + 8) }
            }
            return nil
        }
        guard let ifd0 = u32(4), let exif = entry(ifd0, 0x8769).flatMap({ u32($0.at) }),
              let mn = entry(exif, 0x927C), let mnOff = u32(mn.at) else { return nil }
        // 索尼的 MakerNote 开头是「SONY DSC \0\0\0」，后面是 IFD，偏移仍从文件头（TIFF 头）算。
        let sony = mnOff + 12 <= d.count && Array(d[mnOff..<mnOff + 4]) == Array("SONY".utf8)
        guard let e = entry(sony ? mnOff + 12 : mnOff, 0xB020), e.type == 2 else { return nil }
        let start = e.count <= 4 ? e.at : (u32(e.at) ?? -1)
        guard start >= 0, start + e.count <= d.count else { return nil }
        let bytes = d[start..<start + e.count].prefix { $0 != 0 }
        let s = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return s.isEmpty ? nil : s
    }
}

/// 装在 Camera Raw 里的 Look 配置文件（XMP，LrC 和 ACR 共用）：按机型和外观代号找名字。
/// 文件里有 crs:CameraModelRestriction（「Sony ILCE-7M5」）和名字（「SonyA7M5 Look FL」）。
enum LightroomLooks {
    struct Profile: Hashable { let model: String; let code: String; let name: String; let file: URL }

    static var folders: [URL] {
        [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Adobe/CameraRaw/Settings"),
         URL(filePath: "/Library/Application Support/Adobe/CameraRaw/Settings")]
    }

    /// 扫一遍装好的 Look。名字以「Look 代号」结尾的才算。
    static func installed() -> [Profile] {
        var out: Set<Profile> = []
        for dir in folders {
            guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let u as URL in e where u.pathExtension.lowercased() == "xmp" {
                guard let s = try? String(contentsOf: u, encoding: .utf8), s.contains("crs:PresetType=\"Look\"") else { continue }
                guard let model = value(s, "crs:CameraModelRestriction=\"", "\""),
                      let name = value(s, "<rdf:li xml:lang=\"x-default\">", "</rdf:li>") else { continue }
                let parts = name.split(separator: " ")
                guard parts.count >= 2, parts[parts.count - 2] == "Look" else { continue }
                let code = String(parts.last!)
                if CreativeLook.all.contains(code) { out.insert(Profile(model: model, code: code, name: name, file: u)) }
            }
        }
        return out.sorted { ($0.model, CreativeLook.all.firstIndex(of: $0.code) ?? 99) < ($1.model, CreativeLook.all.firstIndex(of: $1.code) ?? 99) }
    }

    private static func value(_ s: String, _ start: String, _ end: String) -> String? {
        guard let a = s.range(of: start), let b = s.range(of: end, range: a.upperBound..<s.endIndex) else { return nil }
        let v = String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// 这张 RAW 该用哪个 Look（返回配置文件 XMP 的位置，插件读它）：机型取 EXIF 的「Sony」+「ILCE-7M5」，外观取 0xb020。没装就是 nil。
    static func profile(for raw: URL) -> String? {
        guard let code = CreativeLook.code(ofRaw: raw),
              let src = CGImageSourceCreateWithURL(raw as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let model = tiff[kCGImagePropertyTIFFModel] as? String else { return nil }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String)?.split(separator: " ").first.map(String.init) ?? "Sony"
        let full = model.hasPrefix(make) ? model : make + " " + model
        return installed().first { $0.model.caseInsensitiveCompare(full) == .orderedSame && $0.code == code }?.file.path
    }
}
