import Foundation
import Network

/// 从 mDNS `_ptp._tcp` 广播里读尼康相机的配对状态：TXT `apps=PAIR` = 当前网络配置还没配对，`$DSC` = 已配对。
/// 实例名形如「ZR_<序列号>」，TXT 里 `guid` 以 04b0 开头。附近只有一台尼康时才下结论，否则返回 nil。
public enum NikonBonjour {
    public static func needsPairing(timeout: TimeInterval = 2) async -> Bool? {
        let states = await browse(timeout: timeout)
        guard states.count == 1 else { return nil }
        return states.first
    }

    /// TXT 记录 → 是否需要配对；不是尼康时 nil。
    static func state(_ txt: [String: String]) -> Bool? {
        guard let apps = txt["apps"], (txt["guid"] ?? "").lowercased().hasPrefix("04b0") || txt["vid"] != nil else { return nil }
        switch apps {
        case "PAIR": return true
        case "$DSC": return false
        default: return nil
        }
    }

    private static func browse(timeout: TimeInterval) async -> [Bool] {
        final class Box: @unchecked Sendable {
            let lock = NSLock(); var states: [String: Bool] = [:]
        }
        let box = Box()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_ptp._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            for r in results {
                guard case let .bonjour(record) = r.metadata, case let .service(name, _, _, _) = r.endpoint else { continue }
                if let s = state(record.dictionary) { box.lock.withLock { box.states[name] = s } }
            }
        }
        browser.start(queue: DispatchQueue(label: "MiniDiT.NikonBonjour"))
        try? await Task.sleep(for: .seconds(timeout))
        browser.cancel()
        return box.lock.withLock { Array(box.states.values) }
    }
}
