import MiniDiTCore
import SwiftUI

struct CardIdentityConfirmation: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let sourceID: Int
    let root: URL
    @State private var selected: UUID?
    @State private var name = ""
    @State private var failure: String?

    private var store: SourceIdentityStore { model.sourceIdentities }
    private var candidates: [CardIdentityProfile] {
        let kind = store.binding(for: root)?.descriptor.kind
        return store.profiles.filter { $0.descriptor.kind == kind }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(store.binding(for: root)?.descriptor.kind == .directory ? "确认目录身份" : "确认存储卡身份").font(.system(size: 22, weight: .bold))
            Text("选择之前的来源，或另建档案。名称相同不会自动合并。")
                .foregroundStyle(.secondary)
            Picker("来源档案", selection: $selected) {
                Text("新建档案").tag(UUID?.none)
                ForEach(candidates) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            Text(root.path).font(Theme.Font.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if store.binding(for: root)?.descriptor.matchKey == nil {
                Text("此来源未提供稳定标识，下次连接仍需确认。")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            if let failure { Text(failure).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("确认") {
                    if store.confirm(root: root, existing: selected, name: name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                        dismiss()
                    } else { failure = store.errorMessage ?? String(localized: "该档案已用于另一个来源，请为这张卡新建档案。") }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(model.progress != nil || model.cardRoot(for: sourceID) == nil)
            }
        }
        .padding(24).frame(width: 500)
        .background(Theme.surface)
        .onAppear {
            selected = store.binding(for: root)?.profileID
            name = store.name(for: root)
        }
        .onChange(of: selected) { _, id in
            name = id.flatMap { id in store.profiles.first { $0.id == id }?.name } ?? store.binding(for: root)?.descriptor.label ?? ""
        }
    }
}

struct ImportSourceIdentityDetails: View {
    let identity: ImportSourceIdentity
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("来源信息").font(Theme.Font.headline)
            if identity.kind == .camera {
                if let model = identity.cameraModel { LabeledContent("拍摄机型", value: model) }
                LabeledContent("机身序列号", value: identity.cameraSerial ?? String(localized: "未提供"))
                if let slot = identity.slot { LabeledContent("相机卡槽", value: String(slot)) }
            }
            if let name = identity.cardName { LabeledContent(identity.kind == .directory ? "目录名称" : "存储卡", value: name) }
            if identity.kind == .card {
                LabeledContent("存储卡类型", value: identity.cardType?.displayName ?? String(localized: "未识别"))
            }
            if let size = identity.capacity {
                LabeledContent("容量", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file))
            }
            if let id = identity.cardID { LabeledContent(identity.kind == .directory ? "目录档案编号" : "卡档案编号", value: id.uuidString).textSelection(.enabled) }
            if let uuid = identity.volumeUUID { LabeledContent("卷标识", value: uuid).textSelection(.enabled) }
        }
        .padding(18).frame(width: 400, alignment: .leading)
    }
}
