import Foundation
import Testing
import MiniDiTCore

@Suite struct VideoDeliveryTests {
    @Test func retryStatesDistinguishFailureFromUnknownReceipt() throws {
        for software in [VideoDelivery.Software.finalCutPro, .resolve, .premiere] {
            var record = VideoDelivery(software: software, projectIDs: [UUID()], payload: Data([1, 2]), files: [])
            #expect(!record.canRetry)
            record.state = .failed; #expect(record.canRetry)
            record.state = .sending; record.attemptID = UUID(); record.attempts = 2
            let recovered = record.recovered
            #expect(recovered.state == (software != .finalCutPro ? .interrupted : .uncertain))
            #expect(recovered.canRetry == (software != .finalCutPro))
            #expect(recovered.attemptID == record.attemptID && recovered.attempts == 2)
            record.state = .awaitingConfirmation; #expect(!record.canRetry)
            record.state = .completed; #expect(!record.canRetry)
            record.state = .needsAttention; #expect(record.canRetry == (software != .finalCutPro))
            record.state = .queued; #expect(record.recovered.canRetry)
            record.payload = Data(); #expect(!record.recovered.canRetry)
        }
    }

    @Test func frozenRequestTargetAndReceiptSurvivePersistence() throws {
        var record = VideoDelivery(software: .resolve, projectIDs: [UUID()], payload: Data("{\"color\":true}".utf8),
                                   files: [.init(path: "/Volumes/work/A.MP4", size: 123, volumeID: "volume-a")])
        record.resolveProjectID = "original-project-id"; record.resolveProjectName = "婚礼"
        record.state = .failed; record.attemptID = UUID(); record.attemptedAt = Date(); record.attempts = 1
        record.failedPaths = ["/Volumes/work/A.MP4"]; record.warnings = ["代理未能链接"]
        var batch = ImportBatchRecord(files: [], backupRequested: false, backupRoot: nil, state: .completed)
        batch.videoDeliveries = [record]
        let decoded = try JSONDecoder().decode(ImportBatchRecord.self, from: JSONEncoder().encode(batch))
        #expect(decoded.videoDeliveries == [record])
        #expect(decoded.videoDeliveries?.first?.canRetry == true)
    }

    @Test func retryPreflightRequiresAvailableUnchangedSizeAndOriginalVolume() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let original = root.appending(path: "A.MP4"), proxy = root.appending(path: "Proxy.MP4")
        try Data([1, 2, 3]).write(to: original); try Data([1, 2]).write(to: proxy)
        var record = VideoDelivery(software: .resolve, projectIDs: [], payload: Data([1]), files: [
            .init(path: original.path, size: 3, volumeID: BackupRepair.volumeID(at: original)), .init(path: proxy.path, size: 2)])
        try record.checkFiles()
        record.files[0].volumeID = "different-volume"
        #expect(throws: VideoDelivery.Failure.self) { try record.checkFiles() }
        record.files[0].volumeID = nil
        try Data([1]).write(to: original)
        #expect(throws: VideoDelivery.Failure.self) { try record.checkFiles() }
        try Data([1, 2, 3]).write(to: original); try fm.removeItem(at: proxy)
        #expect(throws: VideoDelivery.Failure.self) { try record.checkFiles() }
        try fm.createDirectory(at: proxy, withIntermediateDirectories: true)
        #expect(throws: VideoDelivery.Failure.self) { try record.checkFiles() }
    }
}
