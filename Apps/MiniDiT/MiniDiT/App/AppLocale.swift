import Foundation

extension Locale {
    /// 界面语言的区域设置（中文界面用中文日期，英文界面用英文日期），不随系统的地区格式变化。
    static var app: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }
}

extension String {
    /// 标题用：英文界面每个词首字母大写（「12 New Photos」），中文原样返回。
    var titleCased: String {
        Locale.app.language.languageCode == .chinese ? self : capitalized(with: Locale.app)
    }
}
