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
        let files = model.selectedFiles()
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("导入 \(model.countText(model.grid.selected, noun: true))").font(Theme.Font.headline)
                Spacer(minLength: 0)
                Text("\(files.count) 个文件 · \(FloatingBar.bytes(model.selectionBytes(of: files)))")
                    .font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !isLightroom {
                SegmentPicker(options: [.init(title: String(localized: "新建会话"), value: false), .init(title: String(localized: "加入已有会话"), value: true)],
                             selection: $useExisting, fill: true)
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
                    .buttonStyle(.bordered).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(startTitle) { start() }
                .buttonStyle(.borderedProminent).controlSize(.large)
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

    private var startTitle: String {
        guard !useExisting && groups.count > 1 else { return String(localized: "开始导入") }
        return isLightroom ? String(localized: "导入到 \(groups.count) 个收藏夹") : String(localized: "导入到 \(groups.count) 个会话")
    }

    // MARK: 新建会话

    private var newSessions: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 10) {
            if groupings.count > 1 {
                SegmentPicker(options: groupings.map { .init(title: $0.title, value: $0) },
                             selection: $model.sessionGrouping, fill: true)
                    .disabled(!request.resume.isEmpty)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("分成")
            }
            Text(groups.count > 1 ? "事件名" : "事件名（选填）").font(Theme.Font.headline)
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
                    Text("最近").font(Theme.Font.caption).foregroundStyle(.secondary)
                    ForEach(model.recentContents.prefix(6), id: \.self) { c in
                        Button(c) {
                            if let row = lastRow ?? groups.first(where: { request.resume[$0.id] == nil })?.id { events[row] = c }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
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
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                VStack(alignment: .leading, spacing: 1) {
                    Text("名称不可用").font(Theme.Font.headline)
                    Text(p).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wherePath).lineLimit(1).truncationMode(.middle)
                    Text(footerText).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("更改") { changeFolder() }.buttonStyle(.link)
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
        // 系统列表：选中行用系统的高亮，不自己画对勾。
        List(request.existing, id: \.self, selection: $existing) { f in
            HStack {
                Text(f.deletingPathExtension().lastPathComponent).lineLimit(1)
                Spacer(minLength: 8)
                Text(Self.when(f)).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
        .listStyle(.bordered(alternatesRowBackgrounds: false))
        .frame(height: 180)
        .accessibilityLabel("最近 15 个会话")
    }

    /// 「今天」「昨天」「3 天前」，再早就写日期。
    static func when(_ url: URL) -> String {
        guard let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return "" }
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: .now)).day ?? 0
        switch days {
        case ..<1: return String(localized: "今天")
        case 1: return String(localized: "昨天")
        case 2...6: return String(localized: "\(days) 天前")
        default: return d.formatted(.dateTime.month().day())
        }
    }

    @ViewBuilder private func row(_ g: AppModel.ImportGroup) -> some View {
        let name = sessionName(g)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(g.title).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: groups.count > 1 ? 170 : 96, alignment: .leading)
                if let r = request.resume[g.id] {
                    Text("继续导入至“\(r.name)”").lineLimit(1)
                    Spacer(minLength: 0)
                } else {
                    TextField("事件名", text: binding(g.id), prompt: Text("例如：公园"))
                        .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden()
                        .focused($focusedRow, equals: g.id)
                        .onSubmit { if canStart { start() } }
                }
                Text(AppModel.countText(photos: g.shotCount - g.videoCount, videos: g.videoCount)).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
            if request.resume[g.id] == nil, groups.count > 1 {
                HStack(spacing: 4) {
                    if let problem = problem(g) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        Text(problem)
                    } else {
                        Text(isLightroom ? String(localized: "收藏夹：\(name)") : String(localized: "会话：\(name)")).foregroundStyle(.secondary)
                    }
                }
                .font(Theme.Font.caption)
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
            return groups.filter({ sessionName($0) == name }).count > 1 ? String(localized: "与其他收藏夹重名（\(name)），将合并为同一收藏夹，请填写不同的事件名") : nil
        }
        if FileManager.default.fileExists(atPath: model.sessionsFolder.appending(path: name).path) {
            return String(localized: "已存在同名会话“\(name)”，请填写或修改事件名")
        }
        if openInC1.contains(name) {
            return String(localized: "Capture One 中已打开同名会话“\(name)”，请更换事件名")
        }
        if groups.filter({ sessionName($0) == name }).count > 1 {
            return String(localized: "与其他会话重名（\(name)），请填写不同的事件名")
        }
        return nil
    }

    private var footerText: String {
        guard isLightroom else { return String(localized: "照片存入会话的 Capture 文件夹") }
        guard let lrc, lrc.isFresh else { return String(localized: "Lightroom Classic 将自动打开，照片将添加到其当前目录") }
        return String(localized: "添加到 Lightroom Classic 目录“\(lrc.catalogName)”")
    }

    private var canStart: Bool {
        if useExisting { return existing != nil }
        return !groups.isEmpty && groups.allSatisfy { request.resume[$0.id] != nil || problem($0) == nil }
    }

    private func start() {
        guard let project = model.currentSession else {
            model.sessionRequest = nil
            model.newSessionPrompt = .init(importAfter: true)
            return
        }
        if useExisting, let existing { model.startImport(session: .existing(existing)); return }
        let jobs = groups.map { g -> AppModel.ImportJob in
            if let r = request.resume[g.id] {
                return .init(key: g.id, files: g.files, session: r.session, event: r.event, scene: g.scene,
                             folder: project.name, appSession: project.id)
            }
            return .init(key: g.id, files: g.files, session: .new(sessionName(g)), event: event(g), scene: g.scene,
                         folder: project.name, appSession: project.id)
        }
        model.startImport(jobs: jobs, grouping: model.sessionGrouping)
    }
}

