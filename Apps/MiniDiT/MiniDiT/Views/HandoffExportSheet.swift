import AppKit
import MiniDiTCore
import SwiftUI

struct HandoffExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let project: ShootSession
    let records: [ImportBatchRecord]
    let selectedBatch: UUID?
    @State private var entireProject = false
    @State private var preparedBy = ""
    @State private var notes = ""
    @State private var exporting = false
    @State private var exportStatus = String(localized: "正在生成 PDF…")
    @State private var exportTask: Task<Void, Never>?
    @State private var result: URL?
    @State private var problem: String?

    private var selectedRecords: [ImportBatchRecord] {
        entireProject ? records : records.filter { $0.id == (selectedBatch ?? records.first?.id) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("导出 PDF 交接清单").font(Theme.Font.title)
            Text(project.name).foregroundStyle(.secondary)
            if let result {
                Text("已保存 PDF 交接清单及校验材料。")
                Text(result.lastPathComponent).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("打开 PDF") { NSWorkspace.shared.open(result.appending(path: "report.pdf")) }
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([result]) }
                    Spacer()
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    if records.count > 1 {
                        Picker("导出范围", selection: $entireProject) {
                            Text("所选导入").tag(false)
                            Text("整个项目").tag(true)
                        }
                    }
                    Text("\(selectedRecords.count) 次导入 · \(selectedRecords.flatMap(\.files).filter { $0.projectID == project.id }.count) 个导入项")
                        .foregroundStyle(.secondary)
                    TextField("整理人（可选）", text: $preparedBy).textFieldStyle(.roundedBorder)
                    TextField("交接备注（可选）", text: $notes, axis: .vertical).lineLimit(2...4).textFieldStyle(.roundedBorder)
                }
                .disabled(exporting)
                if let problem { Text(problem).foregroundStyle(Theme.warning).textSelection(.enabled) }
                HStack {
                    if exporting { ProgressView().controlSize(.small); Text(exportStatus).foregroundStyle(.secondary) }
                    Spacer()
                    Button(exporting ? "取消导出" : "取消") {
                        if let exportTask { exportTask.cancel() } else { dismiss() }
                    }.keyboardShortcut(.cancelAction)
                    Button("导出…") { startExport() }.keyboardShortcut(.defaultAction).disabled(exporting || selectedRecords.isEmpty)
                }
            }
        }
        .padding(24).frame(width: 480)
        .background(Theme.surface)
        .interactiveDismissDisabled(exporting)
        .onDisappear { exportTask?.cancel() }
    }
    private func startExport() {
        guard let directory = FolderPicker.choose(start: nil) else { return }
        let records = selectedRecords
        let options = HandoffReport.Options(projectID: project.id, projectName: project.name,
            scope: entireProject ? "整个项目的已记录导入" : "所选一次导入（仅此项目）", preparedBy: preparedBy, notes: notes,
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
        exporting = true; problem = nil; exportStatus = String(localized: "正在整理导入记录…")
        exportTask = Task {
            let worker = Task.detached(priority: .utility) {
                let snapshot = try HandoffReport.snapshot(batches: records, options: options)
                return try HandoffPackage.write(snapshot, to: directory) { message in
                    Task { @MainActor in exportStatus = message }
                }
            }
            do {
                result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
            } catch is CancellationError { problem = String(localized: "已取消导出。") }
            catch { problem = String(localized: "导出未完成：\(error.localizedDescription)") }
            exporting = false; exportTask = nil
        }
    }
}
