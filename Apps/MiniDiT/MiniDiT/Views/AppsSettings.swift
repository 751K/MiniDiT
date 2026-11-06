import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 设置 › 软件：和后期软件的连接情况（装没装、在不在运行、有没有授权自动化）。
struct AppsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var apps: [AppInfo] = []
    @State private var c1Permission: AutomationPermission = .unknown
    /// 已装的 Look：打开页面时在后台扫一次（Camera Raw 预设文件夹可能有上千个 XMP，放在 body 里每次刷新都要读一遍）。
    @State private var c1Looks: [InstalledLooks.Body] = []
    @State private var lrLooks: [LightroomLooks.Profile] = []
    @State private var looksScanned = false

    var body: some View {
        Form {
            Section {
                if let c1 = apps.first(where: { $0.kind == .captureOne }) {
                    CaptureOneRow(app: c1, permission: c1Permission, document: model.captureOneDocument,
                                  inUse: model.captureOneMode != .off,
                                  request: { Task { await checkPermission(ask: true) } },
                                  launch: { Task { await launchCaptureOne() } })
                }
                if let lr = apps.first(where: { $0.kind == .lightroom }) {
                    LightroomRow(app: lr, inUse: model.captureOneMode == .lightroom)
                }
            } header: {
                Text("正在使用")
            }
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
                    Text("未找到 Look 配置文件。").font(.callout).foregroundStyle(.orange)
                }
            } header: {
                Text("创意外观")
            } footer: {
                Text("读取 RAW 文件中记录的创意外观（ST、FL、IN 等）。导入到 Capture One 会话时，ICC 配置文件设为对应的“… Look-ST”（~/Library/ColorSync/Profiles），曲线设为“Linear Response”；导入到 Lightroom Classic 时，配置文件设为 Camera Raw 中安装的“… Look ST”。未安装对应 Look 的照片保持原样。仅处理 RAW 文件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(apps.filter { $0.kind != .captureOne && $0.kind != .lightroom && !$0.kind.isEditor }) { app in
                    FolderAppRow(app: app, usage: model.captureOneMode == .off && model.openAfterImport.appKind == app.kind ? "导入后打开" : nil)
                }
            } header: {
                Text("按文件夹管理")
            } footer: {
                Text("导入方式选“只下载”时，可在“设置 › 照片”中设置导入完成后用哪个软件打开下载的文件夹。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(apps.filter(\.kind.isEditor)) { app in
                    let on = app.kind == .resolve ? model.sendToResolve : model.sendToFCP
                    FolderAppRow(app: app, usage: app.isInstalled && on ? (app.kind == .resolve ? "导入后加入当前项目" : "导入后交给 FCP") : nil)
                }
            } header: {
                Text("视频剪辑")
            } footer: {
                Text("可在“设置 › 视频”中设置导入视频后交给哪个剪辑软件。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            let (c1, lr) = await Task.detached { (InstalledLooks.scan(), LightroomLooks.installed(fresh: true)) }.value
            c1Looks = c1; lrLooks = lr; looksScanned = true
        }
        // 从系统设置改完授权回来时重新检查。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .task { await refresh() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            Task { await refresh() }
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            Task { await refresh() }
        }
    }

    private func refresh() async {
        apps = AppInfo.Kind.allCases.map(AppInfo.find)
        model.refreshCaptureOne()
        await checkPermission(ask: false)
    }

    private func checkPermission(ask: Bool) async {
        guard let c1 = apps.first(where: { $0.kind == .captureOne }), let id = c1.bundleID, c1.isRunning else {
            c1Permission = .unknown
            return
        }
        c1Permission = await AutomationPermission.check(bundleID: id, ask: ask)
        if ask { model.refreshCaptureOne() }
    }

    private func launchCaptureOne() async {
        guard let url = apps.first(where: { $0.kind == .captureOne })?.url else { return }
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }
}

// MARK: - 数据

struct AppInfo: Identifiable {
    enum Kind: String, CaseIterable {
        case captureOne, lightroom, bridge, dxo, resolve, finalCut

        /// 剪辑软件：视频导完交给它们，不在「按文件夹管理」里。
        var isEditor: Bool { self == .resolve || self == .finalCut }

