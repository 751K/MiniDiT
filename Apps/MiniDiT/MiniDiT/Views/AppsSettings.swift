import AppKit
import SwiftUI

/// 设置 › 软件：和后期软件的连接情况（装没装、在不在运行、有没有授权自动化）。
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
            } header: {
                Text("正在使用")
            } footer: {
                Text("导入时 MiniDiT 通过 AppleScript 让 Capture One 新建会话、导入照片，需要在「自动化」里允许。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(apps.filter { $0.kind != .captureOne }) { app in
                    PlannedRow(app: app)
                }
            } header: {
                Text("以后支持")
            } footer: {
                Text("计划在 v0.4 支持：导完以后交给 Lightroom Classic 导入，或在 Bridge / DxO PhotoLab 里打开导入的文件夹。")
                    .font(.caption).foregroundStyle(.secondary)
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
        case captureOne, lightroom, bridge, dxo

        var title: String {
            switch self {
            case .captureOne: "Capture One"
            case .lightroom: "Lightroom Classic"
            case .bridge: "Adobe Bridge"
            case .dxo: "DxO PhotoLab"
            }
        }
        /// Bundle ID 的前缀（版本号会出现在 ID 里，比如 captureone16、bridge2025）。
        var bundlePrefixes: [String] {
            switch self {
            case .captureOne: ["com.captureone.captureone", "com.phaseone.captureone"]
            case .lightroom: ["com.adobe.LightroomClassicCC"]
            case .bridge: ["com.adobe.bridge"]
            case .dxo: ["com.dxo.PhotoLab", "com.dxo.photolab"]
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

    /// 先看正在运行的，再到「应用程序」文件夹（含一层子文件夹，Adobe 的软件装在子文件夹里）找。
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
            for root in [URL(filePath: "/Applications"), fm.homeDirectoryForCurrentUser.appending(path: "Applications")] {
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
                    StatusLine(color: .orange, text: "没有安装。导入方式只能选「只下载」。")
                } else {
                    StatusLine(color: app.isRunning ? .green : .secondary,
                               text: app.isRunning ? "正在运行" : "没有运行，导入时会自动打开")
                    if app.isRunning {
                        switch permission {
                        case .granted: StatusLine(color: .green, text: "已允许 MiniDiT 控制")
                        case .denied: StatusLine(color: .red, text: "没有允许 MiniDiT 控制，导入后 C1 里不会出现照片")
                        case .notAsked: StatusLine(color: .orange, text: "还没有授权，第一次导入时系统会询问")
                        case .unknown: StatusLine(color: .secondary, text: "无法检查授权")
                        }
                        if let d = document {
                            StatusLine(color: .secondary, text: "当前打开的\(d.kind)：\(d.name)")
                        }
                    } else {
                        StatusLine(color: .secondary, text: "打开以后才能检查授权")
                    }
                    if !inUse {
                        StatusLine(color: .secondary, text: "导入方式现在是「只下载」，不会用到 Capture One")
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

private struct PlannedRow: View {
    let app: AppInfo

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(url: app.url).opacity(app.isInstalled ? 1 : 0.4)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(app.kind.title)
                    if let v = app.version { Text(v).foregroundStyle(.secondary) }
                }
                Text(app.isInstalled ? (app.isRunning ? "已安装 · 正在运行" : "已安装") : "没有安装")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("还不支持").font(.caption).foregroundStyle(.secondary)
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
