import Foundation

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

    var urls: [URL] { files.map { URL(filePath: $0) } }

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "SonyImport", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "sessions.json")
    }

    static func load() -> [ShootSession] {
        (try? JSONDecoder().decode([ShootSession].self, from: Data(contentsOf: fileURL))) ?? []
    }

    static func save(_ list: [ShootSession]) {
        if let d = try? JSONEncoder().encode(list) { try? d.write(to: fileURL, options: .atomic) }
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

    /// 侧栏里的顺序：拍摄日期新的在前，同一天后建的在前。
    var sortedSessions: [ShootSession] {
        sessions.sorted { ($0.day, $0.created) > ($1.day, $1.created) }
    }

    /// 新建会话并设为当前会话。同名的已经有了就直接选中它。
    @discardableResult
    func createSession(day: String, event: String?) -> ShootSession {
        let name = ShootSession.name(day: day, event: event)
        rememberEvent(event)
        if let s = sessions.first(where: { $0.name == name }) {
            currentSessionID = s.id
            return s
        }
        let s = ShootSession(day: day, event: event, name: name)
        sessions.append(s)
        ShootSession.save(sessions)
        currentSessionID = s.id
        log.add("新建会话「\(name)」")
        return s
    }

    /// 从列表里移除（不删文件）。
    func removeSession(_ id: UUID) {
        sessions.removeAll { $0.id == id }
        ShootSession.save(sessions)
        if currentSessionID == id { currentSessionID = nil }
        if browsingSession == id { browsingSession = nil }
    }

    func recordSessionFiles(_ urls: [URL], in id: UUID) {
        guard !urls.isEmpty, let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var seen = Set(sessions[i].files)
        for u in urls where seen.insert(u.path).inserted { sessions[i].files.append(u.path) }
        ShootSession.save(sessions)
    }

    /// C1 会话文件夹里已有的 C1 会话（新的在前）。
    var existingC1Sessions: [URL] { CaptureOneBridge.sessions(in: sessionsFolder) }

    /// 选中的内容导入当前会话。下游沿用会话名：C1 会话（磁盘上已有就打开）、LrC 收藏夹、下载文件夹、视频文件夹。
    func importToCurrentSession() {
        guard let s = currentSession else { return }
        var choice: SessionChoice?
        switch captureOneMode {
        case .newSession:
            let file = existingC1Sessions.first { $0.deletingLastPathComponent().lastPathComponent == s.name }
            choice = file.map { .existing($0) } ?? .new(s.name)
        case .lightroom:
            choice = .new(s.name)
        default:
            choice = nil
        }
        startImport(jobs: [ImportJob(key: "all", files: Array(selectedFiles().reversed()), session: choice,
                                     event: s.event, folder: s.name, appSession: s.id)],
                    grouping: .single)
    }

    /// 新建会话时默认的日期：侧栏里选中的那天，没有就取所选文件里最早的一天，再没有就是今天。
    var defaultSessionDay: Date {
        let picked = days.first { d in shownDays.contains(d.id) || d.scenes.contains { shownDays.contains($0.id) } }
        let key = picked?.id ?? selectedFiles().map(Self.dayKey).filter { $0 != "unknown" }.min()
        return key.flatMap(ShootSession.date) ?? .now
    }
}
