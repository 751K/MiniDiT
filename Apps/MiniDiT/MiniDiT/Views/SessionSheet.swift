import AppKit
import SonyRemoteKit
import SwiftUI

/// 给这批照片定一个去处：新建会话，或加入已有会话。
struct SessionSheet: View {
    @Environment(AppModel.self) private var model
    let request: AppModel.SessionRequest
    @State private var name = ""
    @State private var useExisting = false
    @State private var existing: URL?
    @FocusState private var focused: Bool

    private var cleanName: String {
        name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
    private var nameTaken: Bool {
        !cleanName.isEmpty && FileManager.default.fileExists(atPath: model.sessionsFolder.appending(path: cleanName).path)
    }
    /// 只有日期前缀（「11.4-」）还不算填好。
    private var nameReady: Bool { !cleanName.isEmpty && !cleanName.hasSuffix("-") }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("导入 \(model.selectedShotCount) 张照片").font(.system(size: 17, weight: .semibold))
                Text("\(model.selectedFiles().count) 个文件 · \(FloatingBar.bytes(model.selectionBytes))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Picker("导入方式", selection: $useExisting) {
                Text("新建会话").tag(false)
                Text("加入已有会话").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(request.existing.isEmpty)

            Group {
                if !useExisting {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("会话名称").font(.system(size: 12, weight: .semibold))
                        TextField("会话名称", text: $name, prompt: Text("例如 11.4-公园"))
                            .textFieldStyle(.roundedBorder).controlSize(.large)
                            .labelsHidden()
                            .focused($focused)
                            .onSubmit { if canStart { start() } }
                            .padding(.top, 6)
                        HStack(alignment: .top, spacing: 6) {
                            if nameTaken {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                                Text("这个位置已有同名文件夹。请换个名字，或改用「加入已有会话」。")
                            } else {
                                Text("放在 " + model.sessionsFolder.appending(path: cleanName.isEmpty ? "…" : cleanName).path(percentEncoded: false))
                                    .foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                            }
                        }
                        .font(.system(size: 12))
                        .padding(.top, 10)
                        Spacer(minLength: 8)
                        if !model.recentContents.isEmpty {
                            HStack(spacing: 6) {
                                Text("最近").font(.system(size: 12)).foregroundStyle(.secondary)
                                ForEach(model.recentContents.prefix(6), id: \.self) { c in
                                    Button { name = datePrefix + c } label: {
                                        Text(c).font(.system(size: 12)).padding(.horizontal, 10).frame(height: 24)
                                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                                            .contentShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                } else {
                    List(request.existing, id: \.self, selection: $existing) { f in
                        Text(f.deletingPathExtension().lastPathComponent)
                    }
                    .listStyle(.bordered)
                    .accessibilityLabel("最近 15 个会话")
                }
            }
            .frame(height: 168, alignment: .top)

            HStack(spacing: 8) {
                Text("下载到会话的 Capture 文件夹").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { model.sessionRequest = nil }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button { start() } label: { Text("开始导入").fontWeight(.semibold).padding(.horizontal, 4) }
                    .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { name = request.suggestedName; focused = true }
    }

    /// 名字里「-」之前的日期部分（没有就用建议的日期）。
    private var datePrefix: String {
        if let dash = name.firstIndex(of: "-") { return String(name[...dash]) }
        return request.suggestedName
    }

    private var canStart: Bool { useExisting ? existing != nil : (nameReady && !nameTaken) }

    private func start() {
        if useExisting, let existing { model.startImport(session: .existing(existing)) }
        else { model.startImport(session: .new(cleanName)) }
    }
}
