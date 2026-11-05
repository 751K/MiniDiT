import AppKit
import SonyRemoteKit
import SwiftUI

/// 给这批照片定去处：新建会话（可以按天 / 按场分成几个），或加入已有会话。
struct SessionSheet: View {
    @Environment(AppModel.self) private var model
    let request: AppModel.SessionRequest
    /// 各分组填的事件名（按分组 key 记，切换分法时同一天的不会丢）。
    @State private var events: [String: String] = [:]
    @State private var useExisting = false
    @State private var existing: URL?
    @FocusState private var focusedRow: String?
    /// 点「最近」里的事件名时填到哪一行。
    @State private var lastRow: String?
    /// C1 里开着的文档：同名会话建不了。
    @State private var openInC1: Set<String> = []
    /// 导入到 Lightroom Classic：每组是一个收藏夹，没有「加入已有会话」。
    private var isLightroom: Bool { model.captureOneMode == .lightroom }
    private var unit: String { isLightroom ? "收藏夹" : "会话" }
    @State private var lrc: LightroomBridge.Heartbeat?

    private var groups: [AppModel.ImportGroup] { model.importGroups(model.sessionGrouping) }

    /// 能选的分法：分出来不止一组的才列出来。
    private var groupings: [AppModel.SessionGrouping] {
        let perDay = model.importGroups(.perDay).count
        let perScene = model.importGroups(.perScene).count
        var out: [AppModel.SessionGrouping] = [.single]
        if perDay > 1 { out.append(.perDay) }
        if perScene > perDay { out.append(.perScene) }
        return out
    }

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("导入 \(model.selectedShotCount) 张照片").font(.system(size: 17, weight: .semibold))
                Text("\(model.selectedFiles().count) 个文件 · \(FloatingBar.bytes(model.selectionBytes))")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !isLightroom {
                Picker("导入方式", selection: $useExisting) {
                    Text("新建会话").tag(false)
                    Text("加入已有会话").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(request.existing.isEmpty || !request.resume.isEmpty)
            }

            Group {
                if !useExisting {
                    newSessions
                } else {
                    List(request.existing, id: \.self, selection: $existing) { f in
                        Text(f.deletingPathExtension().lastPathComponent)
                    }
                    .listStyle(.bordered)
                    .accessibilityLabel("最近 15 个会话")
                }
            }
            .frame(minHeight: 168, maxHeight: 360, alignment: .top)
            .fixedSize(horizontal: false, vertical: !useExisting)

            HStack(spacing: 8) {
                Text(footerText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("取消") { model.sessionRequest = nil }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button { start() } label: {
                    Text(!useExisting && groups.count > 1 ? "导入到 \(groups.count) 个\(unit)" : "开始导入")
                        .fontWeight(.semibold).padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!canStart)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            if isLightroom { lrc = LightroomBridge.heartbeat() } else { openInC1 = CaptureOneBridge.openDocumentNames() }
            if !groupings.contains(model.sessionGrouping) { model.sessionGrouping = .single }
            focusedRow = groups.first { request.resume[$0.id] == nil }?.id
        }
        .onChange(of: model.sessionGrouping) { _, _ in
            focusedRow = groups.first { request.resume[$0.id] == nil }?.id
        }
        .onChange(of: focusedRow) { _, row in if let row { lastRow = row } }
    }

    // MARK: 新建会话

    private var newSessions: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            if groupings.count > 1 {
                Picker("分成", selection: $model.sessionGrouping) {
                    ForEach(groupings) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(!request.resume.isEmpty)
            }
            Text(groups.count > 1 ? "事件名" : "事件名（可不填）").font(.system(size: 12, weight: .semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(groups) { g in row(g) }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: groups.count > 3 ? 230 : nil)
            .fixedSize(horizontal: false, vertical: groups.count <= 3)
            if !model.recentContents.isEmpty {
                HStack(spacing: 6) {
                    Text("最近").font(.system(size: 12)).foregroundStyle(.secondary)
                    ForEach(model.recentContents.prefix(6), id: \.self) { c in
                        Button {
                            if let row = lastRow ?? groups.first(where: { request.resume[$0.id] == nil })?.id { events[row] = c }
                        } label: {
                            Text(c).font(.system(size: 12)).padding(.horizontal, 10).frame(height: 24)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Text(isLightroom
                 ? "收藏夹按命名模板“\(NameTemplate.current(.session))”命名，放在收藏夹集“MiniDiT”里；照片存到 \(model.destination.path(percentEncoded: false))，按“\(NameTemplate.current(.folder))”分文件夹。"
                 : "会话按命名模板“\(NameTemplate.current(.session))”命名，放在 \(model.sessionsFolder.path(percentEncoded: false))。模板可在“设置 › 导入 › 命名”中修改。")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
        }
    }

    @ViewBuilder private func row(_ g: AppModel.ImportGroup) -> some View {
        let name = sessionName(g)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(g.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 170, alignment: .leading)
                if let r = request.resume[g.id] {
                    Text("继续导入到「\(r.name)」").font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    TextField("事件名", text: binding(g.id), prompt: Text("例如 公园"))
                        .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden()
                        .focused($focusedRow, equals: g.id)
                        .onSubmit { if canStart { start() } }
                }
                Text("\(g.shotCount) 张").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            if request.resume[g.id] == nil {
                HStack(spacing: 4) {
                    if let problem = problem(g) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(problem)
                    } else {
                        Text("\(unit)：\(name)").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .padding(.leading, 178)
            }
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { events[key] ?? "" }, set: { events[key] = $0 })
    }

    private func event(_ g: AppModel.ImportGroup) -> String? {
        let e = NameTemplate.sanitize(events[g.id] ?? "")
        return e.isEmpty ? nil : e
    }

    private func sessionName(_ g: AppModel.ImportGroup) -> String {
        if let r = request.resume[g.id] { return r.name }
        return AppModel.sessionName(for: g, event: event(g))
    }

    /// 这一行的名字不能用的原因：磁盘上已有，或和别的行重名。
    private func problem(_ g: AppModel.ImportGroup) -> String? {
        let name = sessionName(g)
        if isLightroom {
            // 同名收藏夹已经有了就加进去，不算问题；只提醒这一批里重名（会合进同一个收藏夹）。
            return groups.filter({ sessionName($0) == name }).count > 1 ? "和其他收藏夹重名（\(name)），会合并成一个，请填写不同的事件名" : nil
        }
        if FileManager.default.fileExists(atPath: model.sessionsFolder.appending(path: name).path) {
            return "已有同名会话「\(name)」，请填写或修改事件名"
        }
        if openInC1.contains(name) {
            return "Capture One 里已打开同名会话「\(name)」，请换个事件名"
        }
        if groups.filter({ sessionName($0) == name }).count > 1 {
            return "和其他会话重名（\(name)），请填写不同的事件名"
        }
        return nil
    }

    private var footerText: String {
        guard isLightroom else { return "下载到会话的 Capture 文件夹" }
        guard let lrc, lrc.isFresh else { return "Lightroom Classic 会自动打开，照片加进它当前的目录" }
        return "加入 Lightroom Classic 目录“\(lrc.catalogName)”"
    }

    private var canStart: Bool {
        if useExisting { return existing != nil }
        return !groups.isEmpty && groups.allSatisfy { request.resume[$0.id] != nil || problem($0) == nil }
    }

    private func start() {
        if useExisting, let existing { model.startImport(session: .existing(existing)); return }
        let jobs = groups.map { g -> AppModel.ImportJob in
            if let r = request.resume[g.id] {
                return .init(key: g.id, files: g.files, session: r.session, event: r.event, scene: g.scene)
            }
            return .init(key: g.id, files: g.files, session: .new(sessionName(g)), event: event(g), scene: g.scene)
        }
        model.startImport(jobs: jobs, grouping: model.sessionGrouping)
    }
}
