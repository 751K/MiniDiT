import AppKit
import MiniDiTCore
import SwiftUI

struct ProjectImportResults: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: ShootSession
    @State private var selected: UUID?
    @State private var showingExport = false
    @State private var refreshID = UUID()
    private var journal: ImportJournalStore { model.importJournal }
    private var records: [ImportBatchRecord] { journal.records(for: project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("导入记录与备份").font(.system(size: 22, weight: .bold))
                    Text(project.name).foregroundStyle(.secondary)
                }
                Spacer()
                Button("导出交接清单…") { showingExport = true }
                    .disabled(records.isEmpty || model.progress != nil || journal.repairTask != nil || journal.persistenceError != nil)
                Button { refreshID = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.bordered).help("刷新文件状态").accessibilityLabel("刷新文件状态")
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            if let error = journal.persistenceError {
                Text(error).foregroundStyle(.orange).padding(20)
            }
            if records.isEmpty {
                ContentUnavailableView("暂无导入记录", systemImage: "tray", description: Text("导入此项目后，可以在这里查看结果和补备份。"))
            } else {
                HSplitView {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(records) { record in
                                Button { selected = record.id } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(record.startedAt.formatted(.dateTime.year().month().day().hour().minute().locale(.app))).fontWeight(.semibold)
                                        Text(batchDescription(record)).foregroundStyle(.secondary)
                                        if record.backupRequested, record.pendingBackupCount > 0 {
                                            Text("\(record.pendingBackupCount) 项备份待补").foregroundStyle(.orange)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                                    .background((selected ?? records.first?.id) == record.id ? Theme.accent.opacity(0.12) : .clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                }.buttonStyle(.plain)
                            }
                        }.padding(12)
                    }.frame(minWidth: 210, idealWidth: 230, maxWidth: 270)
                    if let record = records.first(where: { $0.id == selected }) ?? records.first {
                        detail(record).frame(minWidth: 430, maxWidth: .infinity)
                    }
                }
            }
        }
        .frame(minWidth: 740, idealWidth: 880, minHeight: 480, idealHeight: 620)
        .background(Theme.surface)
        .task { journal.includeLegacy(project: project, history: ImportHistory.shared.records) }
        .sheet(isPresented: $showingExport) {
            HandoffExportSheet(project: project, records: records, selectedBatch: selected ?? records.first?.id)
        }
    }

    private func batchDescription(_ batch: ImportBatchRecord) -> String {
        let files = batch.files.filter { $0.projectID == project.id }
        let saved = files.filter { $0.state == .saved }.count
        let state: String
        switch batch.state {
        case .running: state = String(localized: "正在导入")
        case .interrupted: state = String(localized: "导入中断")
        case .cancelled: state = String(localized: "已取消")
        case .legacy: state = String(localized: "历史导入")
        case .completed: state = saved == files.count ? String(localized: "文件已保存") : String(localized: "部分文件未保存")
        }
        return String(localized: "\(saved)/\(files.count) 项 · \(state)")
    }

    private func detail(_ batch: ImportBatchRecord) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(batchDescription(batch)).font(Theme.Font.headline)
                if batch.files.contains(where: { $0.projectID != project.id }) {
                    Text("本次导入涉及多个项目；补备份和软件发送会处理原来的整批文件。")
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 14) {
                    Text("备份位置").fontWeight(.semibold)
                    ForEach(batch.targets) { target in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(target.name).fontWeight(.medium)
                                Text(target.required ? "必需" : "可选").foregroundStyle(.secondary)
                                Spacer()
                                Text("已校验 \(batch.verifiedCount(for: target))/\(batch.files.flatMap(\.assets).count)")
                                    .monospacedDigit().foregroundStyle(batch.pendingCount(for: target) > 0 ? Theme.warning : Color.secondary)
                            }
                            Text(target.path).textSelection(.enabled).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if target.availability != .available {
                                Text(target.availability == .wrongVolume ? "此位置的磁盘身份已变化" : target.availability == .readOnly ? "位置不可写入，请检查磁盘权限" : "位置未连接，重新连接后可补齐")
                                    .foregroundStyle(Theme.warning)
                            }
                            HStack {
                                Button("核对并补齐") { journal.repair(batch.id, root: target.root, changeTarget: false, targetID: target.id) }
                                    .buttonStyle(.bordered)
                                Button("更换位置…") {
                                    if let folder = FolderPicker.choose(start: target.root) {
                                        journal.repair(batch.id, root: folder, changeTarget: true, targetID: target.id)
                                    }
                                }.buttonStyle(.bordered)
                            }
                            .disabled(journal.repairTask != nil || model.progress != nil || batch.state == .running || batch.files.flatMap(\.assets).isEmpty)
                            if let error = batch.backupReportErrors?[target.id.uuidString] {
                                Text("校验清单未完成：\(error)").foregroundStyle(Theme.warning)
                            }
                            if journal.repairingBatch == batch.id, journal.repairingTarget == target.id {
                                HStack {
                                    ProgressView().controlSize(.small)
                                    Text(journal.repairProgress)
                                    Spacer()
                                    Button("取消") { journal.repairTask?.cancel() }
                                }
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 8).stroke(Theme.border))
                    }
                    if batch.targets.isEmpty { Text("尚未设置，可为本次导入添加备份。").foregroundStyle(.secondary) }
                    Button("添加备份位置…", systemImage: "plus") {
                        if let folder = FolderPicker.choose(start: nil) {
                            journal.repair(batch.id, root: folder, changeTarget: true, addingTarget: true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(journal.repairTask != nil || model.progress != nil || batch.state == .running || batch.files.flatMap(\.assets).isEmpty)
                    if journal.lastRepairBatch == batch.id {
                        if let summary = journal.repairSummary { Text(summary) }
                        ForEach(Array(journal.repairErrors.enumerated()), id: \.offset) { _, error in
                            Text(error).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                }
                if !batch.delivery.isEmpty || batch.videoDeliveries?.isEmpty == false {
                    Divider()
                    Text("后期软件").fontWeight(.semibold)
                    let deliveries = (batch.videoDeliveries ?? []).filter { $0.projectIDs.contains(project.id) }
                    ForEach(deliveries) { record in
                        VideoDeliveryResultRow(record: record, batchID: batch.id)
                    }
                    ForEach(batch.delivery.keys.sorted().filter { software in !(batch.videoDeliveries ?? []).contains { $0.software.name == software } }, id: \.self) { software in
                        Text("\(software)：\(batch.delivery[software] ?? "")")
                    }
                }
                Divider()
                LazyVStack(spacing: 0) {
                    ForEach(batch.files.filter { $0.projectID == project.id }) { file in
                        ImportFileResultRow(file: file, batch: batch, refreshID: refreshID)
                        Divider()
                    }
                }
                if !batch.reports.isEmpty {
                    Menu("校验清单") {
                        ForEach(batch.reports, id: \.self) { path in
                            Button(URL(filePath: path).lastPathComponent) {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                            }
                        }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }.padding(20)
        }
    }
}

private struct ImportFileResultRow: View {
    let file: ImportedFileRecord
    let batch: ImportBatchRecord
    let refreshID: UUID
    @State private var showSourceIdentity = false

    private var missingBackup: Bool {
        guard batch.backupRequested else { return false }
        return file.assets.contains { asset in
            batch.targets.isEmpty || batch.targets.contains { !asset.hasBackup(at: $0) || asset.error(for: $0) != nil }
        }
    }

    private var status: String {
        guard file.state == .saved else { return file.state == .failed ? String(localized: "未保存") : String(localized: "未完成") }
        if missingBackup { return String(localized: "待补备份") }
        if file.message != nil { return String(localized: "需查看") }
        return file.proxyOnly ? String(localized: "仅代理") : String(localized: "已保存")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(file.filename).font(Theme.Font.headline).lineLimit(1).truncationMode(.middle)
                if let primary = file.assets.first(where: { $0.kind == .original }) ?? file.assets.first {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: primary.size), countStyle: .file))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .help("\(primary.size.formatted()) 字节")
                }
                Spacer(minLength: 12)
                Text(status).foregroundStyle(file.state == .saved && !missingBackup && file.message == nil ? Color.secondary : .orange)
            }
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 7) {
                GridRow {
                    field("导入时间：")
                    Text(file.importedAt.map {
                        $0.formatted(.dateTime.year().month().day().hour().minute().second().locale(.app))
                    } ?? String(localized: "未记录"))
                }
                GridRow {
                    field("导入设备：")
                    HStack(spacing: 6) {
                        Text(file.source).textSelection(.enabled)
                        if let identity = file.sourceIdentity {
                            Button { showSourceIdentity = true } label: { Image(systemName: "info.circle") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("查看机身与存储卡信息").accessibilityLabel("查看机身与存储卡信息")
                                .popover(isPresented: $showSourceIdentity) { ImportSourceIdentityDetails(identity: identity) }
                        }
                    }
                }
                GridRow {
                    field("来源地址：")
                    if let address = file.sourceAddress, address.hasPrefix("/") {
                        CopyResultRow(path: address).id("source-\(refreshID)")
                    } else {
                        Text(file.sourceAddress ?? String(localized: "未记录")).textSelection(.enabled)
                    }
                }
                if !file.assets.contains(where: { $0.copies.contains { $0.role == .working } }) {
                    GridRow { field("导入地址："); Text("尚未保存").foregroundStyle(.secondary) }
                }
                ForEach(file.assets) { asset in
                    ForEach(asset.copies.filter { $0.role == .working }) { copy in
                        GridRow {
                            field("导入地址：")
                            CopyResultRow(path: copy.path).id("\(copy.id)-\(refreshID)")
                        }
                    }
                }
                if !file.assets.contains(where: { $0.copies.contains { $0.role == .backup } }) {
                    GridRow {
                        field("备份地址：")
                        Text(batch.backupRequested ? "待备份" : "未设置").foregroundStyle(batch.backupRequested ? Color.orange : .secondary)
                    }
                }
                ForEach(batch.targets.filter { target in file.assets.contains { !$0.hasBackup(at: target) || $0.error(for: target) != nil } }) { target in
                    GridRow {
                        field("备份地址：")
                        Text("\(target.name) · 待补齐").foregroundStyle(Theme.warning)
                    }
                }
                ForEach(file.assets) { asset in
                    ForEach(asset.copies.filter { $0.role == .backup }) { copy in
                        GridRow {
                            field("备份地址：")
                            CopyResultRow(path: copy.path).id("\(copy.id)-\(refreshID)")
                        }
                    }
                }
            }
            .font(.system(size: 12))
            if let message = file.message { Text(message).foregroundStyle(.orange) }
            ForEach(file.assets) { asset in
                AssetChecksumRow(asset: asset)
                if let errors = asset.targetErrors {
                    ForEach(errors.keys.sorted(), id: \.self) { id in
                        let name = batch.targets.first(where: { $0.id.uuidString == id })?.name ?? String(localized: "备份")
                        Text("\(name)：\(errors[id] ?? "")")
                            .foregroundStyle(Theme.warning)
                    }
                } else if let error = asset.backupError { Text(error).foregroundStyle(.orange) }
            }
        }
        .padding(.vertical, 12)
    }

    private func field(_ label: LocalizedStringKey) -> some View {
        Text(label).foregroundStyle(.secondary).fixedSize()
    }
}

