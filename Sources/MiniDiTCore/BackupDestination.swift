import Foundation
import SonyRemoteKit

/// A configured target; importing freezes a copy of this identity into its batch.
public struct BackupDestination: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var path: String
    public var volumeID: String?
    public var enabled: Bool
    public var required: Bool
    public init(id: UUID = UUID(), name: String, root: URL, enabled: Bool = true, required: Bool = true, volumeID: String? = nil) {
        self.id = id; self.name = name; self.path = root.standardizedFileURL.resolvingSymlinksInPath().path
        self.enabled = enabled; self.required = required
        self.volumeID = volumeID ?? BackupRepair.volumeID(at: root)
    }
    public var root: URL { URL(filePath: path) }
    public enum Availability: String, Sendable { case available, unavailable, wrongVolume, readOnly }
    public var availability: Availability {
        let fm = FileManager.default
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return .unavailable }
        if path.hasPrefix("/Volumes/") {
            guard let volume = try? root.resourceValues(forKeys: [.volumeURLKey]).volume,
                  volume.resolvingSymlinksInPath().path.hasPrefix("/Volumes/") else { return .unavailable }
        }
        if let volumeID, BackupRepair.volumeID(at: root) != volumeID { return .wrongVolume }
        return fm.isWritableFile(atPath: path) ? .available : .readOnly
    }
    public static func overlaps(_ first: URL, _ second: URL) -> Bool {
        let a = first.standardizedFileURL.resolvingSymlinksInPath().path
        let b = second.standardizedFileURL.resolvingSymlinksInPath().path
        return a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
    }
}

extension ImportedAssetRecord {
    public func hasBackup(at target: BackupDestination) -> Bool {
        copies.contains { copy in
            copy.role == .backup && copy.verifiedAt != nil && copy.path.hasPrefix(target.path + "/")
                && (copy.targetID == target.id || copy.targetID == nil)
        }
    }
    public func error(for target: BackupDestination) -> String? {
        if let targetErrors { return targetErrors[target.id.uuidString] }
        return backupError
    }
}

extension ImportBatchRecord {
    /// Existing local records keep their original target identity and verification facts.
    public var targets: [BackupDestination] {
        if let backupTargets { return backupTargets }
        guard let backupRoot else { return [] }
        return [.init(id: id, name: String(localized: "备份", bundle: .miniDiT), root: URL(filePath: backupRoot), volumeID: backupVolumeID)]
    }
    public func pendingCount(for target: BackupDestination) -> Int {
        files.flatMap(\.assets).filter { !$0.hasBackup(at: target) || $0.error(for: target) != nil }.count
    }
    public func verifiedCount(for target: BackupDestination) -> Int {
        files.flatMap(\.assets).filter { $0.hasBackup(at: target) && $0.error(for: target) == nil }.count
    }
    public var requiredBackupsComplete: Bool {
        guard backupRequested else { return true }
        guard !targets.isEmpty, files.allSatisfy({ $0.state == .saved && !$0.assets.isEmpty }) else { return false }
        return targets.filter(\.required).allSatisfy { pendingCount(for: $0) == 0 }
    }
}