        var title: String {
            switch self {
            case .captureOne: "Capture One"
            case .lightroom: "Lightroom Classic"
            case .bridge: "Adobe Bridge"
            case .dxo: "DxO PhotoLab"
            case .resolve: "DaVinci Resolve"
            case .finalCut: "Final Cut Pro"
            }
        }
        /// Bundle ID 的前缀（版本号会出现在 ID 里，比如 captureone16、bridge2025）。
        var bundlePrefixes: [String] {
            switch self {
            case .captureOne: ["com.captureone.captureone", "com.phaseone.captureone"]
            case .lightroom: ["com.adobe.LightroomClassicCC"]
            case .bridge: ["com.adobe.bridge"]
            case .dxo: ["com.dxo.PhotoLab", "com.dxo.photolab"]
            case .resolve: ["com.blackmagic-design.DaVinciResolve"]
            case .finalCut: ["com.apple.FinalCutApp", "com.apple.FinalCut"]
            }
        }
    }

    let kind: Kind
    var url: URL?
    var bundleID: String?
    var version: String?
    var isRunning = false

    var id: Kind { kind }
    var isInstalled: Bool { url != nil }

    /// 先看正在运行的，再到各个「应用程序」文件夹（本机和外置硬盘上的，含一层子文件夹，Adobe 的软件装在子文件夹里）找，
    /// 最后再问系统哪些软件能打开文件夹（软件装在别处时也能找到，比如 DxO PhotoLab）。
    static func find(_ kind: Kind) -> AppInfo {
        func matches(_ id: String?) -> Bool { id.map { i in kind.bundlePrefixes.contains { i.hasPrefix($0) } } ?? false }
        var info = AppInfo(kind: kind)
        if let running = NSWorkspace.shared.runningApplications.first(where: { matches($0.bundleIdentifier) }) {
            info.url = running.bundleURL
            info.bundleID = running.bundleIdentifier
            info.isRunning = true
        } else {
            let fm = FileManager.default
            var candidates: [URL] = []
            var roots = [URL(filePath: "/Applications"), fm.homeDirectoryForCurrentUser.appending(path: "Applications")]
            for v in fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [] where v.path != "/" {
                roots.append(v.appending(path: "Applications"))
            }
            candidates += NSWorkspace.shared.urlsForApplications(toOpen: .folder)
            for root in roots {
                for u in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
                    if u.pathExtension == "app" { candidates.append(u) }
                    else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                        candidates += ((try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "app" }
                    }
                }
            }
            // 装了好几个版本时取版本号最大的。
            let found = candidates.compactMap { u -> (URL, Bundle)? in
                guard let b = Bundle(url: u), matches(b.bundleIdentifier) else { return nil }
                return (u, b)
            }.max { ($0.1.shortVersion ?? "").compare($1.1.shortVersion ?? "", options: .numeric) == .orderedAscending }
            info.url = found?.0
            info.bundleID = found?.1.bundleIdentifier
        }
        if let u = info.url { info.version = Bundle(url: u)?.shortVersion }
        return info
    }
}

private extension Bundle {
    var shortVersion: String? { infoDictionary?["CFBundleShortVersionString"] as? String }
}

enum AutomationPermission {
    case unknown        // 对方没在运行，查不了
    case granted
    case denied
    case notAsked

    /// 查（或请求）控制某个 App 的自动化权限。请求时系统会弹窗，所以放到后台线程。
    static func check(bundleID: String, ask: Bool) async -> AutomationPermission {
        await Task.detached {
            let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
            guard let desc = target.aeDesc else { return .unknown }
            let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
            switch status {
            case noErr: return .granted
            case OSStatus(errAEEventNotPermitted): return .denied
            case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
            default: return .unknown     // procNotFound 等
            }
        }.value
    }
}

// MARK: - 行

