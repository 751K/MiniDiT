import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Persistent facts about an import. Accessibility never implies a fresh content check.
public struct ImportBatchRecord: Codable, Identifiable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case running, completed, interrupted, cancelled, legacy }
    public var id: UUID
    public var startedAt: Date
    public var finishedAt: Date?
    public var state: State
    public var backupRequested: Bool
    public var backupRoot: String?
    public var backupVolumeID: String?
    public var backupTargets: [BackupDestination]?
    public var backupReportErrors: [String: String]?
    public var workingRoots: [String]?
    public var files: [ImportedFileRecord]
    public var delivery: [String: String] = [:]
    public var videoDeliveries: [VideoDelivery]?
    public var reports: [String] = []
    public init(id: UUID = UUID(), files: [ImportedFileRecord], backupRequested: Bool, backupRoot: String?, state: State = .running) {
        self.id = id; self.startedAt = Date(); self.state = state
        self.files = files; self.backupRequested = backupRequested; self.backupRoot = backupRoot
    }
    public var savedCount: Int { files.filter { $0.state == .saved }.count }
    public var pendingBackupCount: Int {
        guard backupRequested else { return 0 }
        if targets.isEmpty { return files.flatMap(\.assets).count }
        return targets.reduce(0) { $0 + pendingCount(for: $1) }
    }

}

public struct ImportedFileRecord: Codable, Identifiable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, saved, failed }
    public var id: String
    public var projectID: UUID?
    public var filename: String
    public var source: String
    public var sourceAddress: String?
    public var sourceIdentity: ImportSourceIdentity?
    /// First successful checkpoint in this import, unaffected by later backup or verification.
    public var importedAt: Date?
    public var mediaKind: String?
    public var capturedAt: Date?
    public var captureDateRaw: String?
    public var expectedBytes: UInt64?
    public var roll: String?
    public var startTimecode: String?
    public var endTimecode: String?
    public var timecodeRate: String?
    public var resolution: String?
    public var frameRate: String?
    public var codec: String?
    public var durationSeconds: Double?

    public var state: State = .pending
    public var message: String?
    public var proxyOnly: Bool = false
    public var assets: [ImportedAssetRecord] = []
    public init(id: String, projectID: UUID?, filename: String, source: String) {
        self.id = id; self.projectID = projectID; self.filename = filename; self.source = source
    }
}

public struct ImportedAssetRecord: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case original, proxy, metadata }
    public var id: UUID
    public var kind: Kind
    public var size: UInt64
    public var xxh64: String?
    public var backupError: String?
    public var targetErrors: [String: String]?
    public var backupRelativePath: String
    public var copies: [ImportedCopyRecord]
    public init(id: UUID = UUID(), kind: Kind, size: UInt64, xxh64: String?, backupRelativePath: String, copies: [ImportedCopyRecord]) {
        self.id = id; self.kind = kind; self.size = size; self.xxh64 = xxh64
        self.backupRelativePath = backupRelativePath; self.copies = copies
    }
}

public struct ImportedCopyRecord: Codable, Identifiable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case working, backup }
    public enum Evidence: String, Codable, Sendable { case sourceComparison, localReadback, legacy }
    public var id: UUID
    public var role: Role
    public var path: String
    public var verifiedAt: Date?
    public var targetID: UUID?
    public var evidence: Evidence
    public init(role: Role, path: String, verifiedAt: Date? = nil, evidence: Evidence, targetID: UUID? = nil) {
        self.id = UUID(); self.role = role; self.path = path; self.verifiedAt = verifiedAt; self.evidence = evidence; self.targetID = targetID
    }
}

