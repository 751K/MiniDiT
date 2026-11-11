import Foundation
import Testing
import MiniDiTCore

@Suite struct ImportJournalTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("backup-journal-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func asset(_ url: URL, data: Data, path: String = "照片/项目/A.JPG") -> ImportedAssetRecord {
        var hash = XXH64(); data.withUnsafeBytes { hash.update($0) }
        return .init(kind: .original, size: UInt64(data.count), xxh64: XXH64.hex(hash.digest()), backupRelativePath: path,
                     copies: [.init(role: .working, path: url.path, verifiedAt: Date(), evidence: .sourceComparison)])
    }

    @Test func repairWithoutOriginalCardReusesMatchingDestinationAndPreservesConflicts() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("work/A.JPG")
        let backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: backup.appendingPathComponent("照片/项目"), withIntermediateDirectories: true)
        let data = Data([1,2,3,4]); try data.write(to: source)
        let conflicting = backup.appendingPathComponent("照片/项目/A.JPG")
        try Data([4,3,2,1]).write(to: conflicting)
        let worker = BackupRepair()
        let first = try await worker.repair(asset(source, data: data), to: backup, expectedVolume: nil)
        let destination = try #require(first.copies.last)
        #expect(destination.role == .backup)
        #expect(destination.path != conflicting.path)
        #expect(try Data(contentsOf: conflicting) == Data([4,3,2,1]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination.path)) == data)
        try FileManager.default.removeItem(at: source)
        let second = try await worker.repair(first, to: backup, expectedVolume: nil)
        #expect(second.copies.count == first.copies.count)
        #expect(try FileManager.default.contentsOfDirectory(atPath: conflicting.deletingLastPathComponent().path).count == 2)
    }

    @Test func refusesSameSizeChangedSourceAndMissingBaseline() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.JPG"), backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        let data = Data([1,2,3,4]); try data.write(to: source)
        let original = asset(source, data: data)
        try Data([4,3,2,1]).write(to: source)
        let worker = BackupRepair()
        await #expect(throws: (any Error).self) { try await worker.repair(original, to: backup, expectedVolume: nil) }
        var unknown = original; unknown.xxh64 = nil
        await #expect(throws: (any Error).self) { try await worker.repair(unknown, to: backup, expectedVolume: nil) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: backup.path).isEmpty)
    }

    @Test func usesAnotherVerifiedCopyWhenWorkingFileHasChanged() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.JPG"), prior = root.appendingPathComponent("prior.JPG")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = Data([1,2,3,4]); try data.write(to: source); try data.write(to: prior)
        var file = asset(source, data: data)
        file.copies.append(.init(role: .backup, path: prior.path, verifiedAt: Date(), evidence: .localReadback))
        try Data([4,3,2,1]).write(to: source)
        let result = try await BackupRepair().repair(file, to: target, expectedVolume: nil)
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(result.copies.last).path)) == data)
        #expect(try Data(contentsOf: source) == Data([4,3,2,1]))
    }

    @Test func offlineTargetWrongVolumeAndEscapingPathsCannotWrite() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.JPG"), target = root.appendingPathComponent("target")
        let data = Data([1,2]); try data.write(to: source)
        let worker = BackupRepair()
        let original = asset(source, data: data)
        await #expect(throws: (any Error).self) { try await worker.repair(original, to: target, expectedVolume: nil) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await worker.repair(original, to: target, expectedVolume: "another-volume") }
        for path in ["../escape.JPG", "/absolute.JPG", "a/../../escape.JPG", "a//b.JPG"] {
            let invalid = asset(source, data: data, path: path)
            await #expect(throws: (any Error).self) { try await worker.repair(invalid, to: target, expectedVolume: nil) }
        }
        try FileManager.default.createSymbolicLink(at: target.appendingPathComponent("link"), withDestinationURL: root)
        let symlink = asset(source, data: data, path: "link/escape.JPG")
        await #expect(throws: (any Error).self) { try await worker.repair(symlink, to: target, expectedVolume: nil) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.JPG").path))
    }

    @Test func corruptedBackupIsNotReusedOrOverwritten() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.JPG"), target = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = Data([1,2,3,4]); try data.write(to: source)
        let worker = BackupRepair()
        let first = try await worker.repair(asset(source, data: data), to: target, expectedVolume: nil)
        let oldPath = try #require(first.copies.last?.path)
        try Data([4,3,2,1]).write(to: URL(fileURLWithPath: oldPath))
        let second = try await worker.repair(first, to: target, expectedVolume: nil)
        #expect(second.copies.last?.path != oldPath)
        #expect(try Data(contentsOf: URL(fileURLWithPath: oldPath)) == Data([4,3,2,1]))
        #expect(try Data(contentsOf: URL(fileURLWithPath: #require(second.copies.last?.path))) == data)
    }

    @Test func retryRemovesOnlyItsPersistedStagingFile() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.JPG"), target = root.appendingPathComponent("backup")
        let folder = target.appendingPathComponent("照片/项目")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data([1,2,3,4]); try data.write(to: source)
        let file = asset(source, data: data)
        let staging = folder.appendingPathComponent(".minidit-backup-\(file.id.uuidString).part")
        let unrelated = folder.appendingPathComponent(".minidit-backup-unrelated.part")
        try Data([9]).write(to: staging); try Data([8]).write(to: unrelated)
        _ = try await BackupRepair().repair(file, to: target, expectedVolume: nil)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try Data(contentsOf: unrelated) == Data([8]))
    }

    @Test func cancellationDoesNotCreateOutput() async throws {
        let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.JPG"), target = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let data = Data([1,2,3,4]); try data.write(to: source)
        let file = asset(source, data: data)
        let task = Task { () throws -> ImportedAssetRecord in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await BackupRepair().repair(file, to: target, expectedVolume: nil)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    @Test func journalRoundTripRetainsCopyEvidenceAndUnfinishedFiles() throws {
        let project = UUID()
        var file = ImportedFileRecord(id: "item-1", projectID: project, filename: "A.JPG", source: "相机一")
        file.state = .saved
        file.assets = [asset(URL(fileURLWithPath: "/work/A.JPG"), data: Data([1]))]
        let pending = ImportedFileRecord(id: "item-2", projectID: project, filename: "B.JPG", source: "相机二")
        let batch = ImportBatchRecord(files: [file, pending], backupRequested: true, backupRoot: "/Volumes/Backup")
        let decoded = try JSONDecoder().decode(ImportBatchRecord.self, from: JSONEncoder().encode(batch))
        #expect(decoded == batch)
        #expect(decoded.savedCount == 1)
        #expect(decoded.pendingBackupCount == 1)
        #expect(decoded.files[1].state == .pending)
    }
}
