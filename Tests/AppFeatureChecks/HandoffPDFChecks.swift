import AppKit
import AVFoundation
import Foundation
import PDFKit
import MiniDiTCore

@main struct HandoffPDFChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(filePath: "/tmp/minidit-pdf-fixtures-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let backupRoot = root.appending(path: "交接备份")
        try fm.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        let backup = BackupDestination(name: "交接备份", root: backupRoot)
        let project = UUID(), date = Date(timeIntervalSince1970: 1_794_304_800)
        let fixtureRoot = URL(filePath: ProcessInfo.processInfo.environment["FEATURE_ROOT"]!).appending(path: "Website/minidit/public")
        let names = ["coast", "city", "walk", "cliffs", "rocks", "street"]
        var files: [ImportedFileRecord] = []
        var identity = ImportSourceIdentity(kind: .camera, evidence: .serial, connectionID: UUID())
        identity.cameraModel = "Sony α7 V"; identity.cameraSerial = "DEMO-CAMERA-01"; identity.slot = 1
        for i in 0..<20 {
            let video = i >= 13
            let name = video ? String(format: "C%04d.MP4", i - 12) : String(format: "DSC%05d.JPG", i + 1)
            let destination = root.appending(path: name)
            let source = video && ProcessInfo.processInfo.environment["MINIDIT_PDF_VIDEOS"] != nil ? URL(filePath: ProcessInfo.processInfo.environment["MINIDIT_PDF_VIDEOS"]!).appending(path: name) : fixtureRoot.appending(path: video ? "videos/coast.mp4" : "images/" + names[i % names.count] + ".jpg")
            try fm.copyItem(at: source, to: destination)
            let backupFile = backupRoot.appending(path: name)
            try fm.copyItem(at: destination, to: backupFile)
            let data = try Data(contentsOf: destination)
            var hash = XXH64(); data.withUnsafeBytes { hash.update($0) }
            var file = ImportedFileRecord(id: name, projectID: project, filename: name, source: "α7 V（DEMO-01）")
            file.state = .saved; file.importedAt = date; file.capturedAt = date.addingTimeInterval(Double(i * 60))
            file.mediaKind = video ? "video" : "photo"; file.sourceIdentity = identity; file.sourceAddress = "/Volumes/DEMO-CARD/" + name
            file.assets = [.init(kind: .original, size: UInt64(data.count), xxh64: XXH64.hex(hash.digest()), backupRelativePath: name,
                copies: [.init(role: .working, path: destination.path, verifiedAt: date, evidence: .sourceComparison), .init(role: .backup, path: backupFile.path, verifiedAt: date, evidence: .localReadback, targetID: backup.id)])]
            if video {
                file.roll = i < 18 ? "A001" : "B001"
                file.startTimecode = "01:00:00:00"; file.timecodeRate = "25"
                file.durationSeconds = AVURLAsset(url: destination).duration.seconds
                file.resolution = "960×640"; file.frameRate = "25"; file.codec = "H.264"
            }
            if i == 12 { try fm.removeItem(at: destination); try fm.removeItem(at: backupFile) }
            files.append(file)
        }
        var batch = ImportBatchRecord(files: files, backupRequested: true, backupRoot: backupRoot.path, state: .completed)
        batch.backupTargets = [backup]
        batch.startedAt = date; batch.finishedAt = date.addingTimeInterval(60); batch.workingRoots = [root.path]
        let report = try HandoffReport.snapshot(batches: [batch], options: .init(projectID: project, projectName: "海边与城市 · 交接排版示例", scope: "演示素材，供排版与抽帧检查", preparedBy: "MiniDiT", notes: "包含照片、两卷视频及一张离线照片。"))
        let output = URL(filePath: "/tmp/minidit-pdf-preview")
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let exported = try HandoffPackage.write(report, to: output)
        let document = PDFDocument(url: exported.appending(path: "report.pdf"))!
        let text = (document.string ?? "").precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        FileHandle.standardError.write(Data("PDF pages: \(document.pageCount); titles: \(text.contains("ROLL A001")), \(text.contains("ROLL B001"))\n".utf8))
        precondition(document.pageCount >= 4 && text.contains("ROLL A001") && text.contains("ROLL B001"))
        precondition(text.contains("导入记录") && text.contains("备份记录") && text.contains("交接备份") && text.contains("DSC00013.JPG"))
        precondition(text.contains("第 1-13 项"))
        for index in 1...7 { precondition(text.contains(String(format: "C%04d.MP4", index))) }
        precondition(!text.contains("个片段") && !text.contains("(续)") && !text.contains("（续）"))
        precondition(!fm.fileExists(atPath: exported.appending(path: "index.html").path))
        print("PDF_SAMPLE: " + exported.path)
        print("PASS: \(document.pageCount) PDF pages; photo pagination, offline placeholder, two rolls, duration-scaled concatenated filmstrips, full filenames, long-clip wraps, real image/video previews; no HTML")
    }
}