private struct CopyResultRow: View {
    let path: String
    @State private var accessible: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
            } label: {
                Label(path, systemImage: "folder").lineLimit(1).truncationMode(.middle)
            }
            .buttonStyle(.link)
            .help("在访达中显示：\(path)")
            .accessibilityLabel("在访达中显示 \(path)")
            .disabled(accessible != true)
            if accessible == false {
                Text("不可访问").foregroundStyle(.orange).fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: path) {
            accessible = await Task.detached { FileManager.default.isReadableFile(atPath: path) }.value
        }
    }
}

private struct AssetChecksumRow: View {
    let asset: ImportedAssetRecord
    @State private var showVerification = false

    var body: some View {
        HStack(spacing: 8) {
            if let hash = asset.xxh64 {
                Text("XXH64：").foregroundStyle(.secondary)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(hash, forType: .string)
                } label: {
                    HStack(spacing: 5) {
                        Text(hash).monospaced()
                        Image(systemName: "doc.on.doc")
                    }
                }
                .buttonStyle(.link).help("复制 xxHash64 校验值")
                .accessibilityLabel("复制 xxHash64 校验值 \(hash)")
            }
            Button { showVerification = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("查看核验时间").accessibilityLabel("查看核验时间")
                .popover(isPresented: $showVerification) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("核验记录").font(Theme.Font.headline)
                        ForEach(asset.copies) { copy in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(copy.path).textSelection(.enabled)
                                Text(copy.verifiedAt.map {
                                    String(localized: "上次核验：\($0.formatted(.dateTime.year().month().day().hour().minute().locale(.app)))")
                                } ?? String(localized: "核验时间未记录"))
                                .foregroundStyle(.secondary)
                            }
                        }
                    }.padding(18).frame(width: 380, alignment: .leading)
                }
        }
        .font(.system(size: 12))
    }
}
