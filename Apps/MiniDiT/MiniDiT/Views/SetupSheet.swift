import AppKit
import SwiftUI

/// 设置向导：使用方式 → 照片 → 视频 → 备份 → 完成。第一次打开时出现，也可从“设置 › 通用”再打开。
/// 每一步直接改设置（和设置窗口里是同一份），所以中途关掉也不会丢。
struct SetupSheet: View {
    @Environment(AppModel.self) private var model
    /// 从设置里打开的：可以直接关闭。
    var reopened = false
    var close: () -> Void = {}

    private enum Step: Int, CaseIterable { case mode, photos, video, backup, done }
    @State private var step = Step.mode
    /// 装了哪些软件：打开时找一次（要扫各个“应用程序”文件夹）。
    @State private var apps: [AppInfo.Kind: AppInfo] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 16) { content }
                    .padding(.horizontal, 28).padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            Divider()
            footer
        }
        .frame(width: 580, height: 560)
        .task {
            apps = Dictionary(uniqueKeysWithValues: AppInfo.Kind.allCases.map { ($0, AppInfo.find($0)) })
            model.refreshCaptureOne()
        }
    }

    // MARK: 框架

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.self) { s in
                    Capsule().fill(s.rawValue <= step.rawValue ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 4)
                }
            }
            Text(title).font(.title2.weight(.semibold))
            Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 16)
    }

    private var footer: some View {
        HStack {
            if reopened {
                Button("关闭") { close() }
            }
            Spacer()
            if step != .mode {
                Button("上一步") { step = Step(rawValue: step.rawValue - 1)! }
            }
            if step == .done {
                Button("开始使用") {
                    model.setupDone = true
                    close()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Button("继续") { step = Step(rawValue: step.rawValue + 1)! }
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .backup && model.backupEnabled && model.backupFolder == nil)
            }
        }
        .padding(.horizontal, 28).padding(.vertical, 14)
    }

    private var title: String {
        switch step {
        case .mode: reopened ? "设置向导" : "欢迎使用 MiniDiT"
        case .photos: "照片"
        case .video: "视频"
        case .backup: "备份"
        case .done: "设置完成"
        }
    }

    private var subtitle: String {
        switch step {
        case .mode: "先选择使用方式。它只决定默认设置和设置中显示哪些选项，之后可在“设置 › 通用”中更改。"
        case .photos: "照片导入后交给哪个软件。"
        case .video: "视频按原文件名存放，不导入修图软件。"
        case .backup: "导入时可同时在另一块磁盘上存一份。照片和视频都会备份。"
        case .done: "以下设置都可以在“设置”中修改。"
        }
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .mode: modeStep
        case .photos: photosStep
        case .video: videoStep
        case .backup: backupStep
        case .done: summary
        }
    }

    // MARK: 使用方式

    private var modeStep: some View {
        VStack(spacing: 10) {
            ForEach(UsageMode.allCases) { m in
                ChoiceCard(icon: .symbol(m == .personal ? "person" : "person.3"), title: m.title, detail: m.detail,
                           selected: model.usageMode == m) {
                    guard model.usageMode != m else { return }
                    model.usageMode = m
                    model.applyModeDefaults()
                }
            }
        }
    }

    // MARK: 照片

    private var isC1: Bool { [.newSession, .c1Settings, .inPlace].contains(model.captureOneMode) }

    @ViewBuilder private var photosStep: some View {
        VStack(spacing: 10) {
            if let c1 = apps[.captureOne], c1.isInstalled {
                ChoiceCard(icon: .app(c1.url), title: "Capture One",
                           detail: "每次导入新建一个会话（如“11.7-公园”），照片存入会话的 Capture 文件夹。",
                           selected: isC1) {
                    if !isC1 { model.captureOneMode = .newSession }
                }
            }
            if let lr = apps[.lightroom], lr.isInstalled {
                ChoiceCard(icon: .app(lr.url), title: "Lightroom Classic",
                           detail: "下载后添加到当前目录，按收藏夹整理。第一次导入时会提示安装 MiniDiT 插件。",
                           selected: model.captureOneMode == .lightroom) {
                    model.captureOneMode = .lightroom
                }
            }
            ChoiceCard(icon: .symbol("folder"), title: "只存到文件夹",
                       detail: "按日期分文件夹存放，用访达、Bridge 或其他软件自行打开。",
                       selected: model.captureOneMode == .off) {
                model.captureOneMode = .off
            }
        }
        if model.captureOneMode == .newSession {
            labeled("新会话的位置") {
                LocationRow(path: model.sessionsFolder.path(percentEncoded: false), button: "更改…") {
                    if let u = FolderPicker.choose(start: model.sessionsFolder) { model.sessionsFolder = u }
                }
            }
        } else if !isC1 {
            labeled("照片存放位置") {
                LocationRow(path: model.destination.path(percentEncoded: false), button: "更改…") {
                    if let u = FolderPicker.choose(start: model.destination) { model.destination = u }
                }
            }
        }
        if model.captureOneMode == .off {
            @Bindable var model = model
            labeled("导入完成后打开") {
                Picker("导入完成后打开", selection: $model.openAfterImport) {
                    ForEach(FolderApp.allCases.filter { $0.isAvailable || $0 == model.openAfterImport }) { Text($0.title).tag($0) }
                }
                .labelsHidden().fixedSize()
            }
        }
    }

    // MARK: 视频

    @ViewBuilder private var videoStep: some View {
        @Bindable var model = model
        labeled("视频存放位置") {
            LocationRow(path: model.videoDestination.path(percentEncoded: false), button: "更改…") {
                if let u = FolderPicker.choose(start: model.videoDestination) { model.videoDestination = u }
            }
        }
        Toggle(isOn: $model.importProxies) {
            Text("同时导入代理文件")
            Text("存入旁边的“Proxy”文件夹，剪辑软件会自动链接。")
        }
        let resolve = apps[.resolve], fcp = apps[.finalCut]
        if resolve?.isInstalled == true || fcp?.isInstalled == true {
            labeled("导入完成后交给剪辑软件") {
                VStack(spacing: 10) {
                    if let r = resolve, r.isInstalled {
                        ToggleCard(icon: .app(r.url), title: "DaVinci Resolve",
                                   detail: "加入当前项目，每个视频文件夹一个媒体夹。须在 Resolve 的“偏好设置 › 系统 › 常规”中把“外部脚本使用”设为“本地”。",
                                   on: $model.sendToResolve)
                    }
                    if let f = fcp, f.isInstalled {
                        ToggleCard(icon: .app(f.url), title: "Final Cut Pro",
                                   detail: "每个视频文件夹一个事件，片段原地引用，不复制进资源库。",
                                   on: $model.sendToFCP)
                    }
                }
            }
        }
    }

    // MARK: 备份

    @ViewBuilder private var backupStep: some View {
        @Bindable var model = model
        VStack(spacing: 10) {
            ChoiceCard(icon: .symbol("internaldrive"), title: "仅存储一份", detail: "只存到前面选的照片和视频存放位置。",
                       selected: !model.backupEnabled) { model.backupEnabled = false }
            ChoiceCard(icon: .symbol("externaldrive.badge.plus"), title: "同时备份到另一块磁盘",
                       detail: "两份都校验通过才算导入完成。备份磁盘没接上时会先询问。",
                       selected: model.backupEnabled) { model.backupEnabled = true }
        }
        if model.backupEnabled {
            labeled("备份位置") {
                LocationRow(path: model.backupFolder?.path(percentEncoded: false),
                            button: model.backupFolder == nil ? "选择…" : "更改…") {
                    if let u = FolderPicker.choose(start: model.backupFolder) { model.backupFolder = u }
                }
            }
        }
        if !model.isPro {
            Toggle(isOn: $model.deleteAfterImport) {
                Text("导入后删除存储卡上的照片")
                Text("仅适用于读卡器，且只删除校验通过的照片。")
            }
        }
    }

    // MARK: 完成

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            SummaryRow(label: "使用方式", value: model.usageMode.title)
            SummaryRow(label: "照片", value: photoSummary)
            SummaryRow(label: "视频", value: videoSummary)
            SummaryRow(label: "备份", value: backupSummary)
            if model.captureOneMode == .lightroom {
                Text("第一次导入到 Lightroom Classic 时，会提示安装 MiniDiT 插件。")
                    .font(.callout).foregroundStyle(.secondary).padding(.top, 12)
            }
        }
    }

    private var photoSummary: String {
        switch model.captureOneMode {
        case .newSession: "Capture One 新会话，存于 \(short(model.sessionsFolder))"
        case .c1Settings, .inPlace: "Capture One 当前文档"
        case .lightroom: "Lightroom Classic，下载到 \(short(model.destination))"
        case .off: "存到 \(short(model.destination))"
        }
    }

    private var videoSummary: String {
        var s = "存到 \(short(model.videoDestination))"
        var to: [String] = []
        if model.sendToResolve, apps[.resolve]?.isInstalled == true { to.append("DaVinci Resolve") }
        if model.sendToFCP, apps[.finalCut]?.isInstalled == true { to.append("Final Cut Pro") }
        if !to.isEmpty { s += "，交给 " + to.joined(separator: "、") }
        return s
    }

    private var backupSummary: String {
        guard model.backupEnabled, let u = model.backupFolder else { return "不备份" }
        return "备份到 \(short(u))"
    }

    /// 「~/Pictures/MiniDiT」
    private func short(_ u: URL) -> String {
        let p = u.path(percentEncoded: false), home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        return p.hasPrefix(home) ? "~/" + p.dropFirst(home.count) : p
    }

    private func labeled<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
        .padding(.top, 4)
    }
}

