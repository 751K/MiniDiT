import AppKit
import MiniDiTCore
import SwiftUI

struct VideoDeliveryResultRow: View {
    @Environment(AppModel.self) private var model
    let record: VideoDelivery
    let batchID: UUID
    @State private var details = false
    private var warning: Bool { [.failed, .needsAttention, .interrupted, .uncertain].contains(record.state) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(record.software.name)
                Spacer()
                if record.state == .sending { ProgressView().controlSize(.small) }
                if record.canRetry {
                    Button((record.software == .resolve && record.resolveProjectID == nil) || (record.software == .premiere && record.premiereProjectID == nil) ? "选择项目并重试…" : "重试发送") {
                        model.retryVideoDelivery(batchID: batchID, id: record.id)
                    }
                    .disabled(model.videoDeliveryTask != nil || model.progress != nil || model.importJournal.repairTask != nil || model.importJournal.persistenceError != nil)
                }
                if !record.failedPaths.isEmpty || !record.warnings.isEmpty { Button("详情…") { details = true } }
                if record.software == .finalCutPro, let path = record.documentPath,
                   [.awaitingConfirmation, .uncertain].contains(record.state) {
                    Button("显示交接文件") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
                }
            }
            Text(record.message).foregroundStyle(warning ? Theme.warning : Color.secondary)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .popover(isPresented: $details) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("发送详情").font(Theme.Font.headline)
                    if !record.failedPaths.isEmpty {
                        Text("未加入的文件")
                        ForEach(Array(record.failedPaths.enumerated()), id: \.offset) { _, path in Text(path).textSelection(.enabled) }
                    }
                    if !record.warnings.isEmpty {
                        Text("需要检查的拍摄信息")
                        ForEach(Array(record.warnings.enumerated()), id: \.offset) { _, message in Text(message).textSelection(.enabled) }
                    }
                }.padding(20).frame(width: 440, alignment: .leading)
            }.frame(maxHeight: 380)
        }
    }
}
