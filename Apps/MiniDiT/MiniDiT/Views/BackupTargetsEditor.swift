import SwiftUI
import MiniDiTCore

/// Shared by Settings and onboarding; the global backup switch lives in the caller.
struct BackupTargetsEditor: View {
    @Environment(AppModel.self) private var model
    @State private var renameID: UUID?
    @State private var name = ""
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(model.backupTargets) { target in
                let bindings = BackupTargetBindings(model: model, id: target.id)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Text(target.name).font(Theme.Font.body.weight(.medium)).lineLimit(1)
                        Text(target.required ? "必需" : "可选")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                        Menu {
                            Button("更改位置…") { chooseReplacement(target) }
                            Button("重命名…") { renameID = target.id; name = target.name }
                            Toggle("必须完成此备份", isOn: bindings.required)
                            Divider()
                            Button("移除此位置") { bindings.remove() }
                        } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("\(target.name)的备份设置")
                        Spacer(minLength: 8)
                        if target.availability == .available, let free = AppModel.freeSpace(at: target.root) {
                            Text(String(localized: "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: free), countStyle: .file)) 可用"))
                                .font(Theme.Font.caption).foregroundStyle(.secondary).fixedSize()
                        }
                        BackupSettingsSwitch(title: "启用“\(target.name)”", isOn: bindings.enabled)
                    }
                    Button { chooseReplacement(target) } label: {
                        HStack(spacing: 4) {
                            Text((target.path as NSString).abbreviatingWithTildeInPath)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .font(Theme.Font.caption)
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help("更改位置：\(target.path)")
                    .accessibilityLabel("更改“\(target.name)”的备份位置")
                    if let note = model.backupTargetNote(target) {
                        Text(note).font(Theme.Font.caption.weight(.medium))
                            .foregroundStyle(target.enabled ? Theme.warning : Color.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 12)
                Divider()
            }
            HStack {
                Button("添加备份位置…", systemImage: "plus") {
                    guard let root = FolderPicker.choose(start: nil) else { return }
                    if model.backupTargets.contains(where: { BackupDestination.overlaps($0.root, root) }) {
                        problem = String(localized: "备份位置相同或互相包含，请选择另一个位置。")
                    } else { model.addBackupTarget(root) }
                }
                .buttonStyle(.plain).foregroundStyle(.tint)
                Spacer()
            }
            .padding(.vertical, 10)
        }
        .task(id: model.backupDiskProbeKey) { await model.refreshBackupDiskIdentities() }
        .alert("重命名备份位置", isPresented: Binding(get: { renameID != nil }, set: { if !$0 { renameID = nil } })) {
            TextField("名称", text: $name)
            Button("保存") {
                let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty, let id = renameID { model.updateBackupTarget(id) { $0.name = clean } }
                renameID = nil
            }
            Button("取消", role: .cancel) { renameID = nil }
        }
        .alert("无法设置备份位置", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("好") { problem = nil }
        } message: { Text(problem ?? "") }
    }
    private func chooseReplacement(_ target: BackupDestination) {
        guard let root = FolderPicker.choose(start: target.root) else { return }
        if model.backupTargets.contains(where: { $0.id != target.id && BackupDestination.overlaps($0.root, root) }) {
            problem = String(localized: "备份位置相同或互相包含，请选择另一个位置。")
        } else { model.replaceBackupTarget(target.id, root: root) }
    }
}

/// Every switch on the backup page uses the same native size and label policy.
struct BackupSettingsSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn)
            .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
    }
}

/// Bind by identity, never by an array index or a binding-captured row. Menus
/// and native controls may retain their bindings after the row is removed.
@MainActor
struct BackupTargetBindings {
    let model: AppModel
    let id: UUID

    var enabled: Binding<Bool> { flag(\.enabled) }
    var required: Binding<Bool> { flag(\.required) }
    func remove() { model.removeBackupTarget(id) }

    private func flag(_ field: WritableKeyPath<BackupDestination, Bool>) -> Binding<Bool> {
        Binding(get: { model.backupTargets.first { $0.id == id }?[keyPath: field] ?? false },
                set: { value in model.updateBackupTarget(id) { $0[keyPath: field] = value } })
    }
}
