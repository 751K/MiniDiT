import Foundation
import CoreGraphics
import CoreText
import ImageIO
import AVFoundation

/// Native, offline contact sheets. Previews are illustrations of recorded media, never a QC result.
public enum HandoffPDF {
    struct Item {
        var rows: [HandoffReport.Row]
        var row: HandoffReport.Row { rows.first! }
        var name: String { row.importItemFilename }
        var key: String { row.batchID + "|" + row.fileID }
        var video: Bool { row.media == "video" || ["mp4", "mov", "mxf", "m4v", "mts", "avi", "crm"].contains(URL(filePath: name).pathExtension.lowercased()) }
        var roll: String { row.roll.isEmpty ? "未记录卷号" : row.roll }
        var candidates: [HandoffReport.Row] {
            rows.filter { !$0.historical && $0.availability == "accessible" && $0.assetKind != "metadata" }
                .sorted { a, b in
                    let x = (a.assetKind == "original" ? 0 : 2) + (a.role == "working" ? 0 : 1)
                    let y = (b.assetKind == "original" ? 0 : 2) + (b.role == "working" ? 0 : 1)
                    return x == y ? a.path < b.path : x < y
                }
        }
    }
    static func items(_ report: HandoffReport) -> [Item] {
        var indices: [String: Int] = [:], result: [Item] = []
        for row in report.rows where !row.historical {
            let key = row.batchID + "|" + row.fileID
            if let index = indices[key] { result[index].rows.append(row) }
            else { indices[key] = result.count; result.append(Item(rows: [row])) }
        }
        return result.sorted { ($0.row.batchStarted, $0.row.capturedAt, $0.name, $0.row.fileID) < ($1.row.batchStarted, $1.row.capturedAt, $1.name, $1.row.fileID) }
    }
    static func stripWidth(duration: Double?, secondsPerLine: Double, available: CGFloat) -> CGFloat {
        let frameWidth = available * 5 / max(5, secondsPerLine)
        guard let duration, duration.isFinite, duration > 0 else { return frameWidth }
        // FCP-style browser thumbnails have a minimum frame width, including a partial final interval.
        return max(1, ceil(duration / 5)) * frameWidth
    }
    struct FilmSegment {
        var item: Int, line: Int
        var x: CGFloat, offset: CGFloat, width: CGFloat
    }
    static func filmLayout(widths: [CGFloat], lineWidth: CGFloat, clipGap: CGFloat = 6) -> [FilmSegment] {
        guard lineWidth > 0 else { return [] }
        var result: [FilmSegment] = [], x: CGFloat = 0, line = 0
        for (index, width) in widths.enumerated() {
            guard width.isFinite, width > 0 else { continue }
            // Separate files, while a continuation keeps its original offset and starts flush at the next line.
            if !result.isEmpty && x > 0 {
                if x + max(0, clipGap) >= lineWidth - 0.01 { x = 0; line += 1 }
                else { x += max(0, clipGap) }
            }
            var offset: CGFloat = 0
            while offset < width {
                if lineWidth - x < 0.01 { x = 0; line += 1 }
                let count = min(width - offset, lineWidth - x)
                result.append(.init(item: index, line: line, x: x, offset: offset, width: count))
                x += count; offset += count
            }
        }
        return result
    }
    public static func write(_ report: HandoffReport, to url: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) throws {
        let writer = try Writer(report: report, url: url, progress: progress)
        try writer.records()
        let all = items(report)
        try writer.photos(all.filter { !$0.video })
        var rolls: [String: [Item]] = [:], order: [String] = []
        for item in all where item.video {
            if rolls[item.roll] == nil { order.append(item.roll) }
            rolls[item.roll, default: []].append(item)
        }
        var durations: [String: Double] = [:]
        for item in all where item.video {
            try Task.checkCancellation()
            if let duration = writer.duration(item) { durations[item.key] = duration }
        }
        for roll in order { try writer.videos(rolls[roll]!, roll: roll, durations: durations) }
        try Task.checkCancellation()
        writer.finish()
        guard let pdf = CGPDFDocument(url as CFURL), pdf.numberOfPages == writer.page else { throw CocoaError(.fileWriteUnknown) }
    }

