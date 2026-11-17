import AppKit
import Dispatch
import Foundation
import MiniDiTCore
import SonyRemoteKit


// 导入前：检查备份盘和空间，按日期 / 场次分组。

extension AppModel {
    func refreshCaptureOne() {
        captureOneDocument = CaptureOneBridge.currentDocument()
    }

    /// 普通导入必须有用户选择的项目；先确定项目，再检查备份、空间和后期软件。
    /// 界面上点按钮时用默认参数；提醒里点「继续」时跳过已经确认过的检查。
    func beginImport(checkBackup: Bool = true, checkSpace: Bool = true) {
        guard importJournal.repairTask == nil, progress == nil, phase == .ready, !isRefreshingSources, !grid.selected.isEmpty else { return }
        guard currentSession != nil else {
            newSessionPrompt = .init(importAfter: true)
            return
        }
        if checkBackup {
            noBackupThisTime = false
            if backupEnabled, !backupAvailable {
                backupMissingPrompt = true
                return
            }
        }
        if checkSpace, let p = spaceShortage() {
            log.add("空间不够：\(p.folder.path) 剩 \(p.available) 字节，需要 \(p.needed)")
            spaceProblem = p
            return
        }
        let hasPhotos = selectedFiles().contains { $0.kind != .video }
        if hasPhotos, captureOneMode == .lightroom {
            let st = LightroomBridge.status()
            guard st.canImport else { lightroomPrompt = st; return }
        }
        if hasPhotos, captureOneMode == .newSession { refreshCaptureOne() }
        importToCurrentSession()
    }

    /// Aggregate storage requirements per mounted volume, including every required target.
    func spaceShortage() -> SpaceProblem? {
        let files = selectedFiles(), history = ImportHistory.shared
        let missing = files.filter { history.localFile($0, camera: camera(of: $0.id)) == nil }
        let photoNeed = missing.filter { $0.kind != .video }.reduce(UInt64(0)) { $0 + $1.sizeEstimate }
        let videoNeed = missing.filter { $0.kind == .video }.reduce(UInt64(0)) { $0 + $1.sizeEstimate }
        let primary = captureOneMode == .newSession ? sessionsFolder : destination
        var used: [String: UInt64] = [:]
        var requests: [(URL, UInt64, Bool)] = [(primary, photoNeed, false), (videoDestination, videoNeed, false)]
        if backupEnabled, !noBackupThisTime {
            for target in enabledBackupTargets where target.required && target.availability == .available {
                let need = files.filter { item in
                    !history.backupFiles(item, camera: camera(of: item.id)).contains { $0.path.hasPrefix(target.path + "/") }
                }.reduce(UInt64(0)) { $0 + $1.sizeEstimate }
                requests.append((target.root, need, true))
            }
        }
        for (folder, need, backup) in requests where need > 0 {
            let key = Self.volume(of: folder)?.path ?? folder.path
            let combined = (used[key] ?? 0) + need
            if let free = Self.freeSpace(at: folder), free < combined + Self.spaceMargin(combined) {
                return SpaceProblem(isBackup: backup, folder: folder, needed: combined, available: free)
            }
            used[key] = combined
        }
        return nil
    }

    /// 文件夹所在的磁盘（还没建的文件夹看它最近的上级）。
    static func volume(of folder: URL) -> URL? {
        var u = folder
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        return (try? u.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    /// 多留一点余量：2%，至少 50 MB。
    private static func spaceMargin(_ need: UInt64) -> UInt64 { max(need / 50, 50_000_000) }

    /// 文件夹所在磁盘的剩余空间（文件夹还没建时看它最近的上级）。
    static func freeSpace(at folder: URL) -> UInt64? {
        var u = folder
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 { u = u.deletingLastPathComponent() }
        guard let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        else { return nil }
        if let i = v.volumeAvailableCapacityForImportantUsage, i > 0 { return UInt64(i) }
        return v.volumeAvailableCapacity.map { UInt64($0) }
    }

    /// 选中的照片按会话分组（旧的在前）。只有一天 / 一场时，各种分法都只有一组。
    func importGroups(_ grouping: SessionGrouping) -> [ImportGroup] {
        func files(_ ids: [UInt32]) -> [CameraContentItem] {
            Array(allShots.filter { ids.contains($0.id) && grid.contains($0.id) }.flatMap(importFiles).compactMap { items[$0] }.reversed())
        }
        let selectedDays = days.filter { $0.shots.contains(where: grid.contains) }.reversed()
        switch grouping {
        case .single:
            let all = Array(selectedFiles().reversed())
            guard !all.isEmpty else { return [] }
            let day = all.map(Self.dayKey).filter { $0 != "unknown" }.min() ?? "unknown"
            let title = selectedDays.count == 1 ? selectedDays.first!.title : String(localized: "\(selectedDays.count) 天")
            return [ImportGroup(id: "all", day: day, scene: nil, title: title, shotCount: grid.selected.count, files: all)]
        case .perDay:
            return selectedDays.map { d in
                ImportGroup(id: d.id, day: d.id, scene: nil, title: d.title,
                            shotCount: d.shots.filter(grid.contains).count, files: files(d.shots))
            }
        case .perScene:
            return selectedDays.flatMap { d in
                d.scenes.reversed().filter { $0.shots.contains(where: grid.contains) }.map { sc in
                    ImportGroup(id: d.scenes.count > 1 ? sc.id : d.id, day: d.id, scene: d.scenes.count > 1 ? sc.number : nil,
                                title: d.scenes.count > 1 ? "\(d.title) · \(Self.sceneTitle(sc))" : d.title,
                                shotCount: sc.shots.filter(grid.contains).count, files: files(sc.shots))
                }
            }
        }
    }

    /// 分组的会话名：按会话命名模板。
    static func sessionName(for group: ImportGroup, event: String?) -> String {
        NameTemplate.render(.session, day: group.day, event: event, scene: group.scene)
    }
}