/// Lightroom Classic：插件装没装、在不在跑、当前目录；安装 / 更新插件。
private struct LightroomRow: View {
    let app: AppInfo
    let inUse: Bool
    @State private var status: LightroomBridge.Status = .appMissing
    @State private var heartbeat: LightroomBridge.Heartbeat?
    @State private var message: String?
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(url: app.url)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(app.kind.title).fontWeight(.semibold)
                    if let v = app.version { Text(v).foregroundStyle(.secondary) }
                }
                switch status {
                case .appMissing:
                    StatusLine(color: .secondary, text: "未安装")
                case .pluginMissing:
                    StatusLine(color: .orange, text: "尚未安装 MiniDiT 插件")
                case .pluginOutdated(let v):
                    StatusLine(color: .orange, text: "插件 \(v) 须更新至 \(LightroomPlugin.version)")
                case .starting:
                    StatusLine(color: .secondary, text: "正在唤醒 Lightroom Classic 中的插件…")
                case .needsRestart:
                    StatusLine(color: .orange, text: "插件已安装但未运行。请重新打开 Lightroom Classic，并确认已在“增效工具管理器”中启用该插件")
                case .notRunning:
                    StatusLine(color: .green, text: "插件 \(LightroomPlugin.version) 已安装")
                    StatusLine(color: .secondary, text: "未运行，导入时将自动打开")
                case .ready(let catalog):
                    StatusLine(color: .green, text: "插件 \(LightroomPlugin.version) 正在运行")
                    StatusLine(color: .secondary, text: "当前目录：\(catalog)")
                }
                let pending = LightroomBridge.pendingJobs
                if pending > 0 { StatusLine(color: .secondary, text: "尚有 \(pending) 个文件等待添加到 Lightroom Classic") }
                if let message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            switch status {
            case .pluginMissing:
                Button("安装插件") { install() }
            case .pluginOutdated:
                Button("更新插件") { install() }
            default:
                EmptyView()
            }
        }
        .padding(.vertical, 4)
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        status = LightroomBridge.status()
        heartbeat = LightroomBridge.heartbeat()
    }

    private func install() {
        do {
            let restart = try LightroomBridge.installPlugin()
            message = restart ? "插件已安装。请退出并重新打开 Lightroom Classic，插件方可生效。"
                              : "插件已安装，下次打开 Lightroom Classic 时将自动加载。"
        } catch {
            message = "安装失败：\(error.localizedDescription)"
        }
        refresh()
    }
}

private struct CaptureOneRow: View {
    let app: AppInfo
    let permission: AutomationPermission
    let document: CaptureOneBridge.DocumentInfo?
    let inUse: Bool
    let request: () -> Void
    let launch: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            AppIconView(url: app.url)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(app.kind.title).fontWeight(.semibold)
                    if let v = app.version { Text(v).foregroundStyle(.secondary) }
                }
                if !app.isInstalled {
                    StatusLine(color: .orange, text: "未安装。导入方式仅可选择“只下载”。")
                } else {
                    StatusLine(color: app.isRunning ? .green : .secondary,
                               text: app.isRunning ? "正在运行" : "未运行，导入时将自动打开")
                    if app.isRunning {
                        switch permission {
                        case .granted: StatusLine(color: .green, text: "已允许 MiniDiT 控制")
                        case .denied: StatusLine(color: .red, text: "未允许 MiniDiT 控制，导入的照片将不会出现在 C1 中")
                        case .notAsked: StatusLine(color: .orange, text: "尚未授权，首次导入时系统将请求授权")
                        case .unknown: StatusLine(color: .secondary, text: "无法检查授权")
                        }
                        if let d = document {
                            StatusLine(color: .secondary, text: "当前打开的\(d.kind)：\(d.name)")
                        }
                    } else {
                        StatusLine(color: .secondary, text: "打开后方可检查授权")
                    }
                    if !inUse {
                        StatusLine(color: .secondary, text: "当前导入方式为“只下载”，不使用 Capture One")
                    }
                }
            }
            Spacer(minLength: 8)
            if app.isInstalled {
                if !app.isRunning {
                    Button("打开", action: launch)
                } else if permission == .notAsked {
                    Button("授权…", action: request)
                } else if permission == .denied {
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct FolderAppRow: View {
    let app: AppInfo
    /// 正在用它做什么（「导入后打开」），没在用时为 nil。
    let usage: String?

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(url: app.url).opacity(app.isInstalled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.kind.title)
                    if let v = app.version { Text(v).foregroundStyle(.secondary) }
                }
                Text(app.isInstalled ? (app.isRunning ? "已安装 · 正在运行" : "已安装") : "未安装")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let usage { Text(usage).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

private struct StatusLine: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

private struct AppIconView: View {
    let url: URL?

    var body: some View {
        Group {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                    .resizable()
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
            }
        }
        .frame(width: 32, height: 32)
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
