import AppKit
import Foundation
import MiniDiTCore
import Observation
@testable import MiniDiT

@MainActor private final class ObservationFlag { var changed = false }

@main struct PhysicalDiskChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let defaults = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        let previous = defaults.persistentDomain(forName: domain)
        defer { if let previous { defaults.setPersistentDomain(previous, forName: domain) } else { defaults.removePersistentDomain(forName: domain) } }
        defaults.removePersistentDomain(forName: domain)
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-disk-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let model = AppModel(startServices: false, journalURL: root.appending(path: "journal.sqlite"))
        model.captureOneMode = .off
        let photoProject = ShootSession(day: "20261109", name: "磁盘检查", content: .photos)
        model.sessions = [photoProject]; model.currentSessionID = photoProject.id
        let work = root.appending(path: "future-work"), backup = root.appending(path: "backup"), second = root.appending(path: "second")
        for path in [backup, second] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        model.destination = work
        model.backupTargets = [.init(name: "A", root: backup), .init(name: "B", root: second)]
        let completionObserved = ObservationFlag()
        withObservationTracking { _ = model.backupTargetNote(model.backupTargets[0]) } onChange: {
            Task { @MainActor in completionObserved.changed = true }
        }
        await model.refreshBackupDiskIdentities()
        await Task.yield()
        precondition(completionObserved.changed, "UI must observe completion even before the identity dictionary has been read")
        let key = work.standardizedFileURL.resolvingSymlinksInPath().path
        precondition(model.backupDiskIdentities[key]?.complete == true, "missing work directory should resolve its existing volume")
        precondition(model.backupTargetNote(model.backupTargets[0]) == "与导入位置位于同一块硬盘")
        let original = model.backupTargets[0]
        // Inject distinct volume/physical IDs to exercise UI decisions beyond this test machine's one volume.
        model.backupTargets[0].volumeID = nil; model.backupTargets[1].volumeID = nil
        model.backupDiskIdentityKey = model.backupDiskProbeKey
        model.backupDiskIdentities = [key: .init(devices: ["disk0"], complete: true),
            original.path: .init(devices: ["disk6"], complete: true),
            model.backupTargets[1].path: .init(devices: ["disk6"], complete: true)]
        // nil volume ID is allowed, but availability remains filesystem based.
        precondition(model.backupTargetNote(model.backupTargets[0]) == "与其他备份位置位于同一块硬盘")
        model.backupDiskIdentities[model.backupTargets[1].path] = .init(devices: ["disk9"], complete: true)
        precondition(model.backupTargetNote(model.backupTargets[0]) == nil, "separate hardware needs no warning")
        model.backupDiskIdentities[original.path] = .init()
        precondition(model.backupTargetNote(model.backupTargets[0]) == "无法确认是否与其他位置共用硬盘")
        model.backupTargets[1].enabled = false
        model.backupDiskIdentities[original.path] = .init(devices: ["disk6"], complete: true)
        // A disabled destination must not affect an active destination's independence.
        model.backupDiskIdentityKey = model.backupDiskProbeKey
        precondition(model.backupTargetNote(model.backupTargets[0]) == nil)
        model.volumesChanged(unmounted: nil)
        precondition(model.backupTargetNote(model.backupTargets[0]) == nil, "stale hardware state must not be reused after mount changes")
        await model.refreshBackupDiskIdentities()
        precondition(model.backupTargetNote(model.backupTargets[0]) == "与导入位置位于同一块硬盘")
        print("PASS: real mounted-volume probe; missing work directory; same hardware versus shared backup hardware; distinct hardware hides note; unknown topology; disabled targets excluded; mount invalidation and refresh")
        if CommandLine.arguments.contains("--live") {
            let paths = CommandLine.arguments.drop(while: { $0 != "--live" }).dropFirst().map { URL(filePath: $0) }
            let values = await Task.detached { PhysicalDiskProbe.identities(for: paths) }.value
            for path in paths {
                let identity = values[path.standardizedFileURL.resolvingSymlinksInPath().path] ?? .init()
                print("\(path.path): \(identity.devices.sorted().joined(separator: ",")); complete=\(identity.complete)")
            }
        }
    }
}
