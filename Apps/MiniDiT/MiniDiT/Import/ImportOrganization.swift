import Foundation
import MiniDiTCore
import SonyRemoteKit

/// 项目类型：新建项目时选，导入到这个项目时只导这一类素材。
enum ImportContent: String, CaseIterable, Identifiable, Codable {
    case photos, videos, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "照片和视频"
        case .photos: "照片"
        case .videos: "视频"
        }
    }
    /// 旧版本的全局「导入内容」设置。旧项目没有记类型，沿用当时的设置，升级后导入范围不变。
    static let legacy: ImportContent = {
        let d = UserDefaults.standard
        return ImportContent(rawValue: d.string(forKey: "importContent") ?? "")
            ?? ((d.object(forKey: "showVideo") as? Bool) == false ? .photos : .all)
    }()
    /// 按选中的素材推测：只有照片或只有视频时就是那一类。
    static func guess(_ kinds: some Sequence<CameraContentItem.Kind>) -> ImportContent? {
        let set = Set(kinds.filter { $0 != .other }.map { $0 == .video })
        return set.count == 1 ? (set.first! ? .videos : .photos) : set.isEmpty ? nil : .all
    }
    func accepts(_ kind: CameraContentItem.Kind) -> Bool {
        guard kind != .other else { return false }
        return self == .all || (kind == .video ? self == .videos : self == .photos)
    }
}

enum ImportFolderLayout: String, CaseIterable, Identifiable {
    case session, date, flat, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .session: "按项目名称建立文件夹"
        case .date: "按拍摄日期建立文件夹"
        case .flat: "直接存入所选位置"
        case .custom: "自定义文件夹规则"
        }
    }
}

/// 一批导入使用同一份路径规则，界面预览和实际拷贝共用。
@MainActor
struct ImportOrganization {
    var photos: ImportFolderLayout
    var videos: ImportFolderLayout
    var splitVideoByRoll: Bool
    var photoTemplate: String
    var videoTemplate: String
    var sessionTemplate: String
    var backupTemplate: String = NameTemplate.Kind.backup.defaultValue
    var mirrorBackup: Bool

    func folder(for item: CameraContentItem, root: URL, sessionName: String?, event: String?,
                scene: Int? = nil, roll: String? = nil) -> URL {
        let video = item.kind == .video
        let layout = video ? videos : photos
        let template = video ? videoTemplate : photoTemplate
        let day = AppModel.dayKey(item)
        let relative: String
        switch layout {
        case .session:
            relative = sessionName ?? NameTemplate.render(sessionTemplate, allowsFolders: false,
                                                          day: day, event: event, scene: scene)
        case .date:
            relative = NameTemplate.render("{YYYY}-{MM}-{DD}", allowsFolders: false,
                                           day: day, event: nil, scene: nil)
        case .flat:
            relative = ""
        case .custom:
            relative = NameTemplate.render(template, allowsFolders: true, day: day,
                                           event: event, scene: scene, roll: roll)
        }
        var result = root
        // 文件夹规则不能通过 "." / ".." 跳出用户选择的根目录。
        for part in relative.split(separator: "/") where part != "." && part != ".." {
            result.append(path: String(part), directoryHint: .isDirectory)
        }
        if video, splitVideoByRoll, !(layout == .custom && template.contains("{卷号}")), let roll {
            result.append(path: NameTemplate.sanitize(roll), directoryHint: .isDirectory)
        }
        return result
    }

    static func mirroredBackup(root: URL, primaryFolder: URL, primaryRoot: URL, video: Bool) -> URL {
        let base = primaryRoot.standardizedFileURL.pathComponents
        let folder = primaryFolder.standardizedFileURL.pathComponents
        var result = root.appending(path: video ? "视频" : "照片", directoryHint: .isDirectory)
        guard folder.starts(with: base) else { return result }
        for part in folder.dropFirst(base.count) { result.append(path: part, directoryHint: .isDirectory) }
        return result
    }
}

/// 中断后继续同一份导入计划，不受随后更改偏好的影响。
@MainActor
struct ImportPlan {
    var organization: ImportOrganization
    var content: ImportContent
    var photoRoot: URL
    var videoRoot: URL
    var captureRoot: URL
    var backupRoot: URL?
    var captureOneMode: CaptureOneMode
    var backupRequested = false
    var configuredBackupRoot: URL?
    var backupTargets: [BackupDestination] = []
    var runBackups = true
    var sendToFCP = false
    var sendToResolve = false
    var sendToPremiere = false
    var sendToJianying = false
    var fcpLogProcessing = true
    var resolveColorSpace = true
    var fcpProjectAs: FCPXMLWriter.ProjectMapping = .library
    var fcpEventLibrary: URL = FCPXMLWriter.defaultEventLibrary
}

extension AppModel {
    var importPlan: ImportPlan {
        .init(organization: importOrganization, content: importContent, photoRoot: destination,
              videoRoot: videoDestination, captureRoot: sessionsFolder,
              backupRoot: backupEnabled && backupAvailable && !noBackupThisTime ? backupFolder : nil,
              captureOneMode: captureOneMode, backupRequested: backupEnabled, configuredBackupRoot: enabledBackupTargets.first?.root,
              backupTargets: backupEnabled ? enabledBackupTargets : [], runBackups: !noBackupThisTime,
              sendToFCP: sendToFCP, sendToResolve: sendToResolve, sendToPremiere: sendToPremiere, sendToJianying: sendToJianying, fcpLogProcessing: fcpLogProcessing, resolveColorSpace: resolveColorSpace,
              fcpProjectAs: fcpProjectAs, fcpEventLibrary: fcpEventLibrary)
    }

    var importOrganization: ImportOrganization {
        .init(photos: photoFolderLayout, videos: videoFolderLayout, splitVideoByRoll: splitVideoByRoll,
              photoTemplate: NameTemplate.current(.folder), videoTemplate: NameTemplate.current(.video),
              sessionTemplate: NameTemplate.current(.session), backupTemplate: NameTemplate.current(.backup), mirrorBackup: backupFollowsOrganization)
    }

    func plannedFolder(for item: CameraContentItem, roll: String? = nil) -> URL {
        let session = currentSession
        let root = item.kind == .video ? videoDestination : destination
        let dir: URL
        if item.kind != .video, captureOneMode == .newSession {
            dir = sessionsFolder.appending(path: session?.name ?? "〈项目名称〉", directoryHint: .isDirectory)
                .appending(path: "Capture", directoryHint: .isDirectory)
        } else {
            dir = importOrganization.folder(for: item, root: root, sessionName: session?.name ?? "〈项目名称〉",
                                            event: session?.event, roll: roll)
        }
        let folders = sourceFolders()
        guard let source = sourceFolder(for: item, in: folders) else { return dir }
        return dir.appending(path: source, directoryHint: .isDirectory)
    }
}
