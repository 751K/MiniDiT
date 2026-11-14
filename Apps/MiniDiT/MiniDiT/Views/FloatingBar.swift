import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

// 浮动底栏。

struct FloatingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.importJournal.repairTask != nil {
                capsule(maxWidth: 560) {
                    ProgressView().controlSize(.small)
                    twoLines("正在补备份", model.importJournal.repairProgress)
                    secondaryButton("取消") { model.importJournal.repairTask?.cancel() }
                }
            } else if let p = model.progress {
                capsule(maxWidth: 560) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(p.resumingFrom == nil ? "正在导入" : "正在续传").fontWeight(.semibold)
                            if let from = p.resumingFrom {
                                // 续传：明确告诉用户这个文件不是从头来的。
                                Label("从 \(Self.bytes(from)) 处继续", systemImage: "arrow.clockwise")
                                    .font(Theme.Font.caption).foregroundStyle(.tint).fixedSize()
                            }
                            Spacer(minLength: 8)
                            Text("\(p.done + p.skipped + p.reused + p.failed.count) / \(p.total) 个文件")
                                .font(Theme.Font.caption.monospacedDigit())
                        }
                        ProgressView(value: p.fraction).progressViewStyle(.linear).controlSize(.small)
                        HStack(spacing: 0) {
                            Text(p.current).lineLimit(1).truncationMode(.middle)
                            Text(" · \(Self.bytes(p.bytesDone)) / \(Self.bytes(p.bytesTotal)) · \(Self.timeLeft(p.secondsLeft))")
                                .monospacedDigit().lineLimit(1).layoutPriority(1)
                        }
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .help(p.bytesPerSecond.map { "\(Self.bytes(UInt64($0)))/s" } ?? "")
                        ForEach(model.importBackupProgress) { target in
                            HStack(spacing: 8) {
                                Text(target.target.name).lineLimit(1)
                                Spacer(minLength: 8)
                                Text("\(target.verified)/\(target.total)" + (target.failed > 0 ? " · \(target.failed) 项待补" : target.copying ? " · 正在备份" : ""))
                                    .monospacedDigit()
                            }
                            .font(Theme.Font.caption)
                            .foregroundStyle(target.failed > 0 ? Theme.warning : Color.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 12)
                    secondaryButton("取消") { model.cancelImport() }
                }
            } else if let i = model.interrupted {
                capsule(maxWidth: 560) {
                    statusIcon(warning: true)
                    twoLines("导入已中断，已完成 \(i.done) / \(i.total) 个文件",
                             (model.sourcesOffline ? "相机已断开，" : "") + "未完成的 \(i.total - i.done) 个文件仍处于选中状态"
                             + (i.savedBytes > 0 ? "；已保存 \(Self.bytes(i.savedBytes))，继续时将从断点续传" : ""))
                    secondaryButton("放弃") { model.dismissInterrupted() }
                    mainButton("继续导入", disabled: model.sourcesOffline) { model.continueImport() }
                }
            } else if let r = model.lastResult, r.c1Failed, model.grid.selected.isEmpty {
                capsule(maxWidth: 560) {
                    statusIcon(warning: true)
                    twoLines("未能交由 Capture One 导入", "\(r.files) 个文件已存储至电脑，无需重新下载")
                    secondaryButton("稍后") { model.dismissResult() }
                    mainButton(model.pendingCaptureOneSessions.isEmpty ? "重新导入 C1" : "重试打开 C1",
                               disabled: model.retryingCaptureOne) { model.retryCaptureOne() }
                }
            } else if !model.grid.selected.isEmpty {
                let files = model.selectedFiles()
                capsule {
                    if let r = model.lastResult, r.cancelled, r.savedBytes > 0, !model.sourcesOffline {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("已选 \(model.countText(model.grid.selected)) · \(Self.bytes(model.selectionBytes(of: files)))")
                                .font(Theme.Font.headline).lineLimit(1)
                            Label("已保存未传输完成的 \(Self.bytes(r.savedBytes))，再次导入时将从断点续传", systemImage: "arrow.clockwise")
                                .font(Theme.Font.caption).foregroundStyle(.tint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        twoLines("已选 \(model.countText(model.grid.selected)) · \(Self.bytes(model.selectionBytes(of: files)))", pickedDetail(files))
                    }
                    ImportOptions()
                    mainButton(importLabel, disabled: model.sourcesOffline || model.phase != .ready) { model.beginImport() }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else if let r = model.lastResult {
                let (title, detail) = resultLines(r)
                capsule(maxWidth: 560) {
                    statusIcon(warning: r.needsAttention || !model.deliveryFailures.isEmpty)
                    twoLines(title, detail).help(detail)
                    let retryable = model.videoDeliveries(in: model.deliveryID).filter(\.canRetry)
                    if !retryable.isEmpty {
                        Menu("重试发送") {
                            ForEach(retryable) { record in
                                Button(record.software.name) { model.retryVideoDelivery(batchID: model.deliveryID, id: record.id) }
                            }
                        }.disabled(model.videoDeliveryTask != nil)
                    }
                    if model.videoDeliveryTask != nil { ProgressView().controlSize(.small) }
                    if !model.lastFolders.isEmpty {
                        secondaryButton("在访达中显示") { for folder in model.lastFolders { NSWorkspace.shared.open(folder) } }
                    }
                    Button { model.dismissResult() } label: { Image(systemName: "xmark").frame(height: 20) }
                    .glassButton().controlSize(.extraLarge)
                    .accessibilityLabel("关闭")
                }
            } else if model.phase == .ready {
                pill { Text("勾选日期或点选照片（⇧ 连选，⌘ 加选）").foregroundStyle(.secondary) }
            }
        }
        .animation(.snappy(duration: 0.2), value: model.grid.selected.isEmpty)
    }

    private var importLabel: String { model.currentSession == nil ? "新建项目" : "导入" }

    private func pickedDetail(_ files: [CameraContentItem]) -> String {
        if model.sourcesOffline { return "相机重新连接后方可导入" }
        let days = Set(files.map(AppModel.dayKey)).count
        var s = "仅导入所选 \(files.count) 个文件 · \(days) 天 · "
        if let cur = model.currentSession {
            s += "归入项目“\(cur.name)”"
        } else {
            s += "请先选择或新建项目"
        }
        if model.backupEnabled {
            s += model.backupAvailable ? " · 备份至 \(model.enabledBackupTargets.count) 个位置" : " · 部分必需备份位置未连接"
        }
        if model.isMultiSource { s += model.splitBySlot && model.canSplitBySlot ? " · 按来源和卡槽分子文件夹" : " · 按来源分子文件夹" }
        if model.proxyOnlyWiFi && model.selectionHasWiFiVideo { s += " · 视频只导代理" }
        if model.willDeleteFromSource { s += " · 完成后删除存储卡上的照片" }
        if let previous = model.lastResult {
            if previous.failed > 0 { s += " · 上次 \(previous.failed) 个文件未完成" }
            if previous.backupFailed > 0 { s += " · 上次 \(previous.backupFailed) 个备份失败" }
        }
        return s
    }

    /// 完成提示的两行：「已导入 12 个文件」和其余说明。
    private func resultLines(_ r: AppModel.ImportResult) -> (String, String) {
        let title = Self.resultTitle(r)
        var rest = resultText(r).dropFirst(title.count)
        while let c = rest.first, "，；、".contains(c) { rest = rest.dropFirst() }
        return (title, String(rest))
    }

    /// 「已导入 12 个文件」；只导了代理时「已导入 3 个片段的代理」。
    static func resultTitle(_ r: AppModel.ImportResult) -> String {
        r.files == 0 && r.proxyOnly > 0 ? "已导入 \(r.proxyOnly) 个片段的代理" : "已导入 \(r.files) 个文件"
    }

    private func resultText(_ r: AppModel.ImportResult) -> String {
        var s = Self.resultTitle(r)
        if r.files > 0 && r.proxyOnly > 0 { s += "、\(r.proxyOnly) 个片段的代理" }
        if r.proxyOnly > 0 { s += "，原片留在存储卡上" }
        if let session = r.session { s += "，已存入 Capture One 会话“\(session)”" }
        if let c = r.lightroom { s += "，收藏夹“\(c)”" + (model.lightroomStatus.map { "：" + $0 } ?? "") }
        if r.resumed > 0 { s += "，其中 \(r.resumed) 个从断点续传" }
        if r.failed > 0 { s += "，\(r.failed) 个失败" }
        if !r.backupTargets.isEmpty {
            s += "，" + r.backupTargets.map { "\($0.target.name)：\($0.verified)/\($0.total) 个文件已校验" }.joined(separator: "；")
        } else if let b = r.backedUp {
            s += "，本次备份并校验 \(b) 个文件"
            if r.backupFailed > 0 { s += "，\(r.backupFailed) 个备份失败" }
        } else {
            s += "，仅存储一份"
        }
        if r.cardReadOnly {
            s += "；存储卡为只读，未删除文件"
        } else if r.deleteFailed > 0 {
            s += "；\(r.deleteFailed) 个文件未能从存储卡上删除"
        } else if r.deleted == 0, r.keptOnCard > 0 {
            s += r.backedUp == nil ? "；因未备份，存储卡上的文件均已保留" : "；存储卡上的文件均已保留"
        } else if let d = r.deleted {
            s += "，已从存储卡删除 \(d) 个" + (r.keptOnCard > 0 ? "（保留 \(r.keptOnCard) 个）" : "")
        }
        if !r.reports.isEmpty { s += "，已写入校验清单" }
        if let o = r.opened { s += o }
        for software in model.deliveryMessages.keys.sorted() where software != "Lightroom Classic" {
            s += "；\(software)：\(model.deliveryMessages[software]!)"
        }
        if r.hasWiFiSource { s += "；Wi-Fi 校验依据为接收内容与本地副本，未取得相机源文件校验值" }
        if r.cancelled { s += r.savedBytes > 0 ? "（已取消；已保存 \(Self.bytes(r.savedBytes))，下次将从断点续传）" : "（已取消）" }
        return s
    }

    private func capsule<C: View>(maxWidth: CGFloat = 760, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
            .padding(.init(top: 6, leading: 20, bottom: 6, trailing: 6))
            .frame(maxWidth: maxWidth)
            .glassCapsule()
    }

    private func statusIcon(warning: Bool) -> some View {
        Image(systemName: warning ? "exclamationmark.triangle" : "checkmark")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(warning ? Theme.warning : Theme.accent)
            .padding(.trailing, 6)
    }

    private func secondaryButton(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).glassButton().controlSize(.extraLarge).fixedSize()
    }

    private func pill<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 8) { content() }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .glassCapsule()
    }

    private func twoLines(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(Theme.Font.headline).lineLimit(1)
            Text(detail).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, 12)
    }

    private func mainButton(_ title: String, disabled: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button { action() } label: { Text(title).fontWeight(.semibold) }
        .glassButton(prominent: true)
        .controlSize(.extraLarge)
        .disabled(disabled)
    }

    static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }

    /// 「剩余约 2 分 10 秒」；刚开始还算不出速度时显示「正在估算…」。
    static func timeLeft(_ s: Double?) -> String {
        guard let s else { return "正在估算…" }
        let n = Int(s.rounded())
        if n < 5 { return "即将完成" }
        if n < 60 { return "剩余约 \(n) 秒" }
        if n < 3600 {
            let sec = n % 60 / 10 * 10      // 秒数取整到 10，免得一直跳
            return "剩余约 \(n / 60) 分" + (sec > 0 ? " \(sec) 秒" : "")
        }
        return "剩余约 \(n / 3600) 小时 \(n % 3600 / 60) 分"
    }
}
