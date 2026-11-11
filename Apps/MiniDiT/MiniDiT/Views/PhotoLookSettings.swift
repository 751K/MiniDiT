import Foundation
import SwiftUI

/// Photo processing preferences and the Look profiles available to each photo editor.
struct PhotoLookSettings: View {
    @Environment(AppModel.self) private var model
    /// 已装的 Look：打开页面时在后台扫一次（Camera Raw 预设文件夹可能有上千个 XMP，放在 body 里每次刷新都要读一遍）。
    @State private var c1Looks: [InstalledLooks.Body] = []
    @State private var lrLooks: [LightroomLooks.Profile] = []
    @State private var looksScanned = false

    var body: some View {
        Section {
            Toggle("按拍摄时的创意外观套用 Look", isOn: Bindable(model).applyCreativeLook)
            let looks = c1Looks
            ForEach(looks, id: \.body) { l in
                LabeledContent("Capture One · \(l.body)", value: l.codes.joined(separator: " · "))
            }
            let lr = Dictionary(grouping: lrLooks, by: \.model)
            ForEach(lr.keys.sorted(), id: \.self) { m in
                LabeledContent("Lightroom · \(m)", value: lr[m]!.map(\.code).joined(separator: " · "))
            }
            if looksScanned && looks.isEmpty && lr.isEmpty {
                Text("未找到 Look 配置文件。").font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("创意外观")
        } footer: {
            Text("仅处理 RAW 文件；未安装对应 Look 的照片保持原样。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task {
            let (c1, lr) = await Task.detached { (InstalledLooks.scan(), LightroomLooks.installed(fresh: true)) }.value
            c1Looks = c1; lrLooks = lr; looksScanned = true
        }
    }
}

/// 装在 ColorSync 文件夹里的 Look 配置文件（「SonyA7M5-Look-ST.icc」），按机身列出有哪些外观。
enum InstalledLooks {
    struct Body { let body: String; let codes: [String] }

    static func scan() -> [Body] {
        let dirs = [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/ColorSync/Profiles"),
                    URL(filePath: "/Library/ColorSync/Profiles")]
        var map: [String: Set<String>] = [:]
        for d in dirs {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? [] {
                let base = (f as NSString).deletingPathExtension
                guard ["icc", "icm"].contains((f as NSString).pathExtension.lowercased()),
                      let r = base.range(of: "-Look-") else { continue }
                map[String(base[..<r.lowerBound]), default: []].insert(String(base[r.upperBound...]))
            }
        }
        let order = CreativeLook.all
        return map.keys.sorted().map { k in
            Body(body: k, codes: map[k]!.sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) })
        }
    }
}
