import Foundation

enum ProjectMedia: String, CaseIterable, Identifiable {
    case photos, videos
    var id: String { rawValue }
    var title: String { self == .photos ? "照片" : "视频" }

    static func forPath(_ path: String) -> ProjectMedia {
        let ext = URL(filePath: path).pathExtension.lowercased()
        return ["mp4", "mov", "mxf", "m4v", "mts", "avi", "crm"].contains(ext) ? .videos : .photos
    }
}

/// 软件自己管理的会话：一次拍摄任务（日期 + 事件）。和 Capture One 的会话无关。
/// 导入时下游沿用它的名字：C1 新建同名会话，LrC 新建同名收藏夹，只下载就是同名文件夹。
/// 记下导入到电脑上的文件（第一份的路径），相机和存储卡不在时也能浏览。
struct ShootSession: Codable, Identifiable, Hashable {
    var id = UUID()
    /// yyyyMMdd
    var day: String
    var event: String?
    var name: String
    var created = Date()
    var files: [String] = []
    /// 项目类型；旧版本建的项目没有，按 `ImportContent.legacy`。
    var content: ImportContent?
    var contentType: ImportContent { content ?? .legacy }

    var urls: [URL] { files.map { URL(filePath: $0) } }
    var photoFileCount: Int { files.filter { ProjectMedia.forPath($0) == .photos }.count }
    var videoFileCount: Int { files.filter { ProjectMedia.forPath($0) == .videos }.count }
    var hasBothMedia: Bool { photoFileCount > 0 && videoFileCount > 0 }
    func fileCount(_ media: ProjectMedia) -> Int {
        files.filter { ProjectMedia.forPath($0) == media }.count
    }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SonyImport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "sessions.json")
    }

    static func load() -> [ShootSession] {
        (try? JSONDecoder().decode([ShootSession].self, from: Data(contentsOf: fileURL))) ?? []
    }

    static func save(_ list: [ShootSession], to url: URL? = nil) {
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: url ?? fileURL, options: .atomic) }
    }

    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func date(_ day: String) -> Date? {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: day)
    }

    /// 会话名：按「会话名称」模板（默认「{M}.{D}-{事件}」）。
    static func name(day: String, event: String?) -> String {
        NameTemplate.render(.session, day: day, event: event)
    }
}

extension AppModel {

    // MARK: 软件会话

    var currentSession: ShootSession? { sessions.first { $0.id == currentSessionID } }

    /// 选择导入目标时返回来源浏览，避免继续显示另一个项目的内容。
    func selectSession(_ id: UUID?) {
        currentSessionID = id
        browseSession(nil)
    }

    func browseSession(_ id: UUID?, media: ProjectMedia? = nil) {
        if let id { currentSessionID = id }
        browsingSession = id
        browsingSessionMedia = id == nil ? nil : media
    }

    /// 侧栏里的顺序：拍摄日期新的在前，同一天后建的在前。
    var sortedSessions: [ShootSession] {
        sessions.sorted { ($0.day, $0.created) > ($1.day, $1.created) }
    }

    /// 新建会话并设为当前会话。同名的已经有了就直接选中它。
    @discardableResult
    func createSession(day: String, event: String?, content: ImportContent = .all) -> ShootSession {
        let name = ShootSession.name(day: day, event: event)
        rememberEvent(event)
        if let s = sessions.first(where: { $0.name == name }) {
            selectSession(s.id)
            return s
        }
        let s = ShootSession(day: day, event: event, name: name, content: content)
        sessions.append(s)
        ShootSession.save(sessions, to: sessionRecordURL)
        selectSession(s.id)
        log.add("新建会话「\(name)」")
        return s
    }

    /// 改项目类型（已导入的文件不动，只影响之后导入哪些素材）。
    func setContent(_ content: ImportContent, of id: UUID) {
        guard let i = sessions.firstIndex(where: { $0.id == id }), sessions[i].contentType != content else { return }
        sessions[i].content = content
        ShootSession.save(sessions, to: sessionRecordURL)
        log.add("项目「\(sessions[i].name)」类型改为\(content.title)")
        if id == currentSessionID { contentChanged() }
    }

    /// 导入范围变了：重新整理网格，并保证这一类不会被格式开关全部藏起来。
    func contentChanged() {
        if importContent != .photos { showVideo = true }
        if importContent != .videos, !showRaw && !showPhotos { showRaw = true; showPhotos = true }
        rebuild()
    }

    /// 从列表里移除（不删文件）。
    func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        ShootSession.save(sessions, to: sessionRecordURL)
        if currentSessionID == id { selectSession(nil) }
        if browsingSession == id { browseSession(nil) }
    }

    func recordSessionFiles(_ urls: [URL], in id: UUID) {
        guard !urls.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set(sessions[i].files)
        for u in urls where seen.insert(u.path).inserted { sessions[i].files.append(u.path) }
        ShootSession.save(sessions, to: sessionRecordURL)
    }

    /// C1 会话文件夹里已有的 C1 会话（新的在前）。
    var existingC1Sessions: [URL] { CaptureOneBridge.sessions(in: sessionsFolder) }

    /// 选中的内容导入当前会话。下游沿用会话名：C1 会话（磁盘上已有就打开）、LrC 收藏夹、下载文件夹、视频文件夹。
    func importToCurrentSession() {
        guard let job = currentSessionJob() else {
            newSessionPrompt = .init(importAfter: true)
            return
        }
        startImport(jobs: [job], grouping: .single)
    }

    /// 把拖拽开始时选中的素材正常导入指定项目；目标项目由落点决定。
    func importDropped(shots ids: Set<UInt32>, into session: ShootSession) {
        guard progress == nil, phase == .ready, !isRefreshingSources else { return }
        let valid = ids.filter { shots[$0] != nil }
        guard !valid.isEmpty, sessions.contains(where: { $0.id == session.id }) else { return }
        log.add("拖拽导入 \(valid.count) 次拍摄到项目「\(session.name)」")
        selectSession(session.id)
        grid.replace(with: valid)
        beginImport()
    }

    /// 只准备导入计划，不启动 C1 / LrC；仅视频时不需要照片软件。
    func currentSessionJob() -> ImportJob? {
        guard let s = currentSession else { return nil }
        let files = Array(selectedFiles().reversed())
        var choice: SessionChoice?
        switch captureOneMode {
        case _ where !files.contains(where: { $0.kind != .video }):
            choice = nil
        case .newSession:
            let file = existingC1Sessions.first { $0.deletingLastPathComponent().lastPathComponent == s.name }
            choice = file.map { .existing($0) } ?? .new(s.name)
        case .lightroom:
            choice = .new(s.name)
        default:
            choice = nil
        }
        return ImportJob(key: "all", files: files, session: choice,
                         event: s.event, folder: s.name, appSession: s.id)
    }

    /// 新建会话时默认的日期：侧栏里选中的那天，没有就取所选文件里最早的一天，再没有就是今天。
    var defaultSessionDay: Date {
        let picked = days.first { d in shownDays.contains(d.id) || d.scenes.contains { shownDays.contains($0.id) } }
        let key = picked?.id ?? selectedFiles().map(Self.dayKey).filter { $0 != "unknown" }.min()
        return key.flatMap(ShootSession.date) ?? .now
    }
}
