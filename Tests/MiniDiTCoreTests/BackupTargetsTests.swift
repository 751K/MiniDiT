import Foundation
import Testing
@testable import MiniDiTCore

struct BackupTargetsTests {
    @Test func targetsHaveIndependentRequirementsAndErrors() throws {
        let a = BackupDestination(name: "A", root: URL(filePath: "/backup-a"))
        let b = BackupDestination(name: "B", root: URL(filePath: "/backup-b"), required: false)
        var asset = ImportedAssetRecord(kind: .original, size: 1, xxh64: "0000000000000000", backupRelativePath: "A.JPG",
            copies: [.init(role: .working, path: "/work/A.JPG", evidence: .sourceComparison),
                     .init(role: .backup, path: "/backup-a/A.JPG", verifiedAt: .now, evidence: .localReadback, targetID: a.id)])
        asset.targetErrors = [b.id.uuidString: "offline"]
        var file = ImportedFileRecord(id: "1", projectID: UUID(), filename: "A.JPG", source: "card")
        file.state = .saved; file.assets = [asset]
        var batch = ImportBatchRecord(files: [file], backupRequested: true, backupRoot: a.path)
        batch.backupTargets = [a, b]
        #expect(batch.verifiedCount(for: a) == 1)
        #expect(batch.verifiedCount(for: b) == 0)
        #expect(batch.pendingBackupCount == 1)
        #expect(batch.requiredBackupsComplete)
        batch.backupTargets?[1].required = true
        #expect(!batch.requiredBackupsComplete)
        let restored = try JSONDecoder().decode(ImportBatchRecord.self, from: JSONEncoder().encode(batch))
        #expect(restored == batch)
        #expect(restored.targets.map(\.id) == [a.id, b.id])
        #expect(restored.files[0].assets[0].error(for: b) == "offline")
        #expect(BackupDestination.overlaps(URL(filePath: "/a"), URL(filePath: "/a/sub")))
        #expect(!BackupDestination.overlaps(URL(filePath: "/a"), URL(filePath: "/ab")))
        #expect(BackupDestination.overlaps(URL(filePath: "/"), URL(filePath: "/a")))
    }
    @Test func repairsOneTargetWithoutChangingOthers() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-target-core-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let work = root.appending(path: "A.JPG"), aRoot = root.appending(path: "A"), bRoot = root.appending(path: "B")
        try fm.createDirectory(at: aRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: bRoot, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x33, count: 4096)
        try bytes.write(to: work)
        var hash = XXH64(); bytes.withUnsafeBytes { hash.update($0) }
        let a = BackupDestination(name: "A", root: aRoot), b = BackupDestination(name: "B", root: bRoot)
        var asset = ImportedAssetRecord(kind: .original, size: UInt64(bytes.count), xxh64: XXH64.hex(hash.digest()), backupRelativePath: "photos/A.JPG",
                                        copies: [.init(role: .working, path: work.path, verifiedAt: .now, evidence: .sourceComparison)])
        let worker = BackupRepair()
        asset = try await worker.repair(asset, to: aRoot, expectedVolume: a.volumeID, targetID: a.id)
        let first = asset.copies.first { $0.targetID == a.id }!
        asset.targetErrors = [b.id.uuidString: "offline"]
        try fm.removeItem(at: work)
        let repaired = try await worker.repair(asset, to: bRoot, expectedVolume: b.volumeID, targetID: b.id)
        #expect(repaired.hasBackup(at: a) && repaired.hasBackup(at: b))
        #expect(repaired.copies.first { $0.targetID == a.id } == first)
        #expect(repaired.error(for: b) == nil)
        #expect(try Data(contentsOf: bRoot.appending(path: "photos/A.JPG")) == bytes)
        let retried = try await worker.repair(repaired, to: bRoot, expectedVolume: b.volumeID, targetID: b.id)
        #expect(retried.copies.count == repaired.copies.count)
        do { _ = try await worker.repair(retried, to: bRoot, expectedVolume: "wrong-volume", targetID: b.id); Issue.record("wrong-volume target was accepted") }
        catch BackupRepair.Failure.wrongVolume {}
    }
}
