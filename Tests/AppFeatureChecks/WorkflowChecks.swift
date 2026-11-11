// 链接 Debug App 对象文件；在独立的命令行偏好设置域中检查工作流程。
import AppKit
import Foundation
@testable import MiniDiT

@main struct WorkflowChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        // 不允许把这个检查作为 App 内的代码执行，以免改动用户的 App 设置。
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            if let previous { defaults.setPersistentDomain(previous, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        let marker = UUID().uuidString
        defaults.set(marker, forKey: "workflowCheckDomain")
        precondition(defaults.persistentDomain(forName: domain)?["workflowCheckDomain"] as? String == marker,
                     "检查必须使用独立的命令行偏好设置域")

        precondition(UsageMode(rawValue: "pro") == .team, "升级不能丢失已有模式")
        precondition(UsageMode(rawValue: "personal") == .personal)
        precondition(UsageMode.allCases.map(\.title) == ["个人", "团队"])

        defaults.set(1, forKey: "setupVersion")
        let upgraded = AppModel(startServices: false)
        precondition(upgraded.setupDone, "已完成旧版引导的用户不应被强制重走")
        defaults.removeObject(forKey: "c1Mode")
        precondition(AppModel(startServices: false).captureOneMode == .off,
                     "首次使用应能直接存入文件夹，不依赖照片软件")
        let key = NameTemplate.Kind.video.key
        let custom = "客户项目/{YYYY}-{MM}-{DD}/{卷号}"
        defaults.set("pro", forKey: "usageMode")
        defaults.set(custom, forKey: key)
        defaults.set(true, forKey: "autoImportCamera")
        defaults.set(true, forKey: "deleteAfterImport")
        defaults.set(false, forKey: "resolveColorSpace")
        defaults.set(false, forKey: "fcpLogProcessing")
        let model = AppModel(startServices: false)
        precondition(model.usageMode == .team)
        precondition(model.autoImportCamera && model.deleteAfterImport,
                     "加载旧模式不能自动应用推荐设置")
        precondition(defaults.string(forKey: key) == custom)

        model.usageMode = .personal
        precondition(model.autoImportCamera && model.deleteAfterImport,
                     "只切换流程必须保留当前选项")
        precondition(defaults.string(forKey: key) == custom)
        precondition(!model.resolveColorSpace && !model.fcpLogProcessing)

        model.usageMode = .team
        model.applyModeDefaults()
        precondition(!model.autoImportCamera && !model.deleteAfterImport,
                     "团队推荐应为手动导入并保留原卡")
        precondition(defaults.string(forKey: key) == custom,
                     "推荐设置不能覆盖自定义命名")
        precondition(!model.resolveColorSpace && !model.fcpLogProcessing,
                     "工作流程不能改动用户的色彩处理选择")

        for template in [nil, "", NameTemplate.Kind.video.defaultValue] as [String?] {
            defaults.set(template, forKey: key)
            model.applyModeDefaults()
            precondition(defaults.string(forKey: key) == UsageMode.teamVideoTemplate)
        }

        model.usageMode = .personal
        model.applyModeDefaults()
        precondition(NameTemplate.current(.video) == NameTemplate.Kind.video.defaultValue,
                     "个人推荐应按日期、事件整理")
        precondition(!model.autoImportCamera && !model.deleteAfterImport,
                     "个人推荐不能擅自启用自动导入或删除原卡")
        defaults.set(custom, forKey: key)
        model.applyModeDefaults()
        precondition(defaults.string(forKey: key) == custom)

        let activeDelivery = model.deliveryID
        model.updateDelivery("Resolve", message: "素材已保存，加入失败", failed: true, id: activeDelivery)
        precondition(model.deliveryFailures.contains("Resolve"))
        model.updateDelivery("Resolve", message: "旧批次迟到回执", id: UUID())
        precondition(model.deliveryMessages["Resolve"] == "素材已保存，加入失败")
        model.updateDelivery("Resolve", message: "已加入", id: activeDelivery)
        precondition(model.deliveryFailures.isEmpty)

        // 团队成员同样可自行选择自动导入、删除和色彩管理等共用能力。
        model.usageMode = .team
        model.autoImportCamera = true
        model.deleteAfterImport = true
        model.resolveColorSpace = true
        model.fcpLogProcessing = true
        precondition(model.autoImportCamera && model.deleteAfterImport)
        precondition(model.resolveColorSpace && model.fcpLogProcessing)
        print("PASS: legacy workflow compatibility; no reset on load/switch; team/personal recommendations; custom naming and color choices preserved; shared options remain configurable")
    }
}