/// 新建会话：由用户主动发起，选日期、填事件。日期从卡上的拍摄日里选，默认取侧栏里选中的那天。
/// 会话由软件自己管理，建好后成为当前会话；导入时 C1 会话、LrC 收藏夹、文件夹都沿用这个名字。
struct NewSessionSheet: View {
    @Environment(AppModel.self) private var model
    let prompt: AppModel.NewSessionPrompt
    /// yyyyMMdd：从卡上的拍摄日里选（再加上今天），不用系统的日期输入框和日历。
    @State private var day = ShootSession.dayKey(.now)
    @State private var showingCalendar = false
    /// 菜单里「其他日期…」的标记。
    private static let other = "other"
    @State private var event = ""
    // 仅在用户确认新建时应用；取消弹窗不修改保存位置。
    @State private var photoRoot: URL?
    @State private var videoRoot: URL?
    @State private var openInC1: Set<String> = []
    @State private var pickedContent = ImportContent.all
    @FocusState private var eventFocused: Bool

    /// 能选的日期：卡上的拍摄日（新的在前），今天不在里面就放在最前。
    private var dayChoices: [String] {
        var keys = model.days.map(\.id).filter { $0 != "unknown" }
        let today = ShootSession.dayKey(.now)
        if !keys.contains(today) { keys.insert(today, at: 0) }
        if !keys.contains(day) { keys.insert(day, at: 0) }
        return keys
    }
    private var cleanEvent: String? {
        let e = NameTemplate.sanitize(event)
        return e.isEmpty ? nil : e
    }
    private var name: String { ShootSession.name(day: day, event: cleanEvent) }
    private var existing: ShootSession? { model.sessions.first { $0.name == name } }
    private var exists: Bool { existing != nil }
    /// 同名项目已存在时沿用它的类型。
    private var content: ImportContent { existing?.contentType ?? pickedContent }
    /// C1 里开着同名文档、磁盘上又没有这个会话：导入时建不了。
    private var blocked: Bool {
        content != .videos && model.captureOneMode == .newSession && openInC1.contains(name)
            && !CaptureOneBridge.sessions(in: baseDirectory(video: false))
                .contains { $0.deletingLastPathComponent().lastPathComponent == name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("新建项目").font(Theme.Font.headline)

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    formLabel("日期").gridColumnAlignment(.trailing)
                    Picker("日期", selection: Binding(get: { day }, set: { new in
                        if new == Self.other { showingCalendar = true } else { day = new }
                    })) {
                        ForEach(dayChoices, id: \.self) { k in
                            Text(k == ShootSession.dayKey(.now) ? String(localized: "\(AppModel.dayTitle(k))（今天）") : AppModel.dayTitle(k)).tag(k)
                        }
                        Divider()
                        Text("其他日期…").tag(Self.other)
                    }
                    .labelsHidden().fixedSize()
                    .popover(isPresented: $showingCalendar, arrowEdge: .bottom) {
                        MiniCalendar(selection: $day, marked: Set(model.days.map(\.id))) { showingCalendar = false }
                    }
                }
                GridRow {
                    formLabel("类型")
                    SegmentPicker(options: ImportContent.allCases.map { .init(title: $0.title, value: $0) },
                                  selection: Binding(get: { content }, set: { pickedContent = $0 }))
                        .fixedSize()
                        .disabled(exists)
                        .accessibilityLabel("项目类型")
                        .help(exists ? "已有同名项目，沿用其类型" : "导入到这个项目时只导入这一类素材")
                }
                GridRow {
                    formLabel("事件")
                    TextField("事件", text: $event, prompt: Text("例如：公园"))
                        .textFieldStyle(.roundedBorder).controlSize(.large).labelsHidden()
                        .focused($eventFocused)
                        .onSubmit { if !blocked { create() } }
                }
                if !model.recentContents.isEmpty {
                    GridRow {
                        formLabel("最近").foregroundStyle(.secondary)
                        recentEvents
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .gridCellUnsizedAxes(.horizontal)
                    }
                }
            }

