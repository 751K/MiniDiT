import Foundation

/// 相机的型号、序列号等（来自 PTP GetDeviceInfo）。
public struct CameraDeviceInfo: Sendable, Equatable, Codable {
    public var manufacturer: String
    public var model: String
    public var version: String
    public var serialNumber: String
    public var operations: Set<UInt16>

    public init(manufacturer: String, model: String, version: String, serialNumber: String, operations: Set<UInt16> = []) {
        self.manufacturer = manufacturer
        self.model = model
        self.version = version
        self.serialNumber = serialNumber
        self.operations = operations
    }

    /// 解析 GetDeviceInfo 数据集；结构不对时返回 nil。
    public static func parse(_ data: Data) -> CameraDeviceInfo? {
        var r = PTPReader(data)
        // 操作列表之前的字段必须完整；之后的缺了也接受（有的实现只给到操作列表）。
        guard (try? r.u16()) != nil, (try? r.u32()) != nil, (try? r.u16()) != nil,
              (try? r.ptpString()) != nil, (try? r.u16()) != nil,
              let ops = try? r.array({ try $0.u16() }) else { return nil }
        var strings: [String] = []
        if (try? r.array({ try $0.u16() })) != nil, (try? r.array({ try $0.u16() })) != nil,
           (try? r.array({ try $0.u16() })) != nil, (try? r.array({ try $0.u16() })) != nil {
            for _ in 0..<4 { strings.append((try? r.ptpString()) ?? "") }
        }
        while strings.count < 4 { strings.append("") }
        return CameraDeviceInfo(manufacturer: strings[0], model: strings[1], version: strings[2],
                                serialNumber: strings[3], operations: Set(ops))
    }

    /// 给人看的机型名：ILCE-7M5 → α7 V；不认识的型号原样返回。
    public var displayName: String { Self.displayName(model: model) }

    public static func displayName(model raw: String) -> String {
        let m = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let table: [String: String] = [
            "ILCE-7M5": "α7 V", "ILCE-7M4": "α7 IV", "ILCE-7M3": "α7 III",
            "ILCE-7RM5": "α7R V", "ILCE-7RM4": "α7R IV", "ILCE-7RM4A": "α7R IVA", "ILCE-7RM3": "α7R III",
            "ILCE-7SM3": "α7S III", "ILCE-7CM2": "α7C II", "ILCE-7CR": "α7CR", "ILCE-7C": "α7C",
            "ILCE-1": "α1", "ILCE-1M2": "α1 II", "ILCE-9M3": "α9 III", "ILCE-9M2": "α9 II",
            "ILCE-6700": "α6700", "ILCE-6600": "α6600", "ILCE-6400": "α6400",
            "ZV-E1": "ZV-E1", "ZV-E10M2": "ZV-E10 II", "ILME-FX3": "FX3", "ILME-FX30": "FX30",
        ]
        return table[m] ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 用来区分机身的 ID：有序列号用序列号，否则用型号。
    public var cameraID: String? {
        let s = serialNumber.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "0")))
        if !s.isEmpty { return "\(model)#\(serialNumber.trimmingCharacters(in: .whitespacesAndNewlines))" }
        return nil
    }
}

public extension CameraLibrary {
    /// 默认没有设备信息（读卡器、旧的连接方式）。
    var deviceInfo: CameraDeviceInfo? { get async { nil } }

    /// 大图预览；默认用缩略图代替。
    func preview(_ handle: UInt32) async throws -> Data? { try await thumbnail(handle) }
}
