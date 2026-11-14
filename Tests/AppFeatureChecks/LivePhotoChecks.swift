import AppKit
@preconcurrency import AVFoundation
import Foundation
import ImageIO
import MiniDiTCore
import Photos
import SonyRemoteKit
import SwiftUI
@testable import MiniDiT

private final class CancelExport: @unchecked Sendable {
    let lock = NSLock()
    var task: Task<LivePhotoExporter.Result, Error>?, requested = false
    func attach(_ task: Task<LivePhotoExporter.Result, Error>) {
        lock.lock(); self.task = task; let requested = requested; lock.unlock()
        if requested { task.cancel() }
    }
    func cancel() { lock.lock(); requested = true; let task = task; lock.unlock(); task?.cancel() }
}
private struct TimelineInputProbe: View {
    let editor: LivePhotoEditor
    var width: CGFloat = 512
    var body: some View {
        if let media = editor.media, let window = editor.window {
            LivePhotoTimeline(media: media, selection: window,
                setIn: editor.setIn, setOut: editor.setOut, setCover: editor.setCover)
                .frame(width: width).padding(24)
        }
    }
}
@main struct LivePhotoChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
        }
        app.run()
    }
    @MainActor static func runChecks() async throws {
        let app = NSApplication.shared, fm = FileManager.default
        if let index = CommandLine.arguments.firstIndex(of: "--single"), CommandLine.arguments.indices.contains(index + 1) {
            let source = URL(filePath: CommandLine.arguments[index + 1])
            let output = URL(filePath: "/tmp/minidit-live-real/" + UUID().uuidString)
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            let before = try await FileOps.hash(source)
            let info = try await LivePhotoExporter.inspect(source)
            let center = min(info.end - 0.2, info.start + info.duration / 2)
            let apple = try await LivePhotoExporter.export(source: source, center: center, format: .apple, directory: output, name: source.deletingPathExtension().lastPathComponent)
            let motion = try await LivePhotoExporter.export(source: source, center: center, format: .motion, directory: output, name: source.deletingPathExtension().lastPathComponent)
            let after = try await FileOps.hash(source); precondition(before == after)
            print("PASS: real local footage exports an Apple pair accepted by PHLivePhoto and a Motion Photo; source hash unchanged")
            print("APPLE_SAMPLE: " + apple.url.path); print("MOTION_SAMPLE: " + motion.url.path)
            return
        }
        let fixtures = URL(filePath: CommandLine.arguments.first(where: { $0.hasPrefix("/") && $0.hasSuffix("fixtures") }) ?? "/tmp/minidit-live-fixtures")
        let root = fm.temporaryDirectory.appending(path: "minidit-live-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if !CommandLine.arguments.contains("--keep") { try? fm.removeItem(at: root) } }
        var originalHashes: [String: UInt64] = [:]
        for file in ["source.mp4", "portrait.mov", "short.mp4", "tiny.mp4", "hlg.mp4"] { originalHashes[file] = try await FileOps.hash(fixtures.appending(path: file)) }
        let source = fixtures.appending(path: "source.mp4")
        let date = Date(timeIntervalSince1970: 1_735_786_245)
        let apple = try await LivePhotoExporter.export(source: source, center: 2.0, format: .apple, directory: root, name: "测试素材", capturedAt: date)
        let movie = try require(apple.video)
        let asset = AVURLAsset(url: movie)
        let length = try await asset.load(.duration).seconds
        precondition(abs(length - 3) < 0.05)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        precondition(audio.count == 1)
        let metadata = try await asset.load(.metadata)
        let identifierItem = try require(metadata.first { $0.identifier == .quickTimeMetadataContentIdentifier })
        let movieID = try await identifierItem.load(.stringValue)
        let image = try require(CGImageSourceCreateWithURL(apple.photo as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
        let maker = try require(properties[kCGImagePropertyMakerAppleDictionary] as? NSDictionary)
        precondition(maker["17"] as? String == movieID && movieID != nil)
        precondition(apple.capturedAt == date.addingTimeInterval(apple.window.sourcePoster))
        let metadataTracks = try await asset.loadTracks(withMediaType: .metadata)
        let metaTrack = try require(metadataTracks.first)
        let reader = try AVAssetReader(asset: asset), output = AVAssetReaderTrackOutput(track: metaTrack, outputSettings: nil)
        reader.add(output); let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
        precondition(reader.startReading())
        let group = try require(adaptor.nextTimedMetadataGroup())
        precondition(abs(group.timeRange.start.seconds - apple.window.poster) < 0.05)
        precondition(group.items.first?.key as? String == "com.apple.quicktime.still-image-time")
        reader.cancelReading()
        print("PASS: Apple pair is accepted by PHLivePhoto; shared image/movie ID, timed key-photo marker, three-second duration, AAC audio and captured date are present")
        let motion = try await LivePhotoExporter.export(source: source, center: 4.98, format: .motion, directory: root, name: "测试素材")
        let motionData = try Data(contentsOf: motion.url)
        let text = String(decoding: motionData, as: UTF8.self)
        let expression = try NSRegularExpression(pattern: #"Item:Length="([0-9]+)""#)
        let match = try require(expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let count = Int((text as NSString).substring(with: match.range(at: 1)))!
        precondition(text.contains("Camera:MotionPhoto=\"1\"") && text.contains("Camera:MotionPhotoVersion=\"1\""))
        precondition(text.contains("Item:Semantic=\"MotionPhoto\"") && motion.url.deletingPathExtension().lastPathComponent.hasSuffix("MP"))
        let tail = Data(motionData.suffix(count)), extracted = root.appending(path: "extracted.mp4")
        try tail.write(to: extracted)
        precondition(tail.count > 8 && String(decoding: tail[4..<8], as: UTF8.self) == "ftyp")
        let extractedDuration = try await AVURLAsset(url: extracted).load(.duration).seconds
        precondition(abs(extractedDuration - 3) < 0.05 && motion.window.sourcePoster < 5)
        let motionImage = try require(CGImageSourceCreateWithURL(motion.url as CFURL, nil))
        precondition(CGImageSourceCreateImageAtIndex(motionImage, 0, nil) != nil)
        let xmp = try require(CGImageSourceCopyMetadataAtIndex(motionImage, 0, nil))
        precondition(CGImageMetadataCopyStringValueWithPath(xmp, nil, "Camera:MotionPhoto" as CFString) as String? == "1")
        print("PASS: Motion Photo is a readable JPEG with native XMP camera/container fields; exact appended MP4 offset, playable audio/video and end-of-clip poster are valid")
        let explicit = try require(LivePhotoWindow(videoEnd: 5, selectionStart: 0.2, selectionEnd: 4.6, center: 2.2, frameRate: 25))
        let longer = try await LivePhotoExporter.export(source: source, center: 2.2, selection: explicit, format: .apple, directory: root, name: "自选范围", capturedAt: date)
        let longerMovie = try require(longer.video)
        let longerAsset = AVURLAsset(url: longerMovie)
        let longerDuration = try await longerAsset.load(.duration).seconds
        precondition(abs(longerDuration - 4.4) < 0.05)
        precondition(abs(longer.window.start - 0.2) < 0.00001 && abs(longer.window.sourcePoster - 2.2) < 0.00001)
        precondition(longer.capturedAt == date.addingTimeInterval(longer.window.sourcePoster))
        let longerTrack = try require(try await longerAsset.loadTracks(withMediaType: .metadata).first)
        let longerReader = try AVAssetReader(asset: longerAsset)
        let longerOutput = AVAssetReaderTrackOutput(track: longerTrack, outputSettings: nil)
        longerReader.add(longerOutput)
        let longerAdaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: longerOutput)
        precondition(longerReader.startReading())
        let longerMarker = try require(longerAdaptor.nextTimedMetadataGroup())
        precondition(abs(longerMarker.timeRange.start.seconds - 2) < 0.05)
        longerReader.cancelReading()
        let shorterWindow = try require(LivePhotoWindow(videoEnd: 5, selectionStart: 0.4, selectionEnd: 1.6, center: 1, frameRate: 25))
        let shorterMotion = try await LivePhotoExporter.export(source: source, center: 1, selection: shorterWindow, format: .motion, directory: root, name: "短范围")
        precondition(abs(shorterMotion.window.duration - 1.2) < 0.00001)
        let shorterData = try Data(contentsOf: shorterMotion.url)
        let shorterText = String(decoding: shorterData, as: UTF8.self)
        let shorterMatch = try require(expression.firstMatch(in: shorterText, range: NSRange(shorterText.startIndex..., in: shorterText)))
        let shorterCount = Int((shorterText as NSString).substring(with: shorterMatch.range(at: 1)))!
        let shorterMP4 = root.appending(path: "shorter-extracted.mp4")
        try Data(shorterData.suffix(shorterCount)).write(to: shorterMP4)
        let shorterDuration = try await AVURLAsset(url: shorterMP4).load(.duration).seconds
        precondition(abs(shorterDuration - 1.2) < 0.05)
        print("PASS: custom 4.4-second Apple Live Photo is accepted by PHLivePhoto; actual duration, key-photo marker and capture date match In/Out; custom 1.2-second Motion Photo contains the selected video range")

        let editor = LivePhotoEditor()
        await editor.load(source, center: 2)
        editor.setIn(0.8); editor.setOut(4.4); editor.setCover(3.2)
        let manualSelection = try require(editor.window)
        precondition(abs(manualSelection.start - 0.8) < 0.00001 && abs(manualSelection.end - 4.4) < 0.00001 && abs(manualSelection.sourcePoster - 3.2) < 0.00001)
        editor.selectMark(1); editor.setIn(0); editor.setOut(4.6)
        let firstMarkSelection = try require(editor.window)
        editor.selectMark(3); editor.setOut(2)
        precondition(editor.window!.sourcePoster < editor.window!.end)
        precondition(editor.window!.duration >= 0.5 - 0.00001)
        editor.selectMark(nil)
        precondition(editor.window == manualSelection)
        editor.selectMark(1)
        precondition(editor.window == firstMarkSelection && editor.window(for: 1) == firstMarkSelection)
        editor.setIn(100); editor.setOut(-100)
        precondition(editor.window!.duration >= 0.5 - 0.00001)
        precondition(editor.window!.sourcePoster >= editor.window!.start && editor.window!.sourcePoster < editor.window!.end)
        let beforeInvalid = editor.window
        editor.setCover(.nan)
        precondition(editor.window == beforeInvalid)
        editor.selectMark(nil)
        let firstID = try require(editor.activeSegmentID)
        let firstSelection = try require(editor.window)
        let secondID = try require(editor.addSegment())
        editor.setIn(0); editor.setOut(1.2); editor.setCover(0.6)
        let secondSelection = try require(editor.window)
        precondition(editor.segments.count == 2 && secondID != firstID)
        precondition(editor.manualSelections[0] == firstSelection && editor.manualSelections[1] == secondSelection)
        editor.selectSegment(firstID)
        precondition(editor.window == firstSelection)
        editor.selectMark(1)
        precondition(editor.addSegment() == nil)
        editor.selectMark(nil)
        precondition(editor.activeSegmentID == firstID && editor.window == firstSelection)
        editor.selectSegment(secondID)
        precondition(editor.window == secondSelection)
        var manualOutputs: [URL] = []
        for window in editor.manualSelections {
            let result = try await LivePhotoExporter.export(source: source, center: window.sourcePoster, selection: window, format: .apple,
                directory: root, name: "手动多片段", capturedAt: date)
            let duration = try await AVURLAsset(url: require(result.video)).load(.duration).seconds
            precondition(abs(duration - window.duration) < 0.05)
            precondition(result.window.sourcePoster == window.sourcePoster)
            manualOutputs.append(result.url)
        }
        precondition(manualOutputs.count == 2 && Set(manualOutputs).count == 2)
        editor.removeSegment(secondID)
        precondition(editor.activeSegmentID == firstID && editor.window == firstSelection)
        precondition(editor.segments.count == 1)
        editor.removeSegment(firstID)
        precondition(editor.segments.count == 1)
        precondition(manualOutputs.allSatisfy { fm.fileExists(atPath: $0.path) })
        print("PASS: two independent manual segments export two recognized Apple Live Photos with their own duration/cover; switching modes preserves both; removing a draft keeps generated files and one editable segment")
        editor.selectMark(nil)
        editor.setIn(1); editor.setOut(4); editor.setCover(2.5)
        if CommandLine.arguments.contains("--interaction") { try await checkTimelineInput(editor) }
        editor.stop()
        print("PASS: cover and endpoints edit independently, crossed handles are constrained, and manual/per-Shot-Mark selections survive switching")
        let portrait = try await LivePhotoExporter.export(source: fixtures.appending(path: "portrait.mov"), center: 0.04, format: .apple, directory: root, name: "竖屏")
        let portraitImage = try require(CGImageSourceCreateWithURL(portrait.photo as CFURL, nil))
        let portraitCG = try require(CGImageSourceCreateImageAtIndex(portraitImage, 0, nil))
        precondition(portraitCG.width == 180 && portraitCG.height == 320 && portrait.window.start == 0)
        let short = try await LivePhotoExporter.export(source: fixtures.appending(path: "short.mp4"), center: 0.4, format: .apple, directory: root, name: "短视频")
        precondition(abs(short.window.duration - 0.8) < 0.05)
        let hlg = try await LivePhotoExporter.export(source: fixtures.appending(path: "hlg.mp4"), center: 2, format: .motion, directory: root, name: "HLG")
        precondition(fm.fileExists(atPath: hlg.url.path))
        do { _ = try await LivePhotoExporter.export(source: fixtures.appending(path: "tiny.mp4"), center: 0, format: .apple, directory: root, name: "过短"); fatalError("undersized source accepted") }
        catch { precondition(error.localizedDescription.contains("0.5")) }
        print("PASS: portrait orientation, silent video, a short source, first-frame cover and 10-bit HLG input export; too-short inputs fail without publishing a file")
        let duplicate = try await LivePhotoExporter.export(source: source, center: 4.98, format: .motion, directory: root, name: "测试素材")
        precondition(duplicate.url != motion.url)
        let cancellationDirectory = root.appending(path: "cancel")
        try fm.createDirectory(at: cancellationDirectory, withIntermediateDirectories: true)
        let control = CancelExport()
        let cancelled = Task.detached {
            try await LivePhotoExporter.export(source: source, center: 2, format: .apple, directory: cancellationDirectory, name: "取消") { value in if value > 0.05 { control.cancel() } }
        }
        control.attach(cancelled)
        do { _ = try await cancelled.value; fatalError("cancelled output published") } catch { precondition(error is CancellationError, error.localizedDescription) }
        let cancelledFiles = try fm.contentsOfDirectory(atPath: cancellationDirectory.path)
        precondition(cancelledFiles.isEmpty)
        for (file, hash) in originalHashes { let after = try await FileOps.hash(fixtures.appending(path: file)); precondition(after == hash) }
        print("PASS: repeat exports preserve existing files; cancellation leaves no partial output; every source file hash is unchanged; no Photos library was modified")
        try await checkContextExportEntry(source: source, cover: apple.photo, root: root,
            interaction: CommandLine.arguments.contains("--interaction"))
        if CommandLine.arguments.contains("--render") {
            let output = URL(filePath: "/tmp/minidit-live-ui")
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            for dark in [false, true] {
                let marks = ClipInfo.parse(Data(#"<NonRealTimeMeta><KlvPacket frameCount="25" lengthValue="0A5F53686F744D61726B31"/><KlvPacket frameCount="75" lengthValue="0A5F53686F744D61726B32"/></NonRealTimeMeta>"#.utf8))!.shotMarks
                let view = LivePhotoExportSheet(source: source, name: "C0001", center: 2, marks: marks, markFrameRate: 25, capturedAt: date, isProxy: false)
                let host = NSHostingView(rootView: view.preferredColorScheme(dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 668, height: 620), styleMask: [.titled, .closable], backing: .buffered, defer: false)
                window.contentView = host; window.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .seconds(1)); host.layoutSubtreeIfNeeded()
                window.setContentSize(host.fittingSize); host.layoutSubtreeIfNeeded()
                let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: dark ? "export-dark.png" : "export.png"))
                window.orderOut(nil)
            }
        }
        if CommandLine.arguments.contains("--keep") { print("LIVE_SAMPLE: " + root.path) }
        _ = app
    }
    @MainActor static func checkContextExportEntry(source: URL, cover: URL, root: URL, interaction: Bool) async throws {
        let fm = FileManager.default, defaults = UserDefaults.standard
        let domain = ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        defaults.removePersistentDomain(forName: domain)
        let oldHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "context-history"))
        defer { ImportHistory.shared = oldHistory }
        let card = root.appending(path: "context-card")
        let clips = card.appending(path: "PRIVATE/M4ROOT/CLIP")
        let photos = card.appending(path: "DCIM/100MSDCF")
        try fm.createDirectory(at: clips, withIntermediateDirectories: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let movie = clips.appending(path: "C0001.MP4")
        try fm.copyItem(at: source, to: movie)
        try fm.copyItem(at: cover, to: photos.appending(path: "DSC00001.JPG"))
        let model = AppModel(startServices: false, journalURL: root.appending(path: "context-journal.sqlite"))
        model.autoRefresh = false; model.onlyNew = false
        model.sourceKind = .card; model.cardRoot = card; model.connectedName = "实况照片入口检查卡"
        model.library = LocalCardLibrary(root: card)
        await model.loadAll()
        let video = try require(model.allShots.first { $0.isVideo })
        let photo = try require(model.allShots.first { !$0.isVideo })
        let originalSelection = model.grid.selected
        model.openLivePhotoExport(photo.id)
        precondition(model.previewShot == nil && model.previewLivePhotoShot == nil)
        model.openLivePhotoExport(video.id)
        for _ in 0..<100 where model.previewVideoURL == nil { try await Task.sleep(for: .milliseconds(25)) }
        precondition(model.previewLivePhotoShot == video.id && model.previewShot == video.id)
        let resolved = try require(model.previewVideoURL)
        precondition(resolved.resolvingSymlinksInPath().path == movie.resolvingSymlinksInPath().path)
        precondition(model.grid.selected == originalSelection && model.currentSessionID == nil)
        precondition(model.importJournal.batches.isEmpty && model.importTask == nil)
        model.closePreview()
        precondition(model.previewLivePhotoShot == nil)
        model.openLivePhotoExport(video.id)
        model.openPreview(photo.id)
        precondition(model.previewLivePhotoShot == nil && model.previewShot == photo.id)
        model.closePreview()
        if interaction {
            model.openLivePhotoExport(video.id)
            for _ in 0..<100 where model.previewVideoURL == nil { try await Task.sleep(for: .milliseconds(25)) }
            let url = try require(model.previewVideoURL)
            let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 860, height: 620),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let host = NSHostingView(rootView: VideoPreviewSurface(url: url, info: model.clipInfos[video.primary]).environment(model))
            window.contentView = host; window.makeKeyAndOrderFront(nil); window.becomeKey()
            defer {
                if let sheet = window.sheets.first { window.endSheet(sheet) }
                window.orderOut(nil); model.closePreview()
            }
            for _ in 0..<100 {
                if model.previewLivePhotoShot == nil && !window.sheets.isEmpty { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            precondition(model.previewLivePhotoShot == nil && window.sheets.count == 1,
                "Context entry did not present the Live Photo editor when local media was ready")
            precondition(model.importJournal.batches.isEmpty && model.grid.selected == originalSelection)
        }
        model.closePreview()
        print("PASS: source-grid Live Photo entry resolves the clicked video, presents the editor, preserves selection, requires no project, starts no import, and clears pending requests on close/switch; photos are rejected")
    }
    @MainActor static func checkTimelineInput(_ editor: LivePhotoEditor) async throws {
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 560, height: 96),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: TimelineInputProbe(editor: editor))
        window.contentView = host
        NSApplication.shared.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(250))
        host.layoutSubtreeIfNeeded()
        window.becomeKey()
        let media = try require(editor.media)
        let width = 484.0
        func point(_ seconds: Double, cover: Bool = false, offset: Double = 0) -> NSPoint {
            NSPoint(x: 38 + (seconds - media.start) / media.duration * width + offset,
                    y: host.bounds.height - 24 - (cover ? 36 : 16))
        }
        func send(_ kind: NSEvent.EventType, _ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: kind, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: kind == .leftMouseUp ? 0 : 1)!
            NSApplication.shared.sendEvent(event)
        }
        func drag(_ from: NSPoint, _ to: NSPoint) async throws {
            send(.leftMouseDown, from)
            for step in 1...12 {
                let fraction = Double(step) / 12
                send(.leftMouseDragged, NSPoint(x: from.x + (to.x - from.x) * fraction, y: to.y))
                try await Task.sleep(for: .milliseconds(5))
            }
            send(.leftMouseUp, to)
            try await Task.sleep(for: .milliseconds(100))
        }
        try await drag(point(editor.window!.start, offset: -6), point(0.5, offset: -6))
        precondition(abs(editor.window!.start - 0.5) < 0.06, "In handle did not follow native mouse drag")
        precondition(abs(editor.window!.sourcePoster - 2.5) < 0.06)
        try await drag(point(editor.window!.end, offset: 6), point(4.6, offset: 6))
        precondition(abs(editor.window!.end - 4.6) < 0.06, "Out handle did not follow native mouse drag")
        let beforeCoverDrag = editor.window!
        try await drag(point(editor.window!.sourcePoster, cover: true), point(3.2, cover: true))
        precondition(abs(editor.window!.sourcePoster - 3.2) < 0.06, "Cover handle did not follow native mouse drag")
        precondition(editor.window!.start == beforeCoverDrag.start && editor.window!.end == beforeCoverDrag.end)
        editor.setIn(2); editor.setOut(2.52); editor.setCover(2.2)
        let narrowHost = NSHostingView(rootView: TimelineInputProbe(editor: editor, width: 120))
        window.contentView = narrowHost
        window.setContentSize(NSSize(width: 168, height: 96))
        try await Task.sleep(for: .milliseconds(150))
        narrowHost.layoutSubtreeIfNeeded()
        func narrowPoint(_ seconds: Double, offset: Double) -> NSPoint {
            NSPoint(x: 38 + (seconds - media.start) / media.duration * 92 + offset, y: 56)
        }
        try await drag(narrowPoint(editor.window!.start, offset: -6), narrowPoint(1, offset: -6))
        precondition(abs(editor.window!.start - 1) < 0.06, "In handle was obscured in a narrow range")
        try await drag(narrowPoint(editor.window!.end, offset: 6), narrowPoint(4, offset: 6))
        precondition(abs(editor.window!.end - 4) < 0.06, "Out handle was obscured in a narrow range")
        print("PASS: native mouse drags move In, Out and cover independently; short highlighted ranges keep both endpoints reachable")
    }
    static func require<T>(_ value: T?) throws -> T { guard let value else { throw LivePhotoExporter.Failure("Required test value missing") }; return value }
}
