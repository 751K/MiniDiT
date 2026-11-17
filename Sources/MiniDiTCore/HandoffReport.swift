import Foundation
import SonyRemoteKit

/// A report is a dated snapshot of recorded transfers, not a new verification or QC pass.
public struct HandoffReport: Codable, Sendable {
    public struct Options: Sendable {
        public var projectID: UUID
        public var projectName: String
        public var scope: String
        public var preparedBy: String
        public var notes: String
        public var appVersion: String
        public init(projectID: UUID, projectName: String, scope: String, preparedBy: String = "", notes: String = "", appVersion: String = "") {
            self.projectID = projectID; self.projectName = projectName; self.scope = scope
            self.preparedBy = preparedBy; self.notes = notes; self.appVersion = appVersion
        }
    }
    public struct Row: Codable, Sendable {
        public var batchID: String, batchStarted: String, fileID: String, filename: String, importItemFilename: String, source: String
        public var sourceAddress: String, sourceIdentity: ImportSourceIdentity?
        public var media: String, capturedAt: String, captureDateRaw: String, roll: String, startTimecode: String, endTimecode: String, timecodeRate: String, resolution: String, frameRate: String, codec: String
        public var durationSeconds: Double?
        public var fileState: String, importedAt: String, proxyOnly: Bool, message: String
        public var assetKind: String, size: UInt64?, expectedSourceBytes: UInt64?, checksum: String
        public var targetID: String, targetName: String, role: String, required: Bool
        public var root: String, relativePath: String, path: String
        public var verification: String, verifiedAt: String, availability: String, error: String
        public var verified: Bool, historical: Bool
        public var needsAttention: Bool { !historical && (!verified || availability != "accessible" || !error.isEmpty || fileState != "saved") }
    }
    public struct Target: Codable, Sendable {
        public var batchID: String, id: String, name: String, root: String, volumeID: String?
        public var required: Bool, assets: Int, verified: Int, accessible: Int, pending: Int
    }
    public struct Source: Codable, Sendable {
        public var name: String, card: String, camera: String, serial: String, slot: String, roll: String, identifier: String
        public var items: Int, assets: Int, bytes: UInt64, knownDurationSeconds: Double, timedClips: Int
    }
    public struct Batch: Codable, Sendable {
        public var id: String, started: String, finished: String, state: String
        public var items: Int, saved: Int, proxyOnly: Int, assetCount: Int, bytes: UInt64
        public var delivery: [String: String]
    }
    public struct Manifest: Codable, Sendable {
        public var original: String, packagePath: String?, status: String
        public var expectedVolumeID: String?
        public init(original: String, packagePath: String? = nil, status: String = "pending", expectedVolumeID: String? = nil) {
            self.original = original; self.packagePath = packagePath; self.status = status; self.expectedVolumeID = expectedVolumeID
        }
    }
    public var formatVersion = 1
    public var id: UUID
    public var createdAt: Date
    public var projectID: UUID
    public var projectName: String, scope: String, preparedBy: String, notes: String, appVersion: String
    public var batches: [Batch], sources: [Source], targets: [Target], rows: [Row], manifests: [Manifest]
    public var issues: [String]
    public var itemCount: Int { batches.reduce(0) { $0 + $1.items } }
    public var assetCount: Int { batches.reduce(0) { $0 + $1.assetCount } }
    public var bytes: UInt64 { batches.reduce(0) { $0 + $1.bytes } }
    public var needsAttention: Bool { !issues.isEmpty || rows.contains(where: \.needsAttention) || manifests.contains { $0.status != "included" } }
    public var status: String { needsAttention ? String(localized: "有待处理或未覆盖项", bundle: .miniDiT) : String(localized: "所选范围记录完整", bundle: .miniDiT) }

