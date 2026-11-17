import Combine
import Sparkle
import SwiftUI

/// 自动更新（Sparkle）。更新源和签名公钥在 Apps/MiniDiT/Info.plist（SUFeedURL、SUPublicEDKey）；
/// 发布脚本生成 appcast.xml，和 DMG 一起放在 GitHub Releases。
/// Debug 版（自己编译的开发版）不启动更新器，免得被提示「更新」成正式版。
@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()

    private let controller: SPUStandardUpdaterController?
    private let feedOverride: FeedOverride
    @Published private(set) var canCheck = false

    private init() {
        let feed = FeedOverride()
        feedOverride = feed
        #if DEBUG
        controller = nil
        #else
        let c = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: feed, userDriverDelegate: nil)
        controller = c
        c.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        #endif
    }

    var isAvailable: Bool { controller != nil }

    func checkForUpdates() { controller?.checkForUpdates(nil) }

    /// 每天在后台检查一次；有新版本时弹窗询问，不会自己安装。
    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue; objectWillChange.send() }
    }
}

/// 测试用：`defaults write com.kong.MiniDiT updateFeedURL http://…/appcast.xml` 时从这个地址检查更新，
/// 删掉这个设置就回到 Info.plist 里的 GitHub 地址。更新包仍要用同一把密钥签名、同一个团队签名才会安装。
private final class FeedOverride: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "updateFeedURL")
    }
}

/// 「MiniDiT › 检查更新…」。
struct CheckForUpdatesButton: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        Button("检查更新…") { updater.checkForUpdates() }
            .disabled(!updater.canCheck)
    }
}

/// 设置里的「自动检查更新」。
struct AutomaticUpdatesToggle: View {
    @ObservedObject private var updater = AppUpdater.shared

    var body: some View {
        if updater.isAvailable {
            Toggle("自动检查更新", isOn: Binding(get: { updater.automaticallyChecks },
                                                set: { updater.automaticallyChecks = $0 }))
                .help("每天检查一次；有新版本时询问是否安装。")
        }
    }
}