    private final class Writer {
        let report: HandoffReport, context: CGContext
        let progress: @Sendable (String) -> Void
        let width: CGFloat = 595.28, height: CGFloat = 841.89, margin: CGFloat = 40
        var y: CGFloat = 0, page = 0, section = "导入与备份记录"
        var videoStarted = false
        let ink = CGColor(gray: 0.12, alpha: 1), secondary = CGColor(gray: 0.40, alpha: 1)
        var contentWidth: CGFloat { width - margin * 2 }
        init(report: HandoffReport, url: URL, progress: @escaping @Sendable (String) -> Void) throws {
            self.report = report; self.progress = progress
            var box = CGRect(x: 0, y: 0, width: width, height: height)
            guard let context = CGContext(url as CFURL, mediaBox: &box, [kCGPDFContextTitle: report.projectName + " · 交接清单", kCGPDFContextCreator: "MiniDiT", kCGPDFContextAuthor: report.preparedBy] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
            self.context = context
        }
        func finish() { if page > 0 { context.endPDFPage() }; context.closePDF() }
        func newPage(_ name: String? = nil) throws {
            try Task.checkCancellation()
            if page > 0 { context.endPDFPage() }
            if let name { section = name }
            page += 1; context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            text("MiniDiT  /  交接清单", x: margin, top: 25, width: 245, size: 9, color: secondary)
            text(section, x: 310, top: 25, width: width - margin - 310, size: 9, color: secondary)
            rule(top: 43)
            rule(top: height - 36)
            text(report.projectName, x: margin, top: height - 28, width: contentWidth - 40, size: 8, color: secondary, maxHeight: 18)
            text(String(page), x: width - margin - 28, top: height - 28, width: 28, size: 8, color: secondary)
            y = 61
        }
        func attributes(size: CGFloat, bold: Bool, color: CGColor) -> [NSAttributedString.Key: Any] {
            let font = CTFontCreateWithName((bold ? "PingFangSC-Semibold" : "PingFangSC-Regular") as CFString, size, nil)
            return [NSAttributedString.Key(kCTFontAttributeName as String): font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
        }
        @discardableResult func text(_ value: String, x: CGFloat, top: CGFloat, width: CGFloat, size: CGFloat = 10, bold: Bool = false, color: CGColor? = nil, maxHeight: CGFloat = 10_000) -> CGFloat {
            let attrs = attributes(size: size, bold: bold, color: color ?? ink)
            var display = value
            func makeSetter(_ value: String) -> CTFramesetter { CTFramesetterCreateWithAttributedString(NSAttributedString(string: value, attributes: attrs)) }
            var setter = makeSetter(display)
            var measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            // Fixed contact-sheet captions visibly ellipsize; full names remain in the CSV.
            while measured.height + 3 > maxHeight && display.count > 1 {
                display.removeLast()
                setter = makeSetter(display + "…")
                measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
            }
            let h = min(maxHeight, ceil(measured.height) + 3)
            let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: x, y: height - top - h, width: width, height: h), transform: nil), nil)
            context.textMatrix = .identity; CTFrameDraw(frame, context)
            return h
        }
        func rule(top: CGFloat) {
            context.setStrokeColor(CGColor(gray: 0.86, alpha: 1)); context.setLineWidth(0.5)
            context.move(to: CGPoint(x: margin, y: height - top)); context.addLine(to: CGPoint(x: width - margin, y: height - top)); context.strokePath()
        }
        func space(_ h: CGFloat) throws { if y + h > height - 53 { try newPage() } }
        /// Text may span pages, including long paths and user notes; never silently clipped.
        func paragraph(_ value: String, size: CGFloat = 10, bold: Bool = false, color: CGColor? = nil) throws {
            var remaining = value[...]
            while !remaining.isEmpty {
                try space(24)
                let string = NSAttributedString(string: String(remaining), attributes: attributes(size: size, bold: bold, color: color ?? ink))
                let setter = CTFramesetterCreateWithAttributedString(string)
                let available = height - 54 - y
                let frame = CTFramesetterCreateFrame(setter, CFRange(), CGPath(rect: CGRect(x: margin, y: 54, width: contentWidth, height: available), transform: nil), nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { try newPage(); continue }
                let visibleText = (string.string as NSString).substring(with: NSRange(location: 0, length: visible.length))
                let h = text(visibleText, x: margin, top: y, width: contentWidth, size: size, bold: bold, color: color)
                y += h + 5
                remaining = String((string.string as NSString).substring(from: visible.length))[...]
                if !remaining.isEmpty { try newPage() }
            }
        }
        func heading(_ name: String) throws {
            try space(62); y += 13
            try paragraph(name, size: 15, bold: true); y += 3
        }
        func field(_ key: String, _ value: String) throws { if !value.isEmpty { try paragraph(key + "：" + value) } }
        func records() throws {
            try newPage()
            try paragraph(report.projectName, size: 27, bold: true)
            try paragraph("交接清单", size: 16)
            try paragraph(report.status, size: 11, bold: true)
            y += 8
            try field("导出时间（UTC）", HandoffReport.iso(report.createdAt))
            try field("报告编号", report.id.uuidString)
            try field("导出范围", report.scope)
            try field("整理人", report.preparedBy); try field("交接备注", report.notes)
            try paragraph("\(report.batches.count) 次导入  /  \(report.itemCount) 个导入项  /  \(report.assetCount) 个实体文件  /  \(HandoffPackage.size(report.bytes))", bold: true)
            try paragraph("实体文件包含原片、代理及 XML；多次导入按记录累计。", size: 9, color: secondary)
            try heading("导入记录")
            for batch in report.batches {
                try space(100)
                try paragraph("\(shortDate(batch.started))  ·  \(HandoffPackage.state(batch.state))", size: 12, bold: true)
                try field("导入时间（UTC）", batch.started + (batch.finished.isEmpty ? "" : " 至 " + batch.finished))
                try field("保存结果", "\(batch.saved) / \(batch.items) 个导入项，\(batch.assetCount) 个实体文件，\(HandoffPackage.size(batch.bytes))" + (batch.proxyOnly > 0 ? "；其中 \(batch.proxyOnly) 项仅导代理" : ""))
                let rows = report.rows.filter { $0.batchID == batch.id }
                try field("导入设备", Set(rows.map(\.source)).sorted().joined(separator: "、"))
                for root in Set(rows.filter { $0.role == "working" }.map(\.root)).sorted() { try field("导入位置", root) }
                try field("导入编号", batch.id)
                y += 6; rule(top: y); y += 8
            }
            try heading("备份记录")
            if report.targets.isEmpty { try paragraph("本次范围未配置额外备份目标。") }
            for target in report.targets {
                try space(95)
                try paragraph(target.name + (target.required ? "  ·  必需" : "  ·  可选"), size: 12, bold: true)
                try field("备份地址", target.root)
                try field("备份结果", "历史已校验 \(target.verified) / \(target.assets)，当前可访问 \(target.accessible) / \(target.assets)")
                let times = report.rows.filter { $0.batchID == target.batchID && $0.targetID == target.id && $0.verified }.map(\.verifiedAt).filter { !$0.isEmpty }.sorted()
                if let first = times.first, let last = times.last { try field("校验时间（UTC）", first == last ? first : first + " 至 " + last) }
                try field("导入编号", target.batchID)
                y += 6; rule(top: y); y += 8
            }
            let problems = report.rows.filter(\.needsAttention)
            if !report.issues.isEmpty || !problems.isEmpty || report.manifests.contains(where: { $0.status != "included" }) {
                try heading("待处理与未覆盖项")
                for issue in report.issues { try paragraph(issue) }
                for row in problems {
                    let problem = HandoffPackage.rowProblem(row), status = HandoffPackage.availability(row.availability)
                    try paragraph(row.filename + " · " + row.targetName + "：" + problem + (problem == status ? "" : "；" + status))
                }
                for manifest in report.manifests where manifest.status != "included" { try paragraph("校验材料未附入：" + manifest.original + "；" + manifest.status) }
            }
            try space(150)
            try heading("来源记录")
            var sourceGroups: [[HandoffReport.Source]] = [], sourceIndex: [String: Int] = [:]
            for source in report.sources {
                let key = [source.identifier, source.name, source.card, source.camera, source.serial, source.slot].joined(separator: "|")
                if let index = sourceIndex[key] { sourceGroups[index].append(source) }
                else { sourceIndex[key] = sourceGroups.count; sourceGroups.append([source]) }
            }
            for group in sourceGroups {
                try space(112)
                let source = group[0]
                try paragraph([source.name, source.card].filter { !$0.isEmpty }.joined(separator: " / "), bold: true)
                try field("相机", [source.camera, source.serial].filter { !$0.isEmpty }.joined(separator: " / "))
                try field("卡槽", source.slot == "0" ? "" : source.slot)
                try field("卡档案 / 来源标识", source.identifier)
                try field("卷号", Set(group.map(\.roll).filter { !$0.isEmpty }).sorted().joined(separator: "、"))
                try field("数量", "\(group.reduce(0) { $0 + $1.items }) 个导入项，\(group.reduce(0) { $0 + $1.assets }) 个实体文件，\(HandoffPackage.size(group.reduce(0) { $0 + $1.bytes }))")
            }
            for batch in report.batches where !batch.delivery.isEmpty {
                try heading("后期软件接收记录")
                for (app, message) in batch.delivery.sorted(by: { $0.key < $1.key }) { try field(app, message) }
            }
            try heading("校验清单")
            try paragraph("算法：XXH64。CSV 保留每个实体文件、每份目标副本的路径、校验值与核验记录。")
            for manifest in report.manifests { try paragraph(manifest.packagePath ?? ("未附入：" + manifest.original), size: 9, color: secondary) }
            try paragraph("导出时检查文件可读性及大小；本报告不重新核验内容。缩略图与视频抽帧仅用于识别素材，不表示已完成画面或声音 QC。详细范围说明见 README.txt。", size: 9, color: secondary)
        }
        func shortDate(_ value: String) -> String { String(value.prefix(19)).replacingOccurrences(of: "T", with: " ") }
        func photo(_ item: Item) throws -> CGImage? {
            for row in item.candidates {
                try Task.checkCancellation()
                if let source = CGImageSourceCreateWithURL(URL(filePath: row.path) as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                   let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 700, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) { return image }
            }
            return nil
        }
        func compressed(_ image: CGImage) -> CGImage {
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return image }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
            guard CGImageDestinationFinalize(destination), let provider = CGDataProvider(data: data as CFData),
                  let decoded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return image }
            return decoded
        }
        func image(_ image: CGImage?, rect: CGRect, message: String = "素材不可访问或无法生成预览") {
            let box = CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
            context.setFillColor(CGColor(gray: 0.96, alpha: 1)); context.fill(box)
            guard let image else {
                text(message, x: rect.minX + 10, top: rect.minY + rect.height / 2 - 8, width: rect.width - 20, size: 9, color: secondary)
                return
            }
            let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
            let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
            context.interpolationQuality = .high
            context.draw(compressed(image), in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h))
        }
        func photos(_ items: [Item]) throws {
            guard !items.isEmpty else { return }
            let gap: CGFloat = 12, cell = (contentWidth - gap * 3) / 4, tile: CGFloat = 153
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                progress("正在生成照片预览 \(index + 1) / \(items.count)…")
                if index % 16 == 0 {
                    try newPage("照片清单")
                    try paragraph("照片", size: 23, bold: true)
                    try paragraph("\(items.count) 个导入项  /  第 \(index + 1)-\(min(index + 16, items.count)) 项", size: 10, color: secondary)
                    y += 8
                }
                let col = index % 4, row = (index % 16) / 4
                let x = margin + CGFloat(col) * (cell + gap), top = y + CGFloat(row) * tile
                let preview = try autoreleasepool { try photo(item) }
                image(preview, rect: CGRect(x: x, y: top, width: cell, height: 82))
                var line = top + 89
                line += text(item.name, x: x, top: line, width: cell, size: 8.5, bold: true, maxHeight: 26)
                let asset = item.rows.first { $0.assetKind == "original" } ?? item.row
                let state = item.row.fileState == "saved" ? "" : "未保存 · "
                line += text(state + (asset.size.map(HandoffPackage.size) ?? "大小未记录"), x: x, top: line + 2, width: cell, size: 9, color: secondary)
            }
        }
        func duration(_ item: Item) -> Double? {
            if let seconds = item.row.durationSeconds, seconds.isFinite, seconds > 0 { return seconds }
            for row in item.candidates {
                let seconds = AVURLAsset(url: URL(filePath: row.path)).duration.seconds
                if seconds.isFinite && seconds > 0 { return seconds }
            }
            return nil
        }
        func frames(_ item: Item, fractions: [Double]) throws -> ([CGImage?], String) {
            for row in item.candidates {
                try Task.checkCancellation()
                let asset = AVURLAsset(url: URL(filePath: row.path))
                let seconds = asset.duration.seconds
                let duration = seconds.isFinite && seconds > 0 ? seconds : item.row.durationSeconds ?? 0
                let times: [Double] = duration > 0 ? fractions.map { min(duration * 0.999, duration * $0) } : [0]
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 540, height: 360)
                var result: [CGImage?] = []
                for time in times {
                    try Task.checkCancellation()
                    result.append(try? generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil))
                }
                generator.cancelAllCGImageGeneration()
                if result.contains(where: { $0 != nil }) { return (result, row.assetKind == "proxy" ? "预览来自代理" : "预览来自原片") }
            }
            return ([], "素材不可访问或无法解码")
        }
        func videos(_ items: [Item], roll: String, durations: [String: Double]) throws {
            let stripHeight: CGFloat = 37, secondsPerLine: Double = 40, frameSeconds: Double = 5
            let pointsPerSecond = contentWidth / secondsPerLine
            func pageHeader() throws {
                try newPage("视频清单")
                try paragraph("视频", size: 21, bold: true)
                videoStarted = true
            }
            if !videoStarted { try pageHeader() }
            if y + 110 > height - 53 { try pageHeader() }
            y += 12
            try paragraph("ROLL " + roll, size: 12, bold: true)
            y += 5
            let widths = items.map { HandoffPDF.stripWidth(duration: durations[$0.key], secondsPerLine: secondsPerLine, available: contentWidth) }
            let segments = HandoffPDF.filmLayout(widths: widths, lineWidth: contentWidth)
            let lines = Dictionary(grouping: segments, by: \.line)
            struct Caption { var x: CGFloat, width: CGFloat, height: CGFloat, lane: Int, text: String }
            for key in lines.keys.sorted() {
                try Task.checkCancellation()
                let parts = lines[key]!
                var captions: [Caption] = [], laneEnds: [CGFloat] = [], laneHeights: [CGFloat] = []
                for part in parts {
                    let name = items[part.item].name + (durations[items[part.item].key] == nil ? "（时长未知）" : "")
                    let attributed = NSAttributedString(string: name, attributes: attributes(size: 9, bold: false, color: ink))
                    let setter = CTFramesetterCreateWithAttributedString(attributed)
                    let natural = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil, CGSize(width: contentWidth, height: .greatestFiniteMagnitude), nil)
                    let w = min(contentWidth, ceil(natural.width) + 3), h = ceil(natural.height) + 3
                    let x = min(part.x, contentWidth - w)
                    var lane = 0
                    while lane < laneEnds.count && x < laneEnds[lane] + 5 { lane += 1 }
                    if lane == laneEnds.count { laneEnds.append(x + w); laneHeights.append(h) }
                    else { laneEnds[lane] = x + w; laneHeights[lane] = max(laneHeights[lane], h) }
                    captions.append(.init(x: x, width: w, height: h, lane: lane, text: name))
                }
                let rowHeight = stripHeight + 6 + laneHeights.reduce(0, +) + CGFloat(max(0, laneHeights.count - 1)) * 2 + 12
                if y + rowHeight > height - 53 {
                    try pageHeader(); try paragraph("ROLL " + roll, size: 12, bold: true); y += 5
                }
                let filmY = y
                for part in parts {
                    let item = items[part.item], fullWidth = widths[part.item]
                    let known = durations[item.key]
                    let startSeconds = Double(part.offset / pointsPerSecond)
                    let endSeconds = Double((part.offset + part.width) / pointsPerSecond)
                    let first = known == nil ? 0 : Int(floor(startSeconds / frameSeconds))
                    let last = known == nil ? 0 : max(first, Int(ceil(endSeconds / frameSeconds)) - 1)
                    let indices = Array(first...last)
                    let fractions = indices.map { frame -> Double in
                        guard let known else { return 0 }
                        let start = Double(frame) * frameSeconds
                        return min(0.999, (start + min(frameSeconds, max(0, known - start)) / 2) / known)
                    }
                    progress("正在生成 \(roll) · \(item.name)…")
                    let result = try autoreleasepool { try frames(item, fractions: fractions) }
                    let previews = result.0.map { $0.map(compressed) }
                    let box = CGRect(x: margin + part.x, y: height - filmY - stripHeight, width: part.width, height: stripHeight)
                    let left = part.offset > 0.01, right = part.offset + part.width < fullWidth - 0.01
                    let path = filmPath(box, continuesLeft: left, continuesRight: right)
                    context.saveGState(); context.addPath(path); context.clip()
                    context.setFillColor(CGColor(gray: 0.94, alpha: 1)); context.fill(box)
                    for (index, frameIndex) in indices.enumerated() {
                        guard index < previews.count, let preview = previews[index] else { continue }
                        let start = known == nil ? CGFloat(0) : CGFloat(frameIndex) * CGFloat(frameSeconds) * pointsPerSecond
                        let frameWidth = known == nil ? fullWidth : min(CGFloat(frameSeconds) * pointsPerSecond, fullWidth - start)
                        let frame = CGRect(x: box.minX - part.offset + start, y: box.minY, width: frameWidth, height: stripHeight)
                        context.saveGState(); context.clip(to: frame)
                        let scale = max(frame.width / CGFloat(preview.width), stripHeight / CGFloat(preview.height))
                        let w = CGFloat(preview.width) * scale, h = CGFloat(preview.height) * scale
                        context.draw(preview, in: CGRect(x: frame.midX - w / 2, y: frame.midY - h / 2, width: w, height: h))
                        context.restoreGState()
                        context.setStrokeColor(CGColor(gray: 0, alpha: 0.2)); context.setLineWidth(0.3)
                        context.move(to: CGPoint(x: frame.maxX, y: box.minY)); context.addLine(to: CGPoint(x: frame.maxX, y: box.maxY)); context.strokePath()
                    }
                    if previews.allSatisfy({ $0 == nil }) && box.width >= 60 {
                        text("无可用预览", x: box.minX + 5, top: filmY + 12, width: box.width - 10, size: 8, color: secondary)
                    }
                    if result.1 == "预览来自代理" && box.width >= 40 {
                        context.setFillColor(CGColor(gray: 0, alpha: 0.5))
                        context.fill(CGRect(x: box.maxX - 25, y: box.maxY - 14, width: 25, height: 14))
                        text("代理", x: box.maxX - 22, top: filmY + 2, width: 22, size: 7, color: CGColor(gray: 1, alpha: 1))
                    }
                    context.restoreGState()
                    context.setStrokeColor(CGColor(gray: 0.82, alpha: 1)); context.setLineWidth(0.5); context.addPath(path); context.strokePath()
                }
                for caption in captions {
                    let offset = laneHeights.prefix(caption.lane).reduce(0, +) + CGFloat(caption.lane) * 2
                    text(caption.text, x: margin + caption.x, top: filmY + stripHeight + 5 + offset, width: caption.width, size: 9)
                }
                y = filmY + rowHeight
            }
            y += 5
        }
        func filmPath(_ box: CGRect, continuesLeft: Bool, continuesRight: Bool) -> CGPath {
            let path = CGMutablePath(), depth: CGFloat = min(2.5, box.width / 4)
            let steps = 12
            path.move(to: CGPoint(x: box.minX + (continuesLeft ? depth : 0), y: box.maxY))
            path.addLine(to: CGPoint(x: box.maxX - (continuesRight ? depth : 0), y: box.maxY))
            if continuesRight {
                for i in 1...steps { path.addLine(to: CGPoint(x: box.maxX - (i % 2 == 0 ? depth : 0), y: box.maxY - CGFloat(i) * box.height / CGFloat(steps))) }
            } else { path.addLine(to: CGPoint(x: box.maxX, y: box.minY)) }
            path.addLine(to: CGPoint(x: box.minX + (continuesLeft ? depth : 0), y: box.minY))
            if continuesLeft {
                for i in 1...steps { path.addLine(to: CGPoint(x: box.minX + (i % 2 == 0 ? depth : 0), y: box.minY + CGFloat(i) * box.height / CGFloat(steps))) }
            } else { path.addLine(to: CGPoint(x: box.minX, y: box.maxY)) }
            path.closeSubpath(); return path
        }
    }
}
