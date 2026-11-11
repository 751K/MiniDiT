import Foundation

/// Frozen handoff data belongs to an import, not to the current UI preferences.
public struct VideoDelivery: Codable, Identifiable, Sendable, Equatable {
    public enum Software: String, Codable, Sendable { case finalCutPro, resolve, premiere
        public var name: String { switch self { case .finalCutPro: "Final Cut Pro"; case .resolve: "DaVinci Resolve"; case .premiere: "Adobe Premiere Pro" } }
    }
    public enum State: String, Codable, Sendable { case queued, sending, failed, awaitingConfirmation, completed, needsAttention, interrupted, uncertain }
    public struct File: Codable, Sendable, Equatable {
        public var path: String, size: UInt64
        public var volumeID: String?
        public init(path: String, size: UInt64, volumeID: String? = nil) { self.path = path; self.size = size; self.volumeID = volumeID }
    }
    public var id: UUID
    public var software: Software
    public var projectIDs: [UUID]
    public var payload: Data
    public var files: [File]
    public var mediaPaths: [String]
    public var createdAt: Date
    public var state: State = .queued
    public var message = "等待发送"
    public var attempts = 0
    public var attemptID: UUID?
    public var attemptedAt: Date?
    public var finishedAt: Date?
    public var resolveProjectID: String?
    public var resolveProjectName: String?
    public var premiereProjectID: String?
    public var premiereProjectName: String?
    public var documentPath: String?
    public var failedPaths: [String] = []
    public var warnings: [String] = []
    public init(id: UUID = UUID(), software: Software, projectIDs: [UUID], payload: Data, files: [File], mediaPaths: [String]? = nil, createdAt: Date = Date()) {
        self.id = id; self.software = software; self.projectIDs = projectIDs; self.payload = payload; self.files = files; self.mediaPaths = mediaPaths ?? files.map(\.path); self.createdAt = createdAt
    }
    public var canRetry: Bool {
        guard !payload.isEmpty else { return false }
        switch state {
        case .failed: return true
        case .interrupted, .needsAttention: return software != .finalCutPro
        default: return false
        }
    }
    public var recovered: Self {
        var next = self
        if state == .sending {
            next.state = software == .finalCutPro ? .uncertain : .interrupted
            next.message = software == .finalCutPro ? "上次发送的结果无法确认，请先在 Final Cut Pro 中查看。" : "上次发送已中断，可重试加入原项目。"
        } else if state == .queued {
            next.state = .failed; next.message = "上次尚未发送，可重试。"
        }
        return next
    }
    /// Only inspect accessibility and recorded size; a retry is not a new content-verification task.
    public func checkFiles() throws {
        for file in files {
            try Task.checkCancellation()
            let url = URL(filePath: file.path)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]), values.isRegularFile == true, values.isReadable == true else {
                throw Failure("文件无法访问，请连接原存储位置后重试：\(url.lastPathComponent)")
            }
            if let expected = file.volumeID, BackupRepair.volumeID(at: url) != expected { throw Failure("存储位置已更换，请连接原磁盘后重试：\(url.lastPathComponent)") }
            guard values.fileSize.map({ UInt64($0) }) == file.size else { throw Failure("文件大小已变化，请检查本地文件：\(url.lastPathComponent)") }
        }
    }
    public struct Failure: LocalizedError, Sendable {
        public var message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
}
