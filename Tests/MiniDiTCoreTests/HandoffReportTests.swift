import Foundation
import Testing
import PDFKit
@testable import MiniDiTCore

@Suite struct HandoffReportTests {
    struct Fixture {
        var root: URL, project: UUID, batch: ImportBatchRecord, a: BackupDestination, b: BackupDestination
        var options: HandoffReport.Options { .init(projectID: project, projectName: "海边 <拍摄>", scope: "所选导入", preparedBy: "DIT", notes: "<script>bad()</script>\n备注") }
    }
    func fixture() throws -> Fixture {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-report-test-" + UUID().uuidString)
        for name in ["work", "A", "B", "exports"] { try fm.createDirectory(at: root.appending(path: name), withIntermediateDirectories: true) }
        let a = BackupDestination(name: "主备份", root: root.appending(path: "A"))
        let b = BackupDestination(name: "交接备份", root: root.appending(path: "B"))
        let data = Data([1,2,3,4]); var hash = XXH64(); data.withUnsafeBytes { hash.update($0) }
        var copies: [ImportedCopyRecord] = []
        for (name, target) in [("work", Optional<BackupDestination>.none), ("A", a), ("B", b)] {
            let path = root.appending(path: name + "/A.JPG"); try data.write(to: path)
            copies.append(.init(role: target == nil ? .working : .backup, path: path.path, verifiedAt: Date(timeIntervalSince1970: 100),
                                evidence: target == nil ? .sourceComparison : .localReadback, targetID: target?.id))
        }
        let project = UUID()
        var file = ImportedFileRecord(id: "file1", projectID: project, filename: "A.JPG", source: "相机卡")
        file.state = .saved; file.importedAt = Date(timeIntervalSince1970: 100)
        file.mediaKind = "photo"; file.sourceAddress = "/Volumes/CARD/DCIM/A.JPG"
        file.expectedBytes = 4
        file.sourceIdentity = .init(kind: .card, evidence: .volume, connectionID: UUID())
        file.sourceIdentity?.cardID = UUID(); file.sourceIdentity?.cardName = "SD 01"; file.sourceIdentity?.volumeUUID = "CARD-UUID"
        file.assets = [.init(kind: .original, size: 4, xxh64: XXH64.hex(hash.digest()), backupRelativePath: "A.JPG", copies: copies)]
        var batch = ImportBatchRecord(files: [file], backupRequested: true, backupRoot: a.path, state: .completed)
        batch.backupTargets = [a, b]; batch.finishedAt = Date(timeIntervalSince1970: 120); batch.workingRoots = [root.appending(path: "work").path]
        for name in ["work", "A", "B"] {
            let dir = root.appending(path: name + "/ascmhl"); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let first = dir.appending(path: "0001.mhl"), second = dir.appending(path: "0002.mhl")
            try Data("<hashlist>first</hashlist>".utf8).write(to: first)
            try Data("<hashlist>second</hashlist>".utf8).write(to: second)
            try Data("<ascmhldirectory><hashlist><path>0001.mhl</path></hashlist><hashlist><path>0002.mhl</path></hashlist></ascmhldirectory>".utf8).write(to: dir.appending(path: "ascmhl_chain.xml"))
            batch.reports.append(second.path)
        }
        return Fixture(root: root, project: project, batch: batch, a: a, b: b)
    }
    func exported(_ report: HandoffReport, fixture: Fixture) throws -> (URL, HandoffReport) {
        let url = try HandoffPackage.write(report, to: fixture.root.appending(path: "exports"))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(HandoffReport.self, from: Data(contentsOf: url.appending(path: "manifest.json")))
        return (url, snapshot)
    }
    @Test func completeReportKeepsCopyFactsPortableInventoryAndWholeMHLHistory() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let report = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        let (url, snapshot) = try exported(report, fixture: f)
        #expect(!snapshot.needsAttention)
        #expect(snapshot.rows.count == 3 && snapshot.assetCount == 1 && snapshot.bytes == 4)
        #expect(snapshot.targets.allSatisfy { $0.verified == 1 && $0.accessible == 1 && $0.pending == 0 })
        #expect(snapshot.rows.allSatisfy { $0.relativePath == "A.JPG" && $0.verifiedAt.hasSuffix("Z") })
        #expect(snapshot.rows.first?.verification == "sourceComparison")
        #expect(snapshot.sources.first?.identifier.contains("卡档案") == true)
        for manifest in snapshot.manifests {
            let path = try #require(manifest.packagePath)
            let folder = url.appending(path: path).deletingLastPathComponent()
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "0001.mhl").path))
            #expect(FileManager.default.fileExists(atPath: folder.appending(path: "ascmhl_chain.xml").path))
        }
        let pdf = try #require(PDFDocument(url: url.appending(path: "report.pdf")))
        #expect(pdf.pageCount >= 2 && pdf.string?.contains("导入记录") == true)
        #expect(pdf.string?.contains("备份记录") == true && pdf.string?.contains("照片") == true)
        #expect(!FileManager.default.fileExists(atPath: url.appending(path: "index.html").path))
        #expect(try Data(contentsOf: url.appending(path: "files.csv")).starts(with: [0xEF,0xBB,0xBF]))
    }
    @Test func offlineAndChangedFilesDoNotErasePastVerificationOrPretendToRehash() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try FileManager.default.removeItem(at: f.root.appending(path: "B/A.JPG"))
        try Data([4,3,2,1]).write(to: f.root.appending(path: "A/A.JPG")) // Same size: no new hash pass is claimed.
        try Data([1]).write(to: f.root.appending(path: "work/A.JPG"))
        let r = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        #expect(r.rows.first { $0.targetID == f.b.id.uuidString }?.verified == true)
        #expect(r.rows.first { $0.targetID == f.b.id.uuidString }?.availability == "unavailable")
        #expect(r.rows.first { $0.targetID == f.a.id.uuidString }?.availability == "accessible")
        #expect(r.rows.first { $0.role == "working" }?.availability == "sizeChanged")
        #expect(r.needsAttention && r.targets.first { $0.id == f.b.id.uuidString }?.verified == 1)
    }
    @Test func selectedProjectIncludesFailedAndProxyOnlyRecordsWithoutCountingOthers() throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var missing = ImportedFileRecord(id: "missing", projectID: f.project, filename: "MISSING.MP4", source: "相机卡")
        missing.state = .failed; missing.expectedBytes = 900; missing.proxyOnly = true; missing.message = "中途取消"
        var other = missing; other.id = "other"; other.projectID = UUID(); other.filename = "OTHER.MP4"
        f.batch.files += [missing, other]; f.batch.state = .cancelled
        let r = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        #expect(r.itemCount == 2 && r.assetCount == 1 && r.rows.count == 6)
        #expect(!r.rows.contains { $0.filename == "OTHER.MP4" })
        #expect(r.rows.filter { $0.filename == "MISSING.MP4" }.allSatisfy { $0.size == nil && $0.expectedSourceBytes == 900 && !$0.verified })
        #expect(r.targets.allSatisfy { $0.assets == 2 && $0.pending == 1 })
        #expect(r.issues.contains { $0.contains("仅代理") } && r.issues.contains { $0.contains("其他项目") })
    }
    @Test func versionsMissingManifestsAndCancellationNeverOverwritePriorReports() async throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let r1 = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        let (first, _) = try exported(r1, fixture: f)
        let original = try Data(contentsOf: first.appending(path: "manifest.json"))
        try FileManager.default.removeItem(at: URL(filePath: f.batch.reports[0]))
        f.batch.files[0].proxyOnly = true
        let r2 = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        let (second, exportedSecond) = try exported(r2, fixture: f)
        #expect(first != second && exportedSecond.needsAttention)
        #expect(exportedSecond.manifests.contains { $0.status.hasPrefix("unavailable:") })
        #expect(try Data(contentsOf: first.appending(path: "manifest.json")) == original)
        let exportParent = f.root.appending(path: "exports")
        let cancelled = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            return try HandoffPackage.write(r2, to: exportParent)
        }
        do { _ = try await cancelled.value; Issue.record("cancelled export succeeded") } catch is CancellationError {}
        let names = try FileManager.default.contentsOfDirectory(atPath: f.root.appending(path: "exports").path)
        #expect(names.count == 2 && !names.contains { $0.hasPrefix(".minidit-report-") })
    }
    @Test func csvEscapesQuotesNewlinesAndSpreadsheetFormulas() throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.batch.files[0].filename = "=1+2,\"测\n试\".JPG"
        let r = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        let csv = HandoffPackage.csv(r)
        #expect(csv.contains("\"'=1+2,\"\"测\n试\"\".JPG\""))
        #expect(csv.hasSuffix("\r\n"))
        #expect(r.rows[0].importItemFilename == f.batch.files[0].filename) // Raw JSON value remains unmodified.
    }
    @Test func legacyAndRelocatedLocationsCannotCompleteCurrentRequiredTarget() throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.batch.files[0].assets[0].copies[0].evidence = .legacy
        f.batch.files[0].assets[0].copies.removeLast()
        var historical = f.batch.files[0].assets[0].copies[1]
        historical.targetID = f.b.id; historical.path = f.root.appending(path: "retired/A.JPG").path
        f.batch.files[0].assets[0].copies.append(historical)
        let r = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        #expect(r.rows.first { $0.role == "working" }?.verified == false)
        #expect(r.targets.first { $0.id == f.b.id.uuidString }?.pending == 1)
        #expect(r.rows.contains { $0.historical && $0.path == historical.path })
        #expect(r.needsAttention)
    }
    @Test func largeShootKeepsAllCopiesInCSVAndCatalogueGroupsCopiesByImportItem() throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let original = f.batch.files[0]
        f.batch.files = (0..<5_000).map { index in
            var file = original
            file.id = "large-\(index)"; file.filename = "CLIP_\(index).JPG"
            return file
        }
        let report = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        #expect(report.itemCount == 5_000 && report.assetCount == 5_000 && report.rows.count == 15_000)
        let csv = HandoffPackage.csv(report)
        #expect(csv.components(separatedBy: "\r\n").count == 15_002)
        #expect(csv.contains("CLIP_4999.JPG"))
        let items = HandoffPDF.items(report)
        #expect(items.count == 5_000 && items.contains { $0.name == "CLIP_4999.JPG" })
    }
    @Test func remountedDifferentVolumeCannotSupplyCopiesOrChecksumAttachments() throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.batch.backupTargets?[0].volumeID = "OTHER-VOLUME-IDENTITY"
        let report = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        #expect(report.rows.first { $0.targetID == f.a.id.uuidString }?.availability == "wrongVolume")
        let (_, saved) = try exported(report, fixture: f)
        #expect(saved.manifests.first { $0.original.contains("/A/ascmhl/") }?.status.hasPrefix("unavailable:") == true)
        #expect(saved.manifests.first { $0.original.contains("/A/ascmhl/") }?.packagePath == nil)
        #expect(saved.needsAttention)
    }

    @Test func sidecarsUseTheirActualFilenameAndKeepTheRelatedImportItem() throws {
        var f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        f.batch.files[0].filename = "C0001.MP4"
        f.batch.files[0].assets[0].kind = .metadata
        f.batch.files[0].assets[0].backupRelativePath = "C0001M01.XML"
        for index in f.batch.files[0].assets[0].copies.indices {
            let old = URL(filePath: f.batch.files[0].assets[0].copies[index].path)
            let renamed = old.deletingLastPathComponent().appending(path: "C0001M01.XML")
            try FileManager.default.moveItem(at: old, to: renamed)
            f.batch.files[0].assets[0].copies[index].path = renamed.path
        }
        let report = try HandoffReport.snapshot(batches: [f.batch], options: f.options)
        #expect(report.rows.allSatisfy { $0.filename == "C0001M01.XML" && $0.importItemFilename == "C0001.MP4" })
        #expect(HandoffPackage.csv(report).contains("ImportItemSourceAddress"))
    }

    @Test func filmstripUsesFixedTimePerThumbnailAndAllowsLongFilesToWrap() {
        #expect(HandoffPDF.stripWidth(duration: 30, secondsPerLine: 60, available: 500) == 250)
        #expect(HandoffPDF.stripWidth(duration: 6, secondsPerLine: 40, available: 800) == 200)
        #expect(HandoffPDF.stripWidth(duration: 3, secondsPerLine: 40, available: 800) == 100)
        #expect(HandoffPDF.stripWidth(duration: 60, secondsPerLine: 60, available: 500) == 500)
        #expect(HandoffPDF.stripWidth(duration: 120, secondsPerLine: 60, available: 500) == 1_000)
        #expect(HandoffPDF.stripWidth(duration: .infinity, secondsPerLine: 60, available: 500).isFinite)
        #expect(HandoffPDF.stripWidth(duration: nil, secondsPerLine: 0, available: 500).isFinite)
    }
    @Test func longNotesPaginateAndCancellationDuringPreviewsLeavesNoPartialPackage() async throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var options = f.options
        options.notes = (0..<130).map { "备注 \($0)：中文路径与拍摄信息 / camera / 照片 🎞️" }.joined(separator: "\n") + "\nEND-REPORT"
        let report = try HandoffReport.snapshot(batches: [f.batch], options: options)
        let (folder, _) = try exported(report, fixture: f)
        let pdf = try #require(PDFDocument(url: folder.appending(path: "report.pdf")))
        #expect(pdf.pageCount > 3 && pdf.string?.contains("END-REPORT") == true)
        let parent = f.root.appending(path: "exports")
        let cancelled = Task.detached {
            try HandoffPackage.write(report, to: parent) { status in
                if status.contains("照片预览") { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelled.value; Issue.record("mid-preview cancellation succeeded unexpectedly") } catch is CancellationError {}
        let names = try FileManager.default.contentsOfDirectory(atPath: parent.path)
        #expect(names.count == 1 && !names.contains { $0.hasPrefix(".minidit-report-") })
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "report.pdf").path))
    }
    @Test func filmstripSeparatesFilesButKeepsCrossLineContinuationsFlush() {
        let pieces = HandoffPDF.filmLayout(widths: [180, 90, 120], lineWidth: 300)
        #expect(pieces.count == 4)
        #expect(pieces[1].x - (pieces[0].x + pieces[0].width) == 6)
        #expect(pieces[2].x == 282 && pieces[2].width == 18)
        #expect(pieces[3].item == pieces[2].item && pieces[3].line == 1)
        #expect(pieces[3].x == 0 && pieces[3].offset == 18 && pieces[3].width == 102)
        let aligned = HandoffPDF.filmLayout(widths: [300, 30], lineWidth: 300)
        #expect(aligned.count == 2 && aligned[1].line == 1 && aligned[1].x == 0)
    }
}
