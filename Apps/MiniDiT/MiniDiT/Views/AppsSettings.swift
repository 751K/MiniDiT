import AppKit
import Combine
import MiniDiTCore
import SwiftUI
import UniformTypeIdentifiers

/// 设置 › 连接：和后期软件的连接情况（装没装、在不在运行、有没有授权自动化）。
struct AppsSettings: View {
    @Environment(AppModel.self) private var model
    @State private var apps: [AppInfo] = []
    @State private var c1Permission: AutomationPermission = .unknown

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
                ForEach(apps.filter { $0.kind != .captureOne && $0.kind != .lightroom && !$0.kind.isEditor }) { app in
                    FolderAppRow(app: app, usage: model.captureOneMode == .off && model.openAfterImport.appKind == app.kind ? "导入后打开" : nil)
                }
            } header: {
                Text("照片后期")
            }
            Section {
                ForEach(apps.filter(\.kind.isEditor)) { app in
                    if app.kind == .premiere { PremiereConnectionRow(app: app) }
                    else {
                        let on = app.kind == .resolve ? model.sendToResolve : app.kind == .jianying ? model.sendToJianying : model.sendToFCP
                        let usage = switch app.kind { case .resolve, .premiere: "导入后加入同名项目"; case .jianying: "导入后加入同名草稿"; default: model.fcpProjectAs == .library ? "导入后加入同名资源库" : "导入后加入同名事件" }
                        FolderAppRow(app: app, usage: app.isInstalled && on ? usage : nil)
                    }
                }
            } header: {
                Text("视频后期")
            }
        }
        .formStyle(.grouped)
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
        case captureOne, lightroom, bridge, dxo, resolve, finalCut, premiere, jianying

        /// 视频后期软件，其他软件归入照片后期。
        var isEditor: Bool { self == .resolve || self == .finalCut || self == .premiere || self == .jianying }

        var title: String {
            switch self {
            case .captureOne: "Capture One"
            case .lightroom: "Lightroom Classic"
            case .bridge: "Adobe Bridge"
            case .dxo: "DxO PhotoLab"
            case .resolve: "DaVinci Resolve"
            case .finalCut: "Final Cut Pro"
            case .premiere: "Adobe Premiere Pro"
            case .jianying: "剪映专业版"
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
            case .premiere: ["com.adobe.PremierePro"]
            case .jianying: ["com.lemon.lvpro"]
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.kind.title)
                    if let v = app.version { Text(v).foregroundStyle(.secondary) }
                }
                // 每个软件一行状态：正常是灰字，需要处理时才有橙色警告。
                switch status {
                case .appMissing:
                    StatusLine(text: "未安装")
                case .pluginMissing:
                    StatusLine(text: "尚未安装 MiniDiT 插件", warning: true)
                case .pluginOutdated:
                    StatusLine(text: "插件需更新至 \(LightroomPlugin.version)", warning: true)
                case .starting:
                    StatusLine(text: "正在唤醒插件…")
                case .needsRestart:
                    StatusLine(text: "插件未运行，请重新打开 Lightroom Classic", warning: true)
                case .notRunning:
                    StatusLine(text: "插件 \(LightroomPlugin.version) · 未运行")
                case .ready(let catalog):
                    StatusLine(text: "插件 \(LightroomPlugin.version) · 当前目录：\(catalog)")
                }
                let pending = LightroomBridge.pendingJobs
                if pending > 0 { StatusLine(text: "尚有 \(pending) 个文件等待添加") }
                if let message { StatusLine(text: message) }
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(app.kind.title)
                    if let v = app.version { Text(v).foregroundStyle(.secondary) }
                }
                if !app.isInstalled {
                    StatusLine(text: "未安装")
                } else if !app.isRunning {
                    StatusLine(text: "未运行")
                } else {
                    switch permission {
                    case .denied: StatusLine(text: "未允许 MiniDiT 控制", warning: true)
                    case .notAsked: StatusLine(text: "首次导入时将请求授权")
                    default: StatusLine(text: document.map { "当前\($0.kind)：\($0.name)" } ?? "正在运行")
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
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.kind.title)
                    if let v = app.version { Text(v).foregroundStyle(.secondary) }
                }
                Text(app.isInstalled ? (app.isRunning ? "正在运行" : "已安装") : "未安装")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let usage { Text(usage).font(Theme.Font.caption).foregroundStyle(.secondary) }
        }
    }
}

/// 软件的一行状态：说明字号、灰色；需要处理时前面加橙色警告图标（不用彩色圆点，见设计规范）。
private struct StatusLine: View {
    let text: String
    var warning = false

    var body: some View {
        HStack(spacing: 4) {
            if warning { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning) }
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(Theme.Font.caption)
    }
}


struct PremiereConnectionRow: View {
    let app: AppInfo
    @State private var heartbeat: PremiereBridge.Heartbeat?
    @State private var message: String?
    @State private var installing = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var supported: Bool { app.version.map { $0.compare("25.6", options: .numeric) != .orderedAscending } ?? false }
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Adobe Premiere Pro")
                    if let version = app.version { Text(version).foregroundStyle(.secondary) }
                }
                if !app.isInstalled { StatusLine(text: "未安装") }
                else if !supported { StatusLine(text: "需更新至 25.6 或更高版本", warning: true) }
                else if let h = heartbeat, h.isFresh, app.isRunning {
                    if h.pluginVersion != PremierePlugin.version || h.protocolVersion != 1 { StatusLine(text: "MiniDiT 插件需更新", warning: true) }
                    else if h.busy { StatusLine(text: "正在接收素材") }
                    else { StatusLine(text: "已连接") }
                } else { StatusLine(text: app.isRunning ? "请打开 Premiere Pro 中的 MiniDiT 面板" : "已安装 · 未运行") }
                if let message { StatusLine(text: message) }
            }
            Spacer(minLength: 8)
            if app.isInstalled && supported {
                Button("安装插件…") {
                    installing = true
                    Task {
                        defer { installing = false }
                        do {
                            let package = try await PremierePlugin.makePackage()
                            guard NSWorkspace.shared.open(package) else { throw MiniDiTCore.VideoDelivery.Failure("请用 Adobe Creative Cloud 打开插件安装文件。") }
                            message = "安装后，在 Premiere Pro 的“窗口 › UXP 插件”中打开 MiniDiT。"
                        } catch { message = error.localizedDescription }
                    }
                }.disabled(installing)
            }
        }
        .padding(.vertical, 4)
        .onAppear { heartbeat = PremiereBridge.heartbeat() }
        .onReceive(timer) { _ in heartbeat = PremiereBridge.heartbeat() }
    }
}
