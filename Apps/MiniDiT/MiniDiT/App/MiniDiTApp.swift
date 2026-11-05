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
                .frame(minWidth: 860, minHeight: 560)
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
            } else {
                ConnectView()
            }
        }
        .sheet(item: $model.credentialRequest) { CredentialSheet(request: $0) }
        .sheet(item: $model.fingerprintRequest) { FingerprintSheet(request: $0) }
        .sheet(item: $model.sessionRequest) { SessionSheet(request: $0) }
        .sheet(isPresented: Binding(get: { !model.setupDone }, set: { if !$0 { model.setupDone = true } })) {
            SetupSheet().interactiveDismissDisabled()
        }
        .alert(model.backupFolder == nil ? "尚未设置备份位置" : "未找到备份磁盘", isPresented: $model.backupMissingPrompt) {
            Button("仅存储一份并继续") { model.beginImport(checkBackup: false) }
            if model.backupFolder == nil {
                Button("选择备份位置…") {
                    if let u = FolderPicker.choose(start: nil) { model.backupFolder = u; model.beginImport() }
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let u = model.backupFolder {
                Text("备份位置“\(u.path(percentEncoded: false))”当前不可用，磁盘可能未连接。\n本次将仅存储一份，且不会删除存储卡上的文件。连接磁盘后再次导入这些照片，即可补全备份。")
            } else {
                Text("本次将仅存储一份，且不会删除存储卡上的文件。可在“设置 › 导入”中选择备份位置。")
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
            case .appMissing: Text("未找到 Lightroom Classic。请先安装，或在“设置 › 导入”中更换导入方式。")
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
