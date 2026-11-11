import Foundation

public enum HandoffPackage {
    private enum Failure: LocalizedError {
        case wrongManifestVolume
        var errorDescription: String? { "校验清单所在磁盘与导入记录中的目标不符。" }
    }
    /// Every export is a new immutable folder. Failure removes only this operation's staging directory.
    public static func write(_ input: HandoffReport, to parent: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) throws -> URL {
        let fm = FileManager.default
        guard (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw CocoaError(.fileWriteInvalidFileName) }
        let stage = parent.appending(path: ".minidit-report-" + input.id.uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: stage) }
        progress("正在整理导入与校验记录…")
        var report = input
        var copiedDirectories: [String: String] = [:]
        for index in report.manifests.indices {
            try Task.checkCancellation()
            let source = URL(filePath: report.manifests[index].original)
            let directory = source.deletingLastPathComponent()
            do {
                guard directory.lastPathComponent == "ascmhl", source.pathExtension.lowercased() == "mhl" else { throw CocoaError(.fileReadInvalidFileName) }
                if let expected = report.manifests[index].expectedVolumeID, BackupRepair.volumeID(at: directory) != expected {
                    throw Failure.wrongManifestVolume
                }
                let relative: String
                if let existing = copiedDirectories[directory.path] { relative = existing }
                else {
                    relative = String(format: "checksums/%03d/ascmhl", copiedDirectories.count + 1)
                    let destination = stage.appending(path: relative)
                    let partial = stage.appending(path: relative + ".partial")
                    try fm.createDirectory(at: partial, withIntermediateDirectories: true)
                    do {
                        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            where file.pathExtension.lowercased() == "mhl" || file.lastPathComponent == "ascmhl_chain.xml" {
                            try Task.checkCancellation()
                            let properties = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                            guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
                            try fm.copyItem(at: file, to: partial.appending(path: file.lastPathComponent))
                        }
                        try fm.moveItem(at: partial, to: destination)
                    } catch { try? fm.removeItem(at: partial); throw error }
                    if !fm.fileExists(atPath: destination.appending(path: "ascmhl_chain.xml").path) {
                        report.issues.append("校验材料缺少 ASC MHL 历史链：" + directory.path)
                    }
                    copiedDirectories[directory.path] = relative
                }
                let file = relative + "/" + source.lastPathComponent
                guard fm.fileExists(atPath: stage.appending(path: file).path) else { throw CocoaError(.fileNoSuchFile) }
                report.manifests[index].packagePath = file; report.manifests[index].status = "included"
            } catch is CancellationError { throw CancellationError() }
            catch { report.manifests[index].status = "unavailable: " + error.localizedDescription }
        }
        try Task.checkCancellation()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: stage.appending(path: "manifest.json"), options: .withoutOverwriting)
        try Data(("\u{FEFF}" + csv(report)).utf8).write(to: stage.appending(path: "files.csv"), options: .withoutOverwriting)
        try HandoffPDF.write(report, to: stage.appending(path: "report.pdf"), progress: progress)
        try Data(readme.utf8).write(to: stage.appending(path: "README.txt"), options: .withoutOverwriting)
        try Task.checkCancellation()
        let name = String(report.projectName.map { "/:\\".contains($0) ? "-" : $0 }.prefix(60)).trimmingCharacters(in: CharacterSet(charactersIn: ". \n\t"))
        let stamp = HandoffReport.iso(report.createdAt).replacingOccurrences(of: ":", with: "-")
        let destination = parent.appending(path: (name.isEmpty ? "MiniDiT" : name) + "_交接_" + stamp + "_" + report.id.uuidString.prefix(8))
        try fm.moveItem(at: stage, to: destination)
        return destination
    }
    static func cell(_ value: String) -> String {
        let leading = value.trimmingCharacters(in: .whitespacesAndNewlines).first
        let safe = leading.map { "=+-@".contains($0) } == true ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    public static func csv(_ report: HandoffReport) -> String {
        let headers = ["ReportID","Project","BatchID","BatchStartedUTC","FileID","Filename","ImportItemFilename","Source","ImportItemSourceAddress","CameraModel","CameraSerial","CardName","CardArchiveID","VolumeUUID","Slot","MediaType","CaptureDateUTC","CaptureDateRaw","Roll","DurationSeconds","FrameRate","StartTimecode","EndTimecode","TimecodeRate","Resolution","Codec","FileState","ImportedAtUTC","ProxyOnly","AssetKind","SizeBytes","ImportItemExpectedSourceBytes","ChecksumAlgorithm","Checksum","TargetRole","TargetID","TargetName","Required","Root","RelativePath","RecordedPath","Evidence","LastVerifiedUTC","CurrentAvailability","RecordedVerified","HistoricalLocation","TargetError","FileMessage"]
        let lines = report.rows.map { row -> String in
            let values: [String] = [report.id.uuidString, report.projectName, row.batchID, row.batchStarted, row.fileID, row.filename, row.importItemFilename, row.source,
                row.sourceAddress, row.sourceIdentity?.cameraModel ?? "", row.sourceIdentity?.cameraSerial ?? "", row.sourceIdentity?.cardName ?? "",
                row.sourceIdentity?.cardID?.uuidString ?? "", row.sourceIdentity?.volumeUUID ?? "", row.sourceIdentity?.slot.map(String.init) ?? "",
                row.media, row.capturedAt, row.captureDateRaw, row.roll, row.durationSeconds.map { String($0) } ?? "", row.frameRate, row.startTimecode, row.endTimecode, row.timecodeRate, row.resolution, row.codec,
                row.fileState, row.importedAt, String(row.proxyOnly), row.assetKind, row.size.map(String.init) ?? "", row.expectedSourceBytes.map(String.init) ?? "", row.checksum.isEmpty ? "" : "XXH64", row.checksum,
                row.role, row.targetID, row.targetName, String(row.required), row.root, row.relativePath, row.path, row.verification, row.verifiedAt,
                row.availability, String(row.verified), String(row.historical), row.error, row.message]
            return values.map(cell).joined(separator: ",")
        }
        return ([headers.map(cell).joined(separator: ",")] + lines).joined(separator: "\r\n") + "\r\n"
    }
    static func availability(_ value: String) -> String {
        switch value { case "accessible": "可访问，大小一致"; case "sizeChanged": "大小已变化"; case "wrongVolume": "磁盘身份不符"; case "notRecorded": "未记录副本"; default: "当前不可访问" }
    }
    static func evidence(_ value: String) -> String {
        switch value { case "sourceComparison": "与来源内容核对"; case "localReadback": "本地副本读回核对"; case "legacy": "旧记录，无完整核验依据"; default: "未核验" }
    }
    static func kind(_ value: String) -> String {
        switch value { case "original": "原文件"; case "proxy": "代理"; case "metadata": "拍摄信息"; default: "未保存" }
    }
    static func state(_ value: String) -> String {
        switch value { case "completed": "已结束"; case "running": "导入中"; case "cancelled": "已取消"; case "interrupted": "已中断"; default: "历史记录" }
    }
    static func size(_ value: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file) }
    static func rowProblem(_ row: HandoffReport.Row) -> String {
        if !row.error.isEmpty { return row.error }
        if !row.message.isEmpty { return row.message }
        if row.fileState != "saved" { return "文件未保存" }
        return row.verified ? availability(row.availability) : "缺少有效核验记录"
    }
    static let methods = """
    报告只涵盖所选项目的导入记录，不代表已扫描或完整拷贝整张存储卡。导入项可包含重复尝试；文件数、字节及已知时长按这些记录累计，不能当作项目去重统计。未记录的拍摄参数留空，不从当前偏好补写历史。源拍摄日期原文保留在 CaptureDateRaw，UTC 字段为导入时已解析的时间，不是机身时钟已经校准的证明。
    历史核验依据来自已保存的记录；导出时仅检查路径可读和文件大小，不重新计算素材内容校验值。同大小的内容变化无法由本次检查发现。离线目标保留过去的核验事实，但当前不可访问不等于可以完成交付。
    XXH64 是记录的素材校验算法；与来源内容核对、本地读回核对和旧记录分别列示。Wi-Fi 来源无法取得相机端源文件校验值，不按原卡端到端核对承诺。仅代理任务明确不包含原片。
    整理卷号为 MiniDiT 记录的卷号；卡档案编号不是存储卡硬件序列号。目标副本路径数量不代表物理磁盘独立性，也不代表异地备份。
    附带的 ASC MHL 目录保留可取得的历史链及清单，未修改其中的路径或校验事实。其相对路径基于原素材目标根目录，报告文件夹不包含素材；在素材根目录中使用兼容工具复核。清单不可取得时会明确列出，不重新编造。
    CSV 为 UTF-8，按实体文件的每个目标副本列行；Filename 为该文件实际名称，ImportItemFilename 为关联导入项名称，来源地址、来源预期大小和拍摄参数为该导入项记录。未保存文件及缺失目标也有行。为防表格软件把文本当作公式，危险起始字符添加单引号；原始字符串保存在 JSON 中。每次导出生成新报告 ID 和新目录，不覆盖旧报告。
    PDF 中的缩略图和抽帧从当前可访问且大小匹配的已记录副本生成，只用于识别素材。原片无法解码时可尝试代理并标明来源；无法读取时保留占位，不把缩略图当作核验结果。照片逐项分页，视频按已记录卷号分组并依次排列，不同视频留间隔，同一视频排满后换行，整份报告共用相同时间比例，无卷号时明确列为未记录卷号。
    本报告不执行画面、声音、同步、色彩或整卡目录结构 QC，也不自动授权清卡；整理人和备注为用户填写，不等于接收方签字。
    """
    static let readme = "打开 report.pdf 查看交接记录、照片缩略图与按卷号编排的视频胶片清单；files.csv 是完整文件与目标副本清单，manifest.json 保留结构化原始字段。\n\n" + methods
}