            Divider()

            if blocked {
                Text("Capture One 中已打开同名会话，请更换事件名")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
            } else if exists {
                Text("已有同名项目，将选中该项目")
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text("保存位置").font(Theme.Font.body.weight(.medium))
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 12) {
                    if content != .videos {
                        GridRow {
                            formLabel("照片").gridColumnAlignment(.trailing)
                            destinationControl("照片", video: false)
                        }
                    }
                    if content != .photos {
                        GridRow {
                            formLabel("视频").gridColumnAlignment(.trailing)
                            destinationControl("视频", video: true)
                        }
                    }
                }
                if previewsCaptureDate {
                    Text("日期目录按所选日期预览，导入时使用素材的拍摄日期。")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 6) {
                Spacer()
                Button("取消") { model.newSessionPrompt = nil }
                    .buttonStyle(.bordered).controlSize(.large)
                    .keyboardShortcut(.cancelAction)
                Button(prompt.importAfter ? "新建并导入" : "新建") { create() }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blocked)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            day = ShootSession.dayKey(model.defaultSessionDay)
            // 按选中的素材推测；没选时沿用最近一个项目的类型。
            pickedContent = (prompt.importAfter ? ImportContent.guess(model.selectedFiles().map(\.kind)) : nil)
                ?? model.sessions.max { $0.created < $1.created }?.contentType ?? .all
            if model.captureOneMode == .newSession { openInC1 = CaptureOneBridge.openDocumentNames() }
            eventFocused = true
        }
    }

    /// 使用与实际导入相同的目录规则；尚未分配的卷号保留为占位符。
    private func destination(video: Bool) -> URL {
        if !video, model.captureOneMode == .newSession {
            return baseDirectory(video: false).appending(path: name, directoryHint: .isDirectory)
                .appending(path: "Capture", directoryHint: .isDirectory)
        }
        let item = CameraContentItem(id: 0, storageID: 0, filename: video ? "preview.MP4" : "preview.JPG",
                                     format: 0, size: 0, captureDate: ShootSession.date(day),
                                     captureDateRaw: day, width: 0, height: 0)
        return model.importOrganization.folder(for: item,
            root: baseDirectory(video: video),
            sessionName: name, event: cleanEvent, roll: video ? String(localized: "〈卷号〉") : nil)
    }

    private func formLabel(_ title: LocalizedStringKey) -> some View {
        Text(title).font(Theme.Font.body).frame(width: 32, alignment: .trailing)
    }

    private var recentEvents: some View {
        ViewThatFits(in: .horizontal) {
            recentButtons(visible: 2)
            recentButtons(visible: 1)
            Menu("选择最近事件") {
                ForEach(model.recentContents, id: \.self) { recent in
                    Button(recent) { event = recent }
                }
            }
            .fixedSize()
        }
        .controlSize(.small)
    }

    private func recentButtons(visible count: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(model.recentContents.prefix(count), id: \.self) { recent in
                Button(recent) { event = recent }
                    .buttonStyle(.bordered).fixedSize()
            }
            if model.recentContents.count > count {
                Menu("更多") {
                    ForEach(Array(model.recentContents.dropFirst(count)), id: \.self) { recent in
                        Button(recent) { event = recent }
                    }
                }
                .fixedSize()
                .accessibilityLabel("更多最近事件")
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func destinationControl(_ title: String, video: Bool) -> some View {
        let path = destination(video: video).path(percentEncoded: false)
        let display = (path as NSString).abbreviatingWithTildeInPath
        return Button { changeDestination(video: video) } label: {
            HStack(spacing: 10) {
                Text(display).lineLimit(1).truncationMode(.middle)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered).controlSize(.large)
        .font(Theme.Font.body)
        .help(path)
        .accessibilityLabel(video ? String(localized: "更改视频保存位置") : String(localized: "更改照片保存位置"))
        .accessibilityValue(path)
    }

    private func baseDirectory(video: Bool) -> URL {
        if video { return videoRoot ?? model.videoDestination }
        return photoRoot ?? (model.captureOneMode == .newSession ? model.sessionsFolder : model.destination)
    }

    private func changeDestination(video: Bool) {
        guard let folder = FolderPicker.choose(start: baseDirectory(video: video)) else { return }
        if video { videoRoot = folder } else { photoRoot = folder }
    }

    private var previewsCaptureDate: Bool {
        let layouts: [(Bool, ImportFolderLayout, String)] = [
            (content != .videos && model.captureOneMode != .newSession,
             model.photoFolderLayout, NameTemplate.current(.folder)),
            (content != .photos, model.videoFolderLayout, NameTemplate.current(.video))
        ]
        return layouts.contains { enabled, layout, template in
            enabled && (layout == .date || (layout == .custom &&
                ["{YYYY}", "{MM}", "{DD}", "{M}", "{D}"].contains(where: template.contains)))
        }
    }

    private func create() {
        guard !blocked else { return }
        if content != .videos, let photoRoot {
            if model.captureOneMode == .newSession { model.sessionsFolder = photoRoot }
            else { model.destination = photoRoot }
        }
        if content != .photos, let videoRoot { model.videoDestination = videoRoot }
        model.createSession(day: day, event: cleanEvent, content: content)
        model.newSessionPrompt = nil
        if prompt.importAfter, !model.grid.selected.isEmpty {
            Task { @MainActor in
                await Task.yield()
                model.beginImport()
            }
        }
    }
}

/// 选日期的小日历（「其他日期…」）：一个月一页，选中的是蓝色圆点，今天是蓝色数字，卡上有拍摄的日子下面有小点。
/// 不用系统的日历控件（样式太旧）。
struct MiniCalendar: View {
    /// yyyyMMdd
    @Binding var selection: String
    /// 卡上的拍摄日（yyyyMMdd），下面画一个小点。
    var marked: Set<String> = []
    var onPick: () -> Void = {}
    @State private var month = Date.now

    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.locale = .app
        c.firstWeekday = 1
        return c
    }

    private var title: String {
        let f = DateFormatter(); f.locale = .app; f.setLocalizedDateFormatFromTemplate("yMMMM")
        return f.string(from: month)
    }

    /// 这个月的格子：前面空几格，然后 1…月底。
    private var cells: [Date?] {
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let range = cal.range(of: .day, in: .month, for: first) else { return [] }
        let lead = (cal.component(.weekday, from: first) - cal.firstWeekday + 7) % 7
        return Array(repeating: nil, count: lead) + range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text(title).font(Theme.Font.headline)
                Spacer()
                stepButton("chevron.left", by: -1).help("上个月")
                Button("今天") {
                    withAnimation(.snappy(duration: 0.2)) { month = .now }
                }
                .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                stepButton("chevron.right", by: 1).help("下个月")
            }
            let columns = Array(repeating: GridItem(.fixed(32), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(Array([String(localized: "日"), String(localized: "一"), String(localized: "二"), String(localized: "三"),
                               String(localized: "四"), String(localized: "五"), String(localized: "六")].enumerated()), id: \.offset) {
                    Text($0.element).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(height: 20)
                }
                ForEach(Array(cells.enumerated()), id: \.offset) { _, d in
                    if let d { dayCell(d) } else { Color.clear.frame(height: 32) }
                }
            }
        }
        .padding(14)
        .frame(width: 7 * 32 + 6 * 2 + 28)
        .onAppear { if let d = ShootSession.date(selection) { month = d } }
    }

    private func stepButton(_ symbol: String, by n: Int) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { month = cal.date(byAdding: .month, value: n, to: month) ?? month }
        } label: {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func dayCell(_ d: Date) -> some View {
        let key = ShootSession.dayKey(d)
        let on = key == selection
        let today = cal.isDateInToday(d)
        return Button {
            selection = key
            onPick()
        } label: {
            ZStack {
                Circle().fill(on ? Theme.accent : .clear)
                Text("\(cal.component(.day, from: d))")
                    .font(.system(size: 13, weight: on || today ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(on ? Color.white : today ? Theme.accent : Color.primary)
                if marked.contains(key) {
                    Circle().fill(on ? Color.white : Theme.accent).frame(width: 4, height: 4).offset(y: 10)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppModel.dayTitle(key))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
