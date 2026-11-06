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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("导入 \(model.countText(model.grid.selected, noun: true))").font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 0)
                Text("\(model.selectedFiles().count) 个文件 · \(FloatingBar.bytes(model.selectionBytes))")
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            if !isLightroom {
                SlidingSegment(options: [("新建会话", false), ("加入已有会话", true)], selection: $useExisting, fill: true)
                    .disabled(request.existing.isEmpty || !request.resume.isEmpty)
                    .help(request.existing.isEmpty ? "会话文件夹中尚无会话" : "")
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("导入方式")
            }

            Group {
                if !useExisting {
                    newSessions
                } else {
                    existingList
                }
            }
            .frame(maxHeight: 360, alignment: .top)
            .fixedSize(horizontal: false, vertical: !useExisting)

            HStack(spacing: 6) {
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
        .padding(18)
        .frame(width: groups.count > 1 && !useExisting ? 520 : 460)
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
                SlidingSegment(options: groupings.map { ($0.title, $0) }, selection: $model.sessionGrouping, fill: true)
                    .disabled(!request.resume.isEmpty)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("分成")
            }
            Text(groups.count > 1 ? "事件名" : "事件名（选填）").font(.system(size: 12, weight: .semibold))
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
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.06)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Divider().padding(.top, 2)
            whereRow
        }
    }

    /// 只有一组时，名字下面直接写这一组的问题（同名等）；没问题就写存到哪。
    private var singleProblem: String? {
        guard groups.count == 1, let g = groups.first, request.resume[g.id] == nil else { return nil }
        return problem(g)
    }

    @ViewBuilder private var whereRow: some View {
        if let p = singleProblem {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("名称不可用").fontWeight(.semibold)
                    Text(p).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wherePath).lineLimit(1).truncationMode(.middle)
                    Text(footerText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("更改…") { changeFolder() }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .help(wherePath)
        }
    }

    /// 一组：完整的会话路径；几组：放会话的文件夹。
    private var wherePath: String {
        let base = isLightroom ? model.destination : model.sessionsFolder
        let path = base.path(percentEncoded: false)
        guard !isLightroom, groups.count == 1, let g = groups.first else { return path }
        return base.appending(path: sessionName(g), directoryHint: .isDirectory).path(percentEncoded: false)
    }

    private func changeFolder() {
        if isLightroom {
            if let url = FolderPicker.choose(start: model.destination) { model.destination = url }
        } else {
            if let url = FolderPicker.choose(start: model.sessionsFolder) { model.sessionsFolder = url }
            openInC1 = CaptureOneBridge.openDocumentNames()
        }
    }

    // MARK: 加入已有会话

    private var existingList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(request.existing, id: \.self) { f in
                    let on = existing == f
                    Button { existing = f } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(on ? 1 : 0).frame(width: 16)
                            Text(f.deletingPathExtension().lastPathComponent).fontWeight(on ? .semibold : .regular).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(Self.when(f)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(on ? Color.primary.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(3)
        }
        .frame(height: 160)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
        .accessibilityLabel("最近 15 个会话")
    }

    /// 「今天」「昨天」「3 天前」，再早就写日期。
    static func when(_ url: URL) -> String {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: .now)).day ?? 0
        switch days {
        case ..<1: return "今天"
        case 1: return "昨天"
        case 2...6: return "\(days) 天前"
        default: return d.formatted(.dateTime.month().day())
        }
    }

    @ViewBuilder private func row(_ g: AppModel.ImportGroup) -> some View {
        let name = sessionName(g)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(g.title).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: groups.count > 1 ? 170 : 96, alignment: .leading)
                if let r = request.resume[g.id] {
                    Text("继续导入至“\(r.name)”").font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    TextField("事件名", text: binding(g.id), prompt: Text("例如：公园"))
                        .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden()
                        .focused($focusedRow, equals: g.id)
                        .onSubmit { if canStart { start() } }
                }
                Text(AppModel.countText(photos: g.shotCount - g.videoCount, videos: g.videoCount)).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            if request.resume[g.id] == nil, groups.count > 1 {
                HStack(spacing: 4) {
                    if let problem = problem(g) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(problem)
                    } else {
                        Text("\(unit)：\(name)").foregroundStyle(.secondary)
                    }
                }
                .font(.system(size: 11))
                .padding(.leading, groups.count > 1 ? 178 : 104)
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
            return groups.filter({ sessionName($0) == name }).count > 1 ? "与其他收藏夹重名（\(name)），将合并为同一收藏夹，请填写不同的事件名" : nil
        }
        if FileManager.default.fileExists(atPath: model.sessionsFolder.appending(path: name).path) {
            return "已存在同名会话“\(name)”，请填写或修改事件名"
        }
        if openInC1.contains(name) {
            return "Capture One 中已打开同名会话“\(name)”，请更换事件名"
        }
        if groups.filter({ sessionName($0) == name }).count > 1 {
            return "与其他会话重名（\(name)），请填写不同的事件名"
        }
        return nil
    }

    private var footerText: String {
        guard isLightroom else { return "照片存入会话的 Capture 文件夹" }
        guard let lrc, lrc.isFresh else { return "Lightroom Classic 将自动打开，照片将添加到其当前目录" }
        return "添加到 Lightroom Classic 目录“\(lrc.catalogName)”"
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
