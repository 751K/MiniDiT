import Foundation

extension Bundle {
    /// 界面文字的翻译表：MiniDiT.app 里的 Localizable.xcstrings（键是中文原文）。
    /// 在 App 里就是主 bundle；minidit、camctl 命令行借用已安装的 MiniDiT.app，找不到就输出中文原文。
    /// 其他进程（测试、模拟相机）一律用主 bundle，也就是中文原文，测试结果不随系统语言变化。
    /// 用法：String(localized: "中文原文", bundle: .miniDiT)
    public static let miniDiT: Bundle = {
        if Bundle.main.bundleIdentifier == "com.kong.MiniDiT" { return .main }
        #if os(macOS)
        let tool = ProcessInfo.processInfo.processName
        guard tool == "minidit" || tool == "camctl" else { return .main }
        let candidates = [
            URL(filePath: "/Applications/MiniDiT.app"),
            URL.homeDirectory.appending(path: "Applications/MiniDiT.app"),
        ]
        for url in candidates {
            if let bundle = Bundle(url: url), bundle.bundleIdentifier == "com.kong.MiniDiT" { return bundle }
        }
        #endif
        return .main
    }()
}