// MARK: - 部件

private enum CardIcon {
    case symbol(String)
    case app(URL?)
}

private struct CardIconView: View {
    let icon: CardIcon
    var body: some View {
        switch icon {
        case .symbol(let s):
            Image(systemName: s).font(.system(size: 20)).foregroundStyle(.tint)
                .frame(width: 32, height: 32)
        case .app(let u):
            if let u {
                Image(nsImage: NSWorkspace.shared.icon(forFile: u.path(percentEncoded: false)))
                    .resizable().frame(width: 32, height: 32)
            } else {
                Image(systemName: "app").frame(width: 32, height: 32)
            }
        }
    }
}

/// 单选的一张卡片：图标、标题、说明，选中时描边。
private struct ChoiceCard: View {
    let icon: CardIcon
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                CardIconView(icon: icon)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.semibold))
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18)).foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(selected ? 0.06 : 0.03)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 可多选的卡片：右边一个开关。
private struct ToggleCard: View {
    let icon: CardIcon
    let title: String
    let detail: String
    @Binding var on: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CardIconView(icon: icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $on).labelsHidden().toggleStyle(.switch)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct SummaryRow: View {
    let label: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct LocationRow: View {
    let path: String?
    let button: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").foregroundStyle(.tint).frame(width: 20)
            Text(path ?? "尚未选择").font(.system(size: 12)).foregroundStyle(path == nil ? .orange : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button(button, action: action)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

enum FolderPicker {
    @MainActor
    static func choose(start: URL?) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}
