import Foundation

/// 给 DxO PhotoLab 套创意外观：DxO 没有脚本接口，但打开文件夹时读 RAW 旁边的 .dop（「DSC0001.ARW.dop」）。
/// 这里按 RAW 的创意外观写一份 .dop：色彩渲染用 sony-look-bridge 的基础 DCP（Adobe 曲线、强度 100、饱和色保护 0），
/// LUT 调色用对应外观的 .cube（ProPhoto RGB、强度 100）。
///
/// 模板是 DxO PhotoLab 10.1 自己写出的「3 - DxO Optical Corrections only」预设（保留镜头校正，智能亮度、
/// 对比度等都关闭），在 Base 和 Overrides 里都写上外观设置；只写几项的简化文件会让 DxO 一直停在加载状态，
/// LUT 开关只写在 Overrides 里也不生效（都在 DxO 10.1 上实测过）。LUT 调色只有 DxO PhotoLab Elite 能用。
enum DxOLooks {
    static var template: String? {
        Bundle.main.url(forResource: "DxOLookTemplate", withExtension: "dop").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    enum Result: Equatable { case written, kept }

    /// 在 RAW 旁边写 .dop。已有 .dop（用户在 DxO 里调过，或之前已写过）时不动它。
    static func writeSidecar(raw: URL, dcp: URL, lut: URL, template: String, now: Date = Date()) throws -> Result {
        let sidecar = raw.appendingPathExtension("dop")
        guard !FileManager.default.fileExists(atPath: sidecar.path) else { return .kept }
        let stamp = ISO8601DateFormatter.string(from: now, timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withInternetDateTime, .withFractionalSeconds])
        var text = template
        for (key, value) in [("{{NAME}}", raw.lastPathComponent), ("{{DCP}}", dcp.path), ("{{LUT}}", lut.path), ("{{NOW}}", stamp)] {
            text = text.replacingOccurrences(of: key, with: luaEscape(value))
        }
        for key in ["{{UUID1}}", "{{UUID2}}"] { text = text.replacingOccurrences(of: key, with: UUID().uuidString) }
        // 不覆盖：同时有别的程序写了同名 .dop 时放弃。
        try Data(text.utf8).write(to: sidecar, options: .withoutOverwriting)
        return .written
    }

    /// .dop 是 Lua 表，字符串里的反斜杠和引号要转义。
    static func luaEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