/// An actor keeps disk reads and copying off the UI thread. A stored hash is required;
/// neither matching size nor a newly calculated hash can establish an old baseline.
public actor BackupRepair {
    public init() {}
    public enum Failure: LocalizedError {
        case noBaseline, noTrustedCopy, invalidPath, targetUnavailable, wrongVolume, insufficientSpace
        public var errorDescription: String? {
            switch self {
            case .noBaseline: "缺少原始校验记录，无法确认用于补备份的文件。"
            case .noTrustedCopy: "现有副本缺失、无法读取或内容已变化；未用于补备份。"
            case .invalidPath: "备份路径无效或与原文件位置重叠。"
            case .targetUnavailable: "备份位置不可用，请连接磁盘并检查写入权限。"
            case .wrongVolume: "此位置连接的磁盘与原备份目标不同，请重新选择备份位置。"
            case .insufficientSpace: "备份位置的可用空间不足。"
            }
        }
    }

    public nonisolated static func volumeID(at root: URL) -> String? {
        (try? root.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    }

    public func repair(_ asset: ImportedAssetRecord, to root: URL, expectedVolume: String?, targetID: UUID? = nil,
                       progress: @Sendable (UInt64) -> Void = { _ in }) throws -> ImportedAssetRecord {
        try Task.checkCancellation()
        let fm = FileManager.default
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue,
              fm.isWritableFile(atPath: root.path) else { throw Failure.targetUnavailable }
        // An unmounted /Volumes entry can leave an ordinary writable directory
        // on the startup disk. It must not silently stand in for the external disk.
        if root.resolvingSymlinksInPath().path.hasPrefix("/Volumes/") {
            let volume = try root.resourceValues(forKeys: [.volumeURLKey]).volume?.resolvingSymlinksInPath()
            guard volume?.path.hasPrefix("/Volumes/") == true else { throw Failure.targetUnavailable }
        }
        if let expectedVolume, Self.volumeID(at: root) != expectedVolume { throw Failure.wrongVolume }
        guard let baseline = asset.xxh64, baseline.count == 16 else { throw Failure.noBaseline }
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let components = asset.backupRelativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              !asset.backupRelativePath.hasPrefix("/") else { throw Failure.invalidPath }
        var destination = root.appendingPathComponent(asset.backupRelativePath).standardizedFileURL
        guard Self.isConfined(destination, to: root) else { throw Failure.invalidPath }
        let originalPaths = asset.copies.filter { $0.role == .working }.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path }
        guard !originalPaths.contains(destination.resolvingSymlinksInPath().path) else { throw Failure.invalidPath }
        // Re-read the destination even when a previous successful check is recorded.
        var result = asset
        if let targetID { result.targetErrors?.removeValue(forKey: targetID.uuidString) }
        else { result.backupError = nil }
        if let copy = asset.copies.first(where: { $0.role == .backup && Self.isConfined(URL(fileURLWithPath: $0.path), to: root) }),
           (try? digest(URL(fileURLWithPath: copy.path), size: asset.size)) == baseline {
            if let index = result.copies.firstIndex(where: { $0.id == copy.id }) { result.copies[index].verifiedAt = Date(); result.copies[index].evidence = .localReadback; result.copies[index].targetID = targetID }
            progress(asset.size)
            return result
        }
        if (try? digest(destination, size: asset.size)) == baseline {
            result.copies.removeAll { $0.role == .backup && $0.path == destination.path }
            result.copies.append(.init(role: .backup, path: destination.path, verifiedAt: Date(), evidence: .localReadback, targetID: targetID))
            progress(asset.size)
            return result
        }
        var source: URL?
        for copy in asset.copies {
            try Task.checkCancellation()
            let candidate = URL(fileURLWithPath: copy.path)
            if (try? digest(candidate, size: asset.size)) == baseline { source = candidate; break }
        }
        guard let source else { throw Failure.noTrustedCopy }
        let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = capacity.volumeAvailableCapacityForImportantUsage, free < Int64(clamping: asset.size) { throw Failure.insufficientSpace }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Never overwrite a conflicting file, including one that has the same byte count.
        let requested = destination
        var suffix = 2
        while fm.fileExists(atPath: destination.path) {
            destination = requested.deletingPathExtension().appendingPathExtension("\(suffix)." + requested.pathExtension)
            suffix += 1
        }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".minidit-backup-\(asset.id.uuidString).part")
        // This asset ID is persisted before copying. A process exit may leave its
        // private staging file; a retry replaces only that known staging file.
        if fm.fileExists(atPath: temporary.path) {
            guard (try temporary.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw Failure.invalidPath }
            try fm.removeItem(at: temporary)
        }
        defer { try? fm.removeItem(at: temporary) }
        try Data().write(to: temporary, options: .withoutOverwriting)
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        #if canImport(Darwin)
        _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
        #endif
        let output = try FileHandle(forWritingTo: temporary)
        defer { try? output.close() }
        var hash = XXH64()
        var count: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let bytes = try input.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            bytes.withUnsafeBytes { hash.update($0) }
            count += UInt64(bytes.count)
            try output.write(contentsOf: bytes)
            progress(count)
        }
        try output.synchronize()
        guard count == asset.size, XXH64.hex(hash.digest()) == baseline,
              try digest(temporary, size: asset.size) == baseline else { throw Failure.noTrustedCopy }
        try Task.checkCancellation()
        try fm.moveItem(at: temporary, to: destination)
        result.copies.removeAll { $0.role == .backup && $0.path == destination.path }
        result.copies.append(.init(role: .backup, path: destination.path, verifiedAt: Date(), evidence: .localReadback, targetID: targetID))
        progress(asset.size)
        return result
    }

    private nonisolated static func isConfined(_ file: URL, to root: URL) -> Bool {
        let prefix = root.path + "/"
        let path = file.standardizedFileURL.path
        guard path.hasPrefix(prefix) else { return false }
        var current = root
        for part in path.dropFirst(prefix.count).split(separator: "/") {
            current.appendPathComponent(String(part))
            // resolvingSymlinksInPath alone does not reliably resolve an intermediate
            // link when the leaf file does not yet exist.
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil { return false }
        }
        return true
    }

    private func digest(_ file: URL, size: UInt64) throws -> String {
        guard let count = (try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? UInt64, count == size else { throw Failure.noTrustedCopy }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        #if canImport(Darwin)
        _ = fcntl(input.fileDescriptor, F_NOCACHE, 1)
        #endif
        var hash = XXH64()
        while true {
            try Task.checkCancellation()
            let bytes = try input.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if bytes.isEmpty { break }
            bytes.withUnsafeBytes { hash.update($0) }
        }
        return XXH64.hex(hash.digest())
    }
}
