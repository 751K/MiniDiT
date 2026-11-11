import AppKit
import Foundation
import SonyRemoteKit
@testable import MiniDiT

@main struct OrganizationChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        let marker = UUID().uuidString
        defaults.set(marker, forKey: "organizationCheckDomain")
        precondition(defaults.persistentDomain(forName: domain)?["organizationCheckDomain"] as? String == marker)
        for key in ["photoFolderLayout", "videoFolderLayout", "splitVideoByRoll", "importContent", "showVideo",
                    "template.video", "template.folder", "template.backup", "backupFollowsOrganization"] {
            defaults.removeObject(forKey: key)
        }

        // 升级保留原先“仅照片”的选择，以及仍在使用的自定义备份规则。
        defaults.set(false, forKey: "showVideo")
        defaults.set("客户-{YYYY}-{MM}-{DD}", forKey: "template.backup")
        let migrated = AppModel(startServices: false)
        precondition(migrated.importContent == .photos)
        precondition(!migrated.backupFollowsOrganization)
        defaults.removeObject(forKey: "template.backup")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "minidit-organization-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let card = root.appending(path: "card")
        let dcim = card.appending(path: "DCIM/100MSDCF")
        let clips = card.appending(path: "PRIVATE/M4ROOT/CLIP")
        try fm.createDirectory(at: dcim, withIntermediateDirectories: true)
        try fm.createDirectory(at: clips, withIntermediateDirectories: true)
        let photoBytes = Data("organization-photo-".utf8) + Data(repeating: 0x31, count: 2048)
        let videoBytes = Data("organization-video-".utf8) + Data(repeating: 0x42, count: 4096)
        try photoBytes.write(to: dcim.appending(path: "ORG001.ARW"))
        try videoBytes.write(to: clips.appending(path: "ORG001.MP4"))
        let library = LocalCardLibrary(root: card)
        let folder = try await library.folders()[0]
        let handles = try await library.handles(in: folder)
        var items: [CameraContentItem] = []
        for handle in handles { items.append(try await library.item(handle)) }
        let photo = try require(items.first { $0.kind == .raw })
        let video = try require(items.first { $0.kind == .video })
        let day = AppModel.dayKey(photo)
        let dated = NameTemplate.render("{YYYY}-{MM}-{DD}", allowsFolders: false, day: day, event: nil, scene: nil)
        var rules = ImportOrganization(photos: .session, videos: .date, splitVideoByRoll: true,
                                       photoTemplate: "{YYYY}/{事件}", videoTemplate: "{YYYY}/{卷号}",
                                       sessionTemplate: "{M}.{D}-{事件}", mirrorBackup: true)
        let photos = root.appending(path: "photos")
        let videos = root.appending(path: "videos")
        let backup = root.appending(path: "backup")
        precondition(rules.folder(for: photo, root: photos, sessionName: "采访", event: nil).path == photos.appending(path: "采访").path)
        precondition(rules.folder(for: video, root: videos, sessionName: "采访", event: nil, roll: "A001").path == videos.appending(path: dated + "/A001").path)
        rules.videos = .custom
        let customVideo = rules.folder(for: video, root: videos, sessionName: "采访", event: nil, roll: "A001")
        precondition(customVideo.lastPathComponent == "A001")
        precondition(customVideo.deletingLastPathComponent().lastPathComponent != "A001", "自定义规则含卷号时不能再嵌一层卷号")
        rules.photos = .flat
        precondition(rules.folder(for: photo, root: photos, sessionName: "采访", event: nil) == photos)
        rules.photos = .custom
        rules.photoTemplate = "../../{YYYY}/../{事件}"
        let confined = rules.folder(for: photo, root: photos, sessionName: nil, event: "采访")
        precondition(confined.standardizedFileURL.path.hasPrefix(photos.standardizedFileURL.path + "/"))
        rules.photos = .session
        let primary = rules.folder(for: photo, root: photos, sessionName: "采访", event: nil)
        let mirrored = ImportOrganization.mirroredBackup(root: backup, primaryFolder: primary,
                                                         primaryRoot: photos, video: false)
        precondition(mirrored.path == backup.appending(path: "照片/采访").path)
        let videoMirror = ImportOrganization.mirroredBackup(root: backup, primaryFolder: customVideo,
                                                           primaryRoot: videos, video: true)
        precondition(videoMirror.path.hasPrefix(backup.appending(path: "视频").path + "/"))

        // 从旧整理位置复用文件时应复制，既有会话中的文件必须保留。
        let oldFolder = FileImporter.folder(for: photo, root: photos)
        try fm.createDirectory(at: oldFolder, withIntermediateDirectories: true)
        let oldFile = oldFolder.appending(path: photo.filename)
        try photoBytes.write(to: oldFile)
        let importer = FileImporter(library: library, root: photos, camera: "organization-" + UUID().uuidString,
                                    backupRoot: backup, backupDirectory: mirrored, checkSource: true)
        let copied = try await importer.importItem(photo, into: primary, progress: { _ in }, stage: { _ in })
        precondition(copied.matchesSource)
        precondition(fm.fileExists(atPath: oldFile.path), "改变整理位置不能移走已有会话的原文件")
        let primaryBytes = try Data(contentsOf: copied.outcome.url)
        precondition(primaryBytes == photoBytes)
        guard case .done(let backedUp) = copied.backup else { fatalError("没有写入备份") }
        precondition(backedUp.deletingLastPathComponent() == mirrored)
        let backupBytes = try Data(contentsOf: backedUp)
        precondition(backupBytes == photoBytes)

        // 不分文件夹时，同名且同大小的其他照片也不能被误判成已导入。
        let flat = root.appending(path: "flat")
        try fm.createDirectory(at: flat, withIntermediateDirectories: true)
        let conflicting = flat.appending(path: photo.filename)
        let differentBytes = Data(repeating: 0x7f, count: photoBytes.count)
        try differentBytes.write(to: conflicting)
        let collision = try await importer.importItem(photo, into: flat, progress: { _ in }, stage: { _ in })
        precondition(collision.outcome.url.path != conflicting.path)
        let keptBytes = try Data(contentsOf: conflicting)
        let importedBytes = try Data(contentsOf: collision.outcome.url)
        precondition(keptBytes == differentBytes && importedBytes == photoBytes)

        let model = AppModel(startServices: false)
        model.onlyNew = false
        model.importContent = .all
        model.showVideo = true
        model.sourceKind = .card
        model.cardRoot = card
        model.connectedName = "整理偏好测试卡"
        model.library = library
        model.destination = photos
        model.videoDestination = videos
        model.sessionsFolder = root.appending(path: "c1-sessions")
        model.sessions = []
        model.photoFolderLayout = .date
        model.videoFolderLayout = .session
        await model.loadAll()
        let session = ShootSession(day: day, event: "采访", name: "采访")
        model.sessions = [session]
        model.currentSessionID = session.id
        for scope in ImportContent.allCases {
            model.importContent = scope
            model.selectAll(in: Set(model.days.map(\.id)))
            let selected = model.selectedFiles()
            precondition(!selected.isEmpty)
            precondition(selected.allSatisfy { scope.accepts($0.kind) })
            if scope == .all { precondition(Set(selected.map { $0.kind.rawValue }).count == 2) }
        }
        for target in [CaptureOneMode.newSession, .lightroom] {
            model.captureOneMode = target
            let job = try require(model.currentSessionJob())
            precondition(job.files.allSatisfy { $0.kind == .video })
            precondition(job.session == nil, "仅视频不能要求照片软件创建会话或收藏夹")
            precondition(job.appSession == session.id)
        }
        model.captureOneMode = .off
        precondition(model.plannedFolder(for: photo).path == photos.appending(path: dated).path)
        precondition(model.plannedFolder(for: video).path == videos.appending(path: session.name).path)
        let snapshot = model.importPlan
        model.videoFolderLayout = .flat
        model.videoDestination = root.appending(path: "changed-videos")
        model.importContent = .photos
        model.captureOneMode = .newSession
        precondition(snapshot.organization.videos == .session, "已开始导入的规则快照不能被设置改动影响")
        precondition(snapshot.videoRoot.path == videos.path)
        precondition(snapshot.content == .videos && snapshot.captureOneMode == .off)
        // 项目可跨日期追加；项目起始日期不应过滤掉本次素材。
        let crossDayProject = ShootSession(day: "20000101", event: "跨天拍摄", name: "跨天拍摄")
        model.sessions = [crossDayProject]
        model.currentSessionID = crossDayProject.id
        model.captureOneMode = .off
        model.importContent = .all
        model.onlyNew = false
        model.selectAll(in: Set(model.days.map(\.id)))
        let crossDayJob = try require(model.currentSessionJob())
        precondition(crossDayJob.appSession == crossDayProject.id && crossDayJob.files.count == 2)
        precondition(model.plannedFolder(for: photo).path == photos.appending(path: dated).path)
        model.mediaFilter.query = "does-not-exist"
        precondition(model.selectedFiles().isEmpty, "隐藏的选择不能继续参与导入")
        model.resetImportFilters()
        precondition(model.importContent == .all && model.pairPolicy == .both)
        model.selectAll(in: Set(model.days.map(\.id)))
        precondition(model.selectedFiles().count == 2)
        let beforeSelection = model.grid.selected
        model.rebuild()
        precondition(model.grid.selected == beforeSelection)
        var outcome = AppModel.ImportResult(files: 1, reused: 0, failed: 0, c1Failed: false,
                                           cancelled: false, backedUp: nil, deleted: nil)
        precondition(!outcome.needsAttention, "主动只存一份不应显示失败警告")
        outcome.failed = 1
        precondition(outcome.needsAttention)
        outcome.failed = 0
        outcome.cancelled = true
        precondition(outcome.needsAttention)
        outcome.cancelled = false
        outcome.backedUp = 1
        outcome.backupFailed = 1
        precondition(outcome.needsAttention, "备份失败必须显示异常")
        print("PASS: cross-day project; hidden selections removed; reset preserves content preference; explicit one-copy success and failure states")
        print("PASS: independent photo/video layouts; legacy preferences; photo/video-only selection; video-only downstream plan; mirrored backup verified against source; prior copy preserved; path preview and frozen layout")
    }

    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
}
