import CryptoKit
import Foundation
import MiniDiTCore

/// 写 ASC MHL v2.0 校验清单（https://theasc.com/society/ascmitc/asc-media-hash-list）。
///
/// 清单放在被管理的文件夹根目录下的 `ascmhl/` 里：每次导入追加一份 `0001_文件夹名_日期Z.mhl`，
/// 并在 `ascmhl_chain.xml` 里登记它的 C4 指纹，防止事后被改。别的 DIT 软件（比如 `ascmhl verify`）可以直接核对。
enum MHLWriter {
    struct Entry {
        enum Action: String { case original, verified }
        var url: URL
        var xxh64: UInt64
        var action: Action
    }

    /// 在 `root` 下追加一份清单，返回清单文件的位置。只登记在 `root` 里面的文件。
    @discardableResult
    static func append(root: URL, entries: [Entry], ignore: [String] = [], date: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let dir = root.appending(path: "ascmhl", directoryHint: .isDirectory)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let chainURL = dir.appending(path: "ascmhl_chain.xml")
        var chain = readChain(chainURL)
        let seq = (chain.map(\.seq).max() ?? 0) + 1
        let name = String(format: "%04d", seq) + "_" + fileSafe(root.lastPathComponent) + "_" + utcStamp(date) + "Z.mhl"

        let rootPath = root.standardizedFileURL.path + "/"
        let now = iso(date)
        var hashes = ""
        for e in entries {
            let p = e.url.standardizedFileURL.path
            guard p.hasPrefix(rootPath) else { continue }
            let rel = String(p.dropFirst(rootPath.count))
            let attrs = try? fm.attributesOfItem(atPath: p)
            let size = (attrs?[.size] as? UInt64) ?? 0
            let modified = (attrs?[.modificationDate] as? Date) ?? date
            hashes += """
                <hash>
                  <path size="\(size)" lastmodificationdate="\(iso(modified))">\(escape(rel))</path>
                  <xxh64 action="\(e.action.rawValue)" hashdate="\(now)">\(XXH64.hex(e.xxh64))</xxh64>
                </hash>

            """
        }
        let patterns = [".DS_Store", "ascmhl", "ascmhl/", "*.part"] + ignore
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <hashlist version="2.0" xmlns="urn:ASC:MHL:v2.0">
          <creatorinfo>
            <creationdate>\(now)</creationdate>
            <hostname>\(escape(ProcessInfo.processInfo.hostName))</hostname>
            <tool version="\(escape(version))">MiniDiT</tool>
          </creatorinfo>
          <processinfo>
            <process>transfer</process>
            <ignore>
        \(patterns.map { "      <pattern>\(escape($0))</pattern>" }.joined(separator: "\n"))
            </ignore>
          </processinfo>
          <hashes>
        \(hashes)  </hashes>
        </hashlist>

        """
        let file = dir.appending(path: name)
        try Data(xml.utf8).write(to: file, options: .atomic)
        chain.append(ChainItem(seq: seq, path: name, c4: try c4(of: file)))
        try writeChain(chain, to: chainURL)
        return file
    }

    // MARK: 链

    private struct ChainItem { var seq: Int; var path: String; var c4: String }

    private static func readChain(_ url: URL) -> [ChainItem] {
        guard let doc = try? XMLDocument(contentsOf: url), let root = doc.rootElement() else { return [] }
        return root.elements(forName: "hashlist").compactMap { el in
            guard let seq = el.attribute(forName: "sequencenr")?.stringValue.flatMap(Int.init),
                  let path = el.elements(forName: "path").first?.stringValue,
                  let c4 = el.elements(forName: "c4").first?.stringValue else { return nil }
            return ChainItem(seq: seq, path: path, c4: c4)
        }
    }

    private static func writeChain(_ items: [ChainItem], to url: URL) throws {
        let body = items.map {
            "  <hashlist sequencenr=\"\($0.seq)\">\n    <path>\(escape($0.path))</path>\n    <c4>\($0.c4)</c4>\n  </hashlist>"
        }.joined(separator: "\n")
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ascmhldirectory xmlns="urn:ASC:MHL:DIRECTORY:v2.0">
        \(body)
        </ascmhldirectory>

        """
        try Data(xml.utf8).write(to: url, options: .atomic)
    }

    // MARK: C4 指纹（SMPTE ST 2114：SHA-512 的 base58，补齐到 88 位，前缀 c4）

    static func c4(of url: URL) throws -> String {
        c4(SHA512.hash(data: try Data(contentsOf: url)))
    }

    static func c4(_ digest: SHA512.Digest) -> String {
        let alphabet = Array("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
        var num = Array(digest)       // 大端的 512 位整数
        var out: [Character] = []
        while num.contains(where: { $0 != 0 }) {
            var rem = 0
            for i in num.indices {
                let v = rem * 256 + Int(num[i])
                num[i] = UInt8(v / 58)
                rem = v % 58
            }
            out.append(alphabet[rem])
        }
        let s = String(out.reversed())
        return "c4" + String(repeating: "1", count: max(0, 88 - s.count)) + s
    }

    // MARK: 格式

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f.string(from: d)
    }

    private static func utcStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: d)
    }

    private static func fileSafe(_ s: String) -> String {
        s.map { "/:\\".contains($0) ? "_" : $0 }.reduce("") { $0 + String($1) }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