    public static func snapshot(batches records: [ImportBatchRecord], options: Options, now: Date = Date()) throws -> Self {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        func timestamp(_ value: Date?) -> String { value.map { dateFormatter.string(from: $0) } ?? "" }
        var result = Self(id: UUID(), createdAt: now, projectID: options.projectID, projectName: options.projectName,
            scope: options.scope, preparedBy: options.preparedBy, notes: options.notes, appVersion: options.appVersion,
            batches: [], sources: [], targets: [], rows: [], manifests: [], issues: [])
        var sourceGroups: [String: Source] = [:], reportPaths = Set<String>()
        for batch in records.sorted(by: { $0.startedAt < $1.startedAt }) {
            try Task.checkCancellation()
            let files = batch.files.filter { $0.projectID == options.projectID }
            guard !files.isEmpty else { continue }
            let assets = files.flatMap(\.assets)
            result.batches.append(.init(id: batch.id.uuidString, started: timestamp(batch.startedAt), finished: timestamp(batch.finishedAt),
                state: batch.state.rawValue, items: files.count, saved: files.filter { $0.state == .saved }.count,
                proxyOnly: files.filter(\.proxyOnly).count, assetCount: assets.count, bytes: assets.reduce(0) { $0 + $1.size }, delivery: batch.delivery))
            if batch.state != .completed { result.issues.append(String(localized: "导入 \(batch.id.uuidString)：状态为 \(batch.state.rawValue)，不按已完成任务交接。", bundle: .miniDiT)) }
            if batch.backupRequested && batch.targets.isEmpty { result.issues.append(String(localized: "导入 \(batch.id.uuidString)：计划备份，但没有记录备份位置。", bundle: .miniDiT)) }
            if files.contains(where: \.proxyOnly) { result.issues.append(String(localized: "导入 \(batch.id.uuidString)：包含仅代理素材，未覆盖对应原片。", bundle: .miniDiT)) }
            if batch.files.contains(where: { $0.projectID != options.projectID }) { result.issues.append(String(localized: "导入 \(batch.id.uuidString)：本报告仅列所选项目；同批 ASC MHL 可能还包含其他项目。", bundle: .miniDiT)) }
            for (id, error) in (batch.backupReportErrors ?? [:]).sorted(by: { $0.key < $1.key }) { result.issues.append(String(localized: "目标 \(id) 的校验清单未完成：\(error)", bundle: .miniDiT)) }
            if batch.reports.isEmpty { result.issues.append(String(localized: "导入 \(batch.id.uuidString)：没有记录 ASC MHL 校验清单。", bundle: .miniDiT)) }
            let expectedAssets = assets.count + files.filter { $0.assets.isEmpty }.count
            for target in batch.targets {
                let matching = assets.map { asset in
                    asset.copies.filter { $0.role == .backup && contains($0.path, in: target.path) && ($0.targetID == target.id || $0.targetID == nil) }
                }
                let verified = zip(assets, matching).filter { asset, copies in
                    copies.contains { valid($0, asset: asset) } && asset.error(for: target) == nil
                }.count
                let accessible = zip(assets, matching).filter { asset, copies in
                    copies.contains { availability($0.path, size: asset.size, target: target) == "accessible" }
                }.count
                result.targets.append(.init(batchID: batch.id.uuidString, id: target.id.uuidString, name: target.name, root: target.path,
                    volumeID: target.volumeID, required: target.required, assets: expectedAssets, verified: verified,
                    accessible: accessible, pending: expectedAssets - verified))
            }
            for file in files {
                try Task.checkCancellation()
                let identity = file.sourceIdentity
                let sourceKey = [identity?.cardID?.uuidString ?? identity?.cameraID ?? identity?.connectionID.uuidString ?? file.source, identity?.volumeUUID ?? "", String(identity?.slot ?? 0), file.roll ?? ""].joined(separator: "|")
                var source = sourceGroups[sourceKey] ?? Source(name: file.source, card: identity?.cardName ?? "", camera: identity?.cameraModel ?? "",
                    serial: identity?.cameraSerial ?? "", slot: identity?.slot.map(String.init) ?? "", roll: file.roll ?? "",
                    identifier: identity?.cardID.map { String(localized: "卡档案 \($0.uuidString)", bundle: .miniDiT) } ?? identity?.cameraID ?? identity?.connectionID.uuidString ?? "",
                    items: 0, assets: 0, bytes: 0, knownDurationSeconds: 0, timedClips: 0)
                source.items += 1; source.assets += file.assets.count; source.bytes += file.assets.reduce(0) { $0 + $1.size }
                if let duration = file.durationSeconds, duration.isFinite, duration >= 0 { source.knownDurationSeconds += duration; source.timedClips += 1 }
                sourceGroups[sourceKey] = source
                if file.state != .saved || file.assets.isEmpty {
                    let reason = file.message ?? String(localized: "没有已保存的文件记录", bundle: .miniDiT)
                    result.issues.append(String(localized: "\(file.filename)：未完成保存，\(reason)。", bundle: .miniDiT))
                }
                if let message = file.message, !message.isEmpty { result.issues.append(String(localized: "\(file.filename)：\(message)", bundle: .miniDiT)) }
                func row(_ asset: ImportedAssetRecord?, _ copy: ImportedCopyRecord?, target: BackupDestination?, historical: Bool = false) -> Row {
                    let root = target?.path ?? copy.map { copy in
                        (batch.workingRoots ?? []).filter { contains(copy.path, in: $0) }.max { $0.count < $1.count }
                            ?? URL(filePath: copy.path).deletingLastPathComponent().path
                    } ?? ""
                    let path = copy?.path ?? ""
                    let assetName = asset.map { URL(filePath: copy?.path ?? $0.backupRelativePath).lastPathComponent }
                    return .init(batchID: batch.id.uuidString, batchStarted: timestamp(batch.startedAt), fileID: file.id, filename: assetName.flatMap { $0.isEmpty ? nil : $0 } ?? file.filename, importItemFilename: file.filename,
                        source: file.source, sourceAddress: file.sourceAddress ?? "", sourceIdentity: identity,
                        media: file.mediaKind ?? "", capturedAt: timestamp(file.capturedAt), captureDateRaw: file.captureDateRaw ?? "", roll: file.roll ?? "", startTimecode: file.startTimecode ?? "",
                        endTimecode: file.endTimecode ?? "", timecodeRate: file.timecodeRate ?? "", resolution: file.resolution ?? "",
                        frameRate: file.frameRate ?? "", codec: file.codec ?? "", durationSeconds: file.durationSeconds,
                        fileState: file.state.rawValue, importedAt: timestamp(file.importedAt), proxyOnly: file.proxyOnly, message: file.message ?? "",
                        assetKind: asset?.kind.rawValue ?? "notSaved", size: asset?.size, expectedSourceBytes: file.expectedBytes, checksum: asset?.xxh64 ?? "",
                        targetID: target?.id.uuidString ?? copy?.targetID?.uuidString ?? "working", targetName: target?.name ?? (historical ? String(localized: "历史备份位置", bundle: .miniDiT) : String(localized: "工作位置", bundle: .miniDiT)),
                        role: target == nil && !historical ? "working" : "backup", required: historical ? false : target?.required ?? true,
                        root: root, relativePath: contains(path, in: root) ? String(path.dropFirst(root.count + (root == "/" ? 0 : 1))) : "", path: path,
                        verification: copy?.evidence.rawValue ?? "notVerified", verifiedAt: timestamp(copy?.verifiedAt),
                        availability: copy.map { availability($0.path, size: asset?.size, target: target) } ?? "notRecorded",
                        error: target.flatMap { asset?.error(for: $0) } ?? "", verified: asset.map { asset in copy.map { valid($0, asset: asset) } ?? false } ?? false,
                        historical: historical)
                }
                if file.assets.isEmpty {
                    result.rows.append(row(nil, nil, target: nil))
                    for target in batch.targets { result.rows.append(row(nil, nil, target: target)) }
                    continue
                }
                for asset in file.assets {
                    let working = asset.copies.filter { $0.role == .working }
                    if working.isEmpty { result.rows.append(row(asset, nil, target: nil)) }
                    for copy in working { result.rows.append(row(asset, copy, target: nil)) }
                    for target in batch.targets {
                        let copies = asset.copies.filter { $0.role == .backup && contains($0.path, in: target.path) && ($0.targetID == target.id || $0.targetID == nil) }
                        if copies.isEmpty { result.rows.append(row(asset, nil, target: target)) }
                        for copy in copies { result.rows.append(row(asset, copy, target: target)) }
                    }
                    for copy in asset.copies where copy.role == .backup && !batch.targets.contains(where: { contains(copy.path, in: $0.path) && (copy.targetID == $0.id || copy.targetID == nil) }) {
                        result.rows.append(row(asset, copy, target: nil, historical: true))
                    }
                }
            }
            for path in batch.reports where reportPaths.insert(path).inserted {
                let volume = batch.targets.first { contains(path, in: $0.path) }?.volumeID
                result.manifests.append(.init(original: path, expectedVolumeID: volume))
            }
        }
        result.sources = sourceGroups.values.sorted { ($0.name, $0.roll, $0.card, $0.identifier) < ($1.name, $1.roll, $1.card, $1.identifier) }
        if result.batches.isEmpty { result.issues.append(String(localized: "所选范围没有可导出的项目导入记录。", bundle: .miniDiT)) }
        return result
    }
    static func valid(_ copy: ImportedCopyRecord, asset: ImportedAssetRecord) -> Bool {
        copy.verifiedAt != nil && copy.evidence != .legacy && asset.xxh64?.count == 16 && asset.xxh64?.allSatisfy(\.isHexDigit) == true
    }
    static func contains(_ path: String, in root: String) -> Bool {
        !root.isEmpty && path.hasPrefix(root == "/" ? "/" : root + "/") && path != root
    }
    static func availability(_ path: String, size: UInt64?, target: BackupDestination?) -> String {
        if let target, target.availability == .wrongVolume { return "wrongVolume" }
        if let target, target.availability == .unavailable { return "unavailable" }
        guard let values = try? URL(filePath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isReadableKey]),
              values.isRegularFile == true, values.isReadable == true else { return "unavailable" }
        if let size, values.fileSize.map({ UInt64($0) }) != size { return "sizeChanged" }
        return "accessible"
    }
    static func iso(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}
