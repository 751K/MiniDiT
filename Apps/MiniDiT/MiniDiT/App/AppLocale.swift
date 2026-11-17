import Foundation

extension Locale {
    /// 界面语言的区域设置（中文界面用中文日期，英文界面用英文日期），不随系统的地区格式变化。
    static var app: Locale { Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en") }
}
