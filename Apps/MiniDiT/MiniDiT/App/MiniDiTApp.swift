import AppKit
import SonyRemoteKit
import SwiftUI

@main
struct MiniDiTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        // 只有一个主窗口：关了以后从菜单栏、通知、插卡再打开的都是它。
        Window("MiniDiT", id: "main") {
            RootView()
                .environment(model)
                .frame(minWidth: 1040, minHeight: 560)
                .onAppear { model.mainWindowChanged(open: true) }
                .onDisappear { model.mainWindowChanged(open: false) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("切换来源…") { model.disconnect() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.progress != nil || model.connectedName == nil)
                Button("重新读取") { model.refreshSources() }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.progress != nil || model.phase != .ready)
                Divider()
                Button(model.isTethering ? "显示联机拍摄窗口" : "联机拍摄") {
                    if model.isTethering { model.tetherWindowRequest += 1 }
                    else { model.startTetherFromCurrent() }
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!model.isTethering && (!model.canStartTether || model.progress != nil))
            }
            CommandMenu("选择") {
                Button("选择全部新照片") { model.selectNew(in: Set(model.days.map(\.id))) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("反选") { model.grid.invert() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("取消选择") { model.grid.clear() }
                    .keyboardShortcut("d", modifiers: .command)
                Divider()
                Button("大图预览") { model.openPreview() }
                    .keyboardShortcut("y", modifiers: .command)
            }
            CommandMenu("来源") {
                Button(model.alignCandidate.map { "按选中的两张对齐时间（\(model.sourceLabel($0.adjust)) \(CameraProfile.offsetText($0.offset))）" }
                       ?? "按选中的两张对齐时间") { model.alignClocks() }
                    .disabled(model.alignCandidate == nil)
                Divider()
                ForEach(model.sources) { src in
                    Menu(model.sources.count > 1 ? model.sourceLabel(src.id) : "当前来源") {
                        SourceMenu(id: src.id) { model.renamingSource = $0 }.environment(model)
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Button("放大缩略图") { model.thumbSize = min(320, model.thumbSize + 30) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小缩略图") { model.thumbSize = max(110, model.thumbSize - 30) }
                    .keyboardShortcut("-", modifiers: .command)
            }
        }
        Window("联机拍摄", id: "tether") {
            TetherWindow().environment(model)
        }
        .defaultSize(width: 1180, height: 760)
        Settings {
            SettingsView().environment(model)
        }
        MenuBarExtra(isInserted: Bindable(model).keepInMenuBar) {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarLabel().environment(model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 关窗口时要不要退出、登录时打开的话先不弹窗口。
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 这次是作为登录项打开的。
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        let e = NSAppleEventManager.shared().currentAppleEvent
        launchedAtLogin = e?.eventID == kAEOpenApplication
            && e?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 登录时打开：只在菜单栏待着，不弹主窗口。
        guard launchedAtLogin, UserDefaults.standard.object(forKey: "keepInMenuBar") as? Bool ?? true else { return }
        DispatchQueue.main.async {
            for w in NSApp.windows where w.identifier?.rawValue.hasPrefix("main") == true { w.close() }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(UserDefaults.standard.object(forKey: "keepInMenuBar") as? Bool ?? true)
    }

    /// 点程序坞图标时，窗口关着就打开。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { Notifier.shared.model?.showMainWindow() } }
        return true
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private var lightroomTitle: String {
        switch model.lightroomPrompt {
        case .appMissing: "未安装 Lightroom Classic"
        case .pluginOutdated: "MiniDiT 插件需要更新"
        default: "需要安装 Lightroom Classic 插件"
        }
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.phase == .ready || model.offline || (model.phase == .loading && model.connectedName != nil) {
                BrowserView()
            } else if let id = model.browsingSession, let s = model.sessions.first(where: { $0.id == id }) {
                SessionBrowser(session: s, media: model.browsingSessionMedia) { model.browseSession(nil) }
            } else {
                ConnectView()
            }
        }
        .onChange(of: model.tetherWindowRequest) { _, _ in openWindow(id: "tether") }
        .sheet(item: $model.credentialRequest) { CredentialSheet(request: $0) }
        .sheet(item: $model.fingerprintRequest) { FingerprintSheet(request: $0) }
        .sheet(item: $model.sessionRequest) { SessionSheet(request: $0) }
        .sheet(item: $model.newSessionPrompt) { NewSessionSheet(prompt: $0) }
        .sheet(isPresented: Binding(get: { !model.setupDone || model.showingSetup },
                                    set: { if !$0 { model.setupDone = true; model.showingSetup = false } })) {
            SetupSheet(reopened: model.setupDone) { model.showingSetup = false }.interactiveDismissDisabled()
        }
        .alert(model.enabledBackupTargets.isEmpty ? "尚未设置备份位置" : "部分备份位置不可用", isPresented: $model.backupMissingPrompt) {
            Button("先导入，稍后补齐") { model.beginImport(checkBackup: false) }
            if model.enabledBackupTargets.isEmpty {
                Button("选择备份位置…") {
                    if let u = FolderPicker.choose(start: nil) {
                        if let index = model.backupTargets.firstIndex(where: { $0.root.resolvingSymlinksInPath().path == u.resolvingSymlinksInPath().path }) {
                            model.backupTargets[index].enabled = true
                        } else { model.addBackupTarget(u) }
                        if model.backupAvailable { model.beginImport() }
                    }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if model.enabledBackupTargets.isEmpty {
                Text("本次先保存工作文件，不删除卡上原片；之后可在项目的导入记录中添加备份位置。")
            } else {
                Text("不可用的必需位置：" + model.missingRequiredBackupTargets.map(\.name).joined(separator: "、")
                     + "。继续后仍会备份到可用位置；未完成的目标保留在导入记录中，可单独补齐。")
            }
        }
        .alert(model.spaceProblem?.isBackup == true ? "备份磁盘空间不足" : "存储空间不足",
               isPresented: Binding(get: { model.spaceProblem != nil }, set: { if !$0 { model.spaceProblem = nil } }),
               presenting: model.spaceProblem) { p in
            if p.isBackup {
                Button("仅存储一份并继续") {
                    model.noBackupThisTime = true
                    model.beginImport(checkBackup: false)
                }
            }
            Button("取消", role: .cancel) {}
        } message: { p in
            let free = ByteCountFormatter.string(fromByteCount: Int64(p.available), countStyle: .file)
            let need = ByteCountFormatter.string(fromByteCount: Int64(p.needed), countStyle: .file)
            Text("“\(p.folder.path(percentEncoded: false))”所在磁盘剩余 \(free)，本次导入约需 \(need)。\n"
                 + (p.isBackup ? "请清理备份磁盘、更换备份位置或减少所选照片；也可本次仅存储一份，此时不会删除存储卡上的文件。"
                               : "请清理磁盘、更换存储位置，或减少所选照片。"))
        }
        .alert(lightroomTitle, isPresented: Binding(get: { model.lightroomPrompt != nil }, set: { if !$0 { model.lightroomPrompt = nil } })) {
            switch model.lightroomPrompt {
            case .pluginMissing, .pluginOutdated:
                Button("安装插件") {
                    do {
                        let restart = try LightroomBridge.installPlugin()
                        model.lightroomPrompt = nil
                        if restart {
                            model.errorMessage = "插件已安装。请退出并重新打开 Lightroom Classic，然后再进行导入。"
                        } else {
                            model.beginImport(checkBackup: false, checkSpace: false)
                        }
                    } catch {
                        model.errorMessage = "安装插件失败：\(error.localizedDescription)"
                    }
                }
                Button("取消", role: .cancel) {}
            default:
                Button("好", role: .cancel) {}
            }
        } message: {
            switch model.lightroomPrompt {
            case .appMissing: Text("未找到 Lightroom Classic。请先安装，或在“设置 › 照片”中更换导入方式。")
            case .pluginOutdated(let v): Text("已安装的 MiniDiT 插件版本为 \(v)，须更新至 \(LightroomPlugin.version)。更新后须重新打开 Lightroom Classic。")
            default: Text("导入到 Lightroom Classic 前，须先安装 MiniDiT 插件（安装至 Lightroom 的 Modules 文件夹，将自动加载）。若 Lightroom Classic 正在运行，安装后须重新打开。")
            }
        }
        .alert("发生错误", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
