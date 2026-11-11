import Foundation

/// Only classifies reported media characteristics, never a reader name, volume
/// label, capacity or generic USB/NVMe transport. SD protocol alone does not
/// distinguish a full-size card from microSD in an adapter.
public enum CardMediaType: String, Codable, Sendable, CaseIterable {
    case sdFamily, microSD, cfexpress, cfexpressA, cfexpressB

    public var displayName: String {
        switch self {
        case .sdFamily: "SD / microSD"
        case .microSD: "microSD（TF）"
        case .cfexpress: "CFexpress"
        case .cfexpressA: "CFexpress Type A"
        case .cfexpressB: "CFexpress Type B"
        }
    }

    public static func detect(reportedTypes: [String], interconnects: [String]) -> Self? {
        let reports = reportedTypes.map(normalize).filter { !$0.isEmpty }
        let parsed = reports.map { value -> Self? in
            switch value {
            case "SD", "SDSC", "SDHC", "SDXC", "SDUC", "SECUREDIGITAL": .sdFamily
            case "TF", "MICROSD", "MICROSDSC", "MICROSDHC", "MICROSDXC", "MICROSDUC": .microSD
            case "CFEXPRESS": .cfexpress
            case "CFEXPRESSA", "CFEXPRESSTYPEA": .cfexpressA
            case "CFEXPRESSB", "CFEXPRESSTYPEB": .cfexpressB
            default: nil
            }
        }
        // An unrecognized or conflicting explicit report must not be replaced
        // by a less specific inference from the reader's interface.
        guard parsed.allSatisfy({ $0 != nil }) else { return nil }
        var types = Set(parsed.compactMap { $0 })
        if types.contains(.microSD) { types.remove(.sdFamily) }
        if types.contains(.cfexpressA) || types.contains(.cfexpressB) { types.remove(.cfexpress) }
        if types.count == 1 { return types.first }
        guard reports.isEmpty else { return nil }
        return interconnects.contains { normalize($0) == "SECUREDIGITAL" } ? .sdFamily : nil
    }

    private static func normalize(_ value: String) -> String {
        value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}
