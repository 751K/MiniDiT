import AppKit
import SonyRemoteKit
import SwiftUI

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
        FileManager.default.fileExists(atPath: model.sessionsFolder.appending(path: cleanName).path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入到 Capture One 会话").font(.title2.bold())
            Picker("", selection: $useExisting) {
                Text("新建会话").tag(false)
                Text("加入已有会话").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden()
            .disabled(request.existing.isEmpty)

            if !useExisting {
                TextField("会话名称", text: $name, prompt: Text("例如 3.15-公园"))
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if canStart { start() } }
                if !model.recentContents.isEmpty {
                    HStack(spacing: 6) {
                        Text("最近：").font(.caption).foregroundStyle(.secondary)
                        ForEach(model.recentContents.prefix(6), id: \.self) { c in
                            Button(c) { name = datePrefix + c }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                Text(nameTaken ? "已经有同名的文件夹了，换个名字，或者选「加入已有会话」。"
                     : "会放在 \(model.sessionsFolder.path(percentEncoded: false))/\(cleanName.isEmpty ? "…" : cleanName)/")
                    .font(.caption).foregroundStyle(nameTaken ? Color.orange : Color.secondary)
            } else {
                List(request.existing, id: \.self, selection: $existing) { f in
                    Text(f.deletingPathExtension().lastPathComponent)
                }
                .frame(height: 180)
            }
            Text("\(model.selectedShotCount) 张（\(model.selectedFiles().count) 个文件），\(ImportBar.bytes(model.selectionBytes))，下载到会话的 Capture 文件夹。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("取消") { model.sessionRequest = nil }.keyboardShortcut(.cancelAction)
                Button("开始导入") { start() }.keyboardShortcut(.defaultAction).disabled(!canStart)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { name = request.suggestedName; focused = true }
    }

    /// 名字里「-」之前的日期部分（没有就用建议的日期）。
    private var datePrefix: String {
        if let dash = name.firstIndex(of: "-") { return String(name[...dash]) }
        return request.suggestedName
    }

    private var canStart: Bool { useExisting ? existing != nil : (!cleanName.isEmpty && !nameTaken) }

    private func start() {
        if useExisting, let existing { model.startImport(session: .existing(existing)) }
        else { model.startImport(session: .new(cleanName)) }
    }
}
