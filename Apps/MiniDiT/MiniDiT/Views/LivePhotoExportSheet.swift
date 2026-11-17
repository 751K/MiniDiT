import AppKit
@preconcurrency import AVKit
import MiniDiTCore
import Observation
@preconcurrency import Photos
import SonyRemoteKit
import SwiftUI

@MainActor @Observable final class LivePhotoEditor {
    let player = AVPlayer()
    var media: LivePhotoExporter.Media?
    var window: LivePhotoWindow?
    var activeMark: Double?
    struct Segment: Identifiable {
        let id = UUID()
        var window: LivePhotoWindow
    }
    private(set) var segments: [Segment] = []
    private(set) var activeSegmentID: UUID?
    var activeSegmentIndex: Int? { segments.firstIndex { $0.id == activeSegmentID } }
    var manualSelections: [LivePhotoWindow] { segments.map(\.window) }
    @ObservationIgnored private var markWindows: [Double: LivePhotoWindow] = [:]
    var playing = false
    var problem: String?
    var posterImage: NSImage?
    @ObservationIgnored private var posterTask: Task<Void, Never>?
    @ObservationIgnored private var sourceURL: URL?
    @ObservationIgnored private var posterGeneration = 0
    @ObservationIgnored private var observer: Any?
    func load(_ url: URL, center: Double) async {
        do {
            let media = try await LivePhotoExporter.inspect(url)
            try Task.checkCancellation()
            self.sourceURL = url
            self.media = media
            window = LivePhotoWindow(videoStart: media.start, videoEnd: media.end, center: center, frameRate: media.frameRate)
            if let window {
                let first = Segment(window: window)
                segments = [first]
                activeSegmentID = first.id
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            seekCover()
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, self.playing, let window = self.window else { return }
                    if time.seconds >= window.end - 0.025 { self.player.pause(); self.playing = false; self.seekCover() }
                }
            }
        } catch is CancellationError {} catch { problem = error.localizedDescription }
    }
    func window(for mark: Double) -> LivePhotoWindow? {
        guard let media else { return nil }
        return markWindows[mark] ?? LivePhotoWindow(videoStart: media.start, videoEnd: media.end, center: mark, frameRate: media.frameRate)
    }
    func selectMark(_ mark: Double?) {
        activeMark = mark
        window = mark.flatMap { window(for: $0) } ?? activeSegmentIndex.map { segments[$0].window }
        seekCover()
    }
    func selectSegment(_ id: UUID) {
        guard let segment = segments.first(where: { $0.id == id }) else { return }
        activeMark = nil
        activeSegmentID = id
        window = segment.window
        seekCover()
    }
    @discardableResult func addSegment() -> UUID? {
        guard activeMark == nil, let window else { return nil }
        let segment = Segment(window: window)
        segments.append(segment)
        selectSegment(segment.id)
        return segment.id
    }
    func removeSegment(_ id: UUID) {
        guard activeMark == nil, segments.count > 1,
              let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments.remove(at: index)
        if activeSegmentID == id { selectSegment(segments[min(index, segments.count - 1)].id) }
    }
    func setCover(_ seconds: Double) {
        guard let window else { return }
        update(start: window.start, end: window.end, cover: seconds)
    }
    func setIn(_ seconds: Double) {
        guard let media, let window else { return }
        update(start: max(media.start, min(seconds, window.end - 0.5)), end: window.end, cover: window.sourcePoster)
    }
    func setOut(_ seconds: Double) {
        guard let media, let window else { return }
        update(start: window.start, end: min(media.end, max(seconds, window.start + 0.5)), cover: window.sourcePoster)
    }
    private func update(start: Double, end: Double, cover: Double) {
        guard let media, let selected = LivePhotoWindow(videoStart: media.start, videoEnd: media.end,
            selectionStart: start, selectionEnd: end, center: cover, frameRate: media.frameRate) else { return }
        window = selected
        if let activeMark {
            markWindows[activeMark] = selected
        } else if let index = activeSegmentIndex {
            segments[index].window = selected
        }
        seekCover()
    }
    func seekCover() {
        player.pause(); playing = false
        guard let window else { return }
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: window.end, preferredTimescale: 60000)
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: window.sourcePoster, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        posterTask?.cancel(); posterGeneration += 1
        let generation = posterGeneration
        guard let sourceURL else { return }
        posterTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(120))
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: sourceURL))
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 1200, height: 800)
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                let result = try await generator.image(at: CMTime(seconds: window.sourcePoster, preferredTimescale: 60000))
                guard !Task.isCancelled, posterGeneration == generation else { return }
                posterImage = NSImage(cgImage: result.image, size: .zero)
            } catch {}
        }
    }
    func toggle() {
        if playing { seekCover(); return }
        guard let window else { return }
        player.seek(to: CMTime(seconds: window.start, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); playing = true
    }
    func stop() {
        posterTask?.cancel(); posterGeneration += 1; sourceURL = nil; posterImage = nil
        if let observer { player.removeTimeObserver(observer) }; observer = nil
        player.pause(); player.replaceCurrentItem(with: nil); playing = false
    }
}
private struct LivePhotoPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .none; view.videoGravity = .resizeAspect; view.player = player; return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct LivePhotoExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let source: URL
    let name: String
    let center: Double
    let marks: [ClipInfo.Mark]
    let markFrameRate: Double
    let capturedAt: Date?
    let isProxy: Bool
    @State private var editor = LivePhotoEditor()
    @State private var format: LivePhotoExporter.Format = .apple
    @State private var allMarks = false
    @State private var exporting = false
    @State private var committing = false
    @State private var progress = 0.0
    @State private var task: Task<Void, Never>?
    @State private var outputs: [URL] = []
    @State private var savedToPhotos = false
    @State private var problem: String?
    private var markCenters: [Double] {
        guard let media = editor.media else { return [] }
        return Set(marks.map { Double($0.frame) / max(1, markFrameRate) }.filter { $0 >= media.start && $0 < media.end }).sorted()
    }
    private var selections: [LivePhotoWindow] {
        allMarks ? markCenters.compactMap { editor.window(for: $0) } : editor.manualSelections
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("导出实况照片").font(Theme.Font.title)
                Spacer()
                Text(name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            LivePhotoPlayer(player: editor.player).frame(height: 240)
                .overlay { if !editor.playing, let image = editor.posterImage { Image(nsImage: image).resizable().scaledToFit() } }
                .background(.black, in: RoundedRectangle(cornerRadius: 10)).clipShape(RoundedRectangle(cornerRadius: 10))
            if savedToPhotos || !outputs.isEmpty && !exporting && problem == nil {
                Text(savedToPhotos ? "已存入“照片”。" : "已导出 \(outputs.count) 张实况照片。")
                HStack {
                    if savedToPhotos { Button("打开照片") { Task { _ = try? await NSWorkspace.shared.openApplication(at: URL(filePath: "/System/Applications/Photos.app"), configuration: .init()) } } }
                    else { Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting(outputs) } }
                    Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            } else {
                VStack(alignment: .leading, spacing: 18) {
                    coverControls
                    exportOptions
                }.disabled(exporting)
                if let message = problem ?? editor.problem { Text(message).foregroundStyle(Theme.warning).textSelection(.enabled) }
                if !outputs.isEmpty && problem != nil { Button("显示已完成的文件") { NSWorkspace.shared.activateFileViewerSelecting(outputs) } }
                HStack {
                    if exporting { ProgressView(value: progress).frame(width: 120); Text(committing ? "正在存入照片…" : "正在导出…").foregroundStyle(.secondary) }
                    Spacer()
                    Button(exporting ? "取消导出" : "取消") {
                        if let task { task.cancel() } else { dismiss() }
                    }.keyboardShortcut(.cancelAction).disabled(committing)
                    if format == .apple {
                        Button("存入照片") { start(toPhotos: true) }.disabled(exporting || editor.window == nil)
                    }
                    Button(selections.count > 1 ? "导出 \(selections.count) 张…" : "导出…") { start(toPhotos: false) }.keyboardShortcut(.defaultAction).disabled(exporting || editor.window == nil)
                }
            }
        }
        .padding(24).frame(width: 560).background(Theme.surface)
        .interactiveDismissDisabled(exporting)
        .onChange(of: allMarks) { _, enabled in
            editor.selectMark(enabled ? markCenters.first : nil)
        }
        .task { await editor.load(source, center: center) }
        .onDisappear { task?.cancel(); editor.stop() }
    }
    @ViewBuilder private var coverControls: some View {
        if let media = editor.media, let window = editor.window {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if allMarks {
                        Picker("预览标记", selection: Binding(get: { editor.activeMark ?? markCenters.first ?? 0 }, set: { editor.selectMark($0) })) {
                            ForEach(Array(markCenters.enumerated()), id: \.offset) { index, time in
                                Text("Shot Mark \(index + 1) · \(time, specifier: "%.2f") 秒").tag(time)
                            }
                        }
                        .labelsHidden()
                    } else {
                        segmentMenu
                    }
                    Text("\(window.duration, specifier: "%.2f") 秒")
                        .monospacedDigit().foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(editor.playing ? "停止" : "预览") { editor.toggle() }
                        .buttonStyle(.bordered)
                        .help(editor.playing ? "停止预览" : "预览所选片段")
                }
                LivePhotoTimeline(media: media, selection: window,
                    setIn: editor.setIn, setOut: editor.setOut, setCover: editor.setCover)
                HStack {
                    Text(String(format: "In %.2f", window.start))
                    Spacer()
                    Text("封面 \(window.sourcePoster, specifier: "%.2f")")
                    Spacer()
                    Text(String(format: "Out %.2f", window.end))
                }
                .font(Theme.Font.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        } else if editor.problem == nil {
            ProgressView("正在读取视频…")
        }
    }

    private var segmentMenu: some View {
        Menu {
            ForEach(Array(editor.segments.enumerated()), id: \.element.id) { index, segment in
                Button {
                    editor.selectSegment(segment.id)
                } label: {
                    let title = String(localized: "片段 \(index + 1) · \(segment.window.start, specifier: "%.2f")–\(segment.window.end, specifier: "%.2f") 秒")
                    if segment.id == editor.activeSegmentID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
            Divider()
            Button("添加片段", systemImage: "plus") { editor.addSegment() }
            Button("移除当前片段") {
                if let id = editor.activeSegmentID { editor.removeSegment(id) }
            }
            .disabled(editor.segments.count <= 1)
        } label: {
            Text(editor.segments.count > 1
                ? "片段 \((editor.activeSegmentIndex ?? 0) + 1) / \(editor.segments.count)"
                : "片段 1")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .accessibilityLabel("选择手动片段")
    }

    private var exportOptions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("格式")
                Spacer()
                Picker("格式", selection: $format) {
                    ForEach(LivePhotoExporter.Format.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 230, alignment: .trailing)
            }
            if !markCenters.isEmpty {
                HStack(spacing: 10) {
                    Text("按 Shot Mark 批量导出")
                    Spacer()
                    Text("\(markCenters.count) 张").foregroundStyle(.secondary)
                    Toggle("按 Shot Mark 批量导出", isOn: $allMarks)
                        .labelsHidden().toggleStyle(.switch).controlSize(.mini).fixedSize()
                }
            }
            if isProxy {
                Text("当前使用代理视频，导出画质以代理为准。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private func start(toPhotos: Bool) {
        let directory: URL
        if toPhotos { directory = FileManager.default.temporaryDirectory.appending(path: "MiniDiT-LivePhoto-" + UUID().uuidString) }
        else { guard let selected = FolderPicker.choose(start: nil) else { return }; directory = selected }
        let windows = selections, chosen = format
        guard !windows.isEmpty else { return }
        exporting = true; problem = nil; progress = 0; outputs = []; editor.seekCover()
        task = Task {
            defer { exporting = false; committing = false; task = nil; if toPhotos { try? FileManager.default.removeItem(at: directory) } }
            do {
                if toPhotos {
                    guard try await LivePhotoLibrary.canAdd() else { throw LivePhotoExporter.Failure(String(localized: "未获得添加照片的权限。可改为导出文件，或在系统设置中允许 MiniDiT 添加照片。")) }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                }
                var generated: [LivePhotoExporter.Result] = []
                for (index, window) in windows.enumerated() {
                    try Task.checkCancellation()
                    let worker = Task.detached(priority: .userInitiated) {
                        try await LivePhotoExporter.export(source: source, center: window.sourcePoster, selection: window, format: chosen, directory: directory, name: name, capturedAt: capturedAt) { fraction in
                            Task { @MainActor in progress = (Double(index) + fraction) / Double(windows.count) }
                        }
                    }
                    let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                    generated.append(result)
                    if !toPhotos { outputs.append(result.url) }
                }
                if toPhotos {
                    try Task.checkCancellation(); committing = true
                    try await LivePhotoLibrary.add(generated)
                    savedToPhotos = true
                }
            } catch is CancellationError {
                problem = outputs.isEmpty ? String(localized: "已取消导出。") : String(localized: "已取消，其余文件未导出；已完成的 \(outputs.count) 张保留在所选文件夹。")
                // Keep the editor open after a partial batch, with a visible result link below the error.
            } catch { problem = String(localized: "导出未完成：\(error.localizedDescription)") }
        }
    }
}

/// Source-wide timeline: independent In, key-photo and Out handles.
struct LivePhotoTimeline: View {
    let media: LivePhotoExporter.Media
    let selection: LivePhotoWindow
    let setIn: (Double) -> Void
    let setOut: (Double) -> Void
    let setCover: (Double) -> Void
    @State private var dragging: Handle?
    @State private var dragOffset = 0.0

    private enum Handle { case start, cover, end }
    private let inset = 14.0

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - inset * 2)
            let start = x(selection.start, width: width)
            let end = x(selection.end, width: width)
            ZStack(alignment: .topLeading) {
                Capsule().fill(.primary.opacity(0.15))
                    .frame(width: width, height: 5).offset(x: inset, y: 21.5)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Theme.accent.opacity(0.18))
                    .frame(width: max(2, end - start), height: 26).offset(x: start, y: 11)
                Rectangle().fill(Theme.accent)
                    .frame(width: max(2, end - start), height: 3).offset(x: start, y: 22.5)
                // The cover handle sits below the endpoints so all three remain reachable
                // even when a short selection is a small part of a long source.
                handle(.start, at: selection.start, width: width)
                handle(.end, at: selection.end, width: width)
                handle(.cover, at: selection.sourcePoster, width: width)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: "livePhotoTimeline")
        }
        .frame(height: 48)
    }

    private func x(_ time: Double, width: Double) -> Double {
        inset + max(0, min(1, (time - media.start) / media.duration)) * width
    }
    private func time(_ location: Double, width: Double) -> Double {
        media.start + max(0, min(1, (location - inset) / width)) * media.duration
    }
    private func update(_ handle: Handle, _ time: Double) {
        switch handle {
        case .start: setIn(time)
        case .cover: setCover(time)
        case .end: setOut(time)
        }
    }
    private func label(_ handle: Handle) -> String {
        switch handle {
        case .start: String(localized: "In 入点")
        case .cover: String(localized: "封面")
        case .end: String(localized: "Out 出点")
        }
    }
    private func handle(_ handle: Handle, at value: Double, width: Double) -> some View {
        ZStack {
            if handle == .cover {
                Capsule().fill(.primary).frame(width: 2, height: 22).offset(y: -5)
                Circle().fill(.primary).frame(width: 12, height: 12).offset(y: 6)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            } else {
                Capsule().fill(Theme.accent).frame(width: 3, height: 26)
                Image(systemName: handle == .start ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.accent)
                    .offset(x: handle == .start ? -5 : 5)
            }
        }
        .offset(x: handle == .start ? 12 : handle == .end ? -12 : 0, y: handle == .cover ? 0 : 8)
        .frame(width: handle == .cover ? 28 : 24, height: handle == .cover ? 24 : 32)
        .contentShape(Rectangle())
        // Endpoint hit areas extend away from the selection, so In and Out do
        // not compete for the same pointer hit when the highlighted range is tiny.
        .position(x: x(value, width: width) + (handle == .start ? -12 : handle == .end ? 12 : 0),
                  y: handle == .cover ? 36 : 16)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("livePhotoTimeline"))
            .onChanged { gesture in
                if dragging != handle {
                    dragging = handle
                    dragOffset = gesture.startLocation.x - x(value, width: width)
                }
                update(handle, time(gesture.location.x - dragOffset, width: width))
            }
            .onEnded { _ in dragging = nil })
        .help(label(handle))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label(handle))
        .accessibilityValue(String(localized: "\(value, specifier: "%.2f") 秒"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: update(handle, value + 1 / media.frameRate)
            case .decrement: update(handle, value - 1 / media.frameRate)
            @unknown default: break
            }
        }
        .focusable()
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            update(handle, value + (press.key == .rightArrow ? 1 : -1) / media.frameRate)
            return .handled
        }
    }
}

@MainActor enum LivePhotoLibrary {
    static func canAdd() async throws -> Bool {
        try Task.checkCancellation()
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if status == .authorized { return true }
        guard status == .notDetermined else { return false }
        let authorized = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        try Task.checkCancellation()
        return authorized == .authorized
    }
    static func add(_ results: [LivePhotoExporter.Result]) async throws {
        guard !results.isEmpty, results.allSatisfy({ $0.video != nil }) else { throw LivePhotoExporter.Failure(String(localized: "实况照片文件不完整，未写入照片图库。")) }
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else { throw LivePhotoExporter.Failure(String(localized: "未获得添加照片的权限，未写入照片图库。")) }
        try await PHPhotoLibrary.shared().performChanges {
            for result in results {
                let request = PHAssetCreationRequest.forAsset()
                request.creationDate = result.capturedAt
                let photoOptions = PHAssetResourceCreationOptions(), videoOptions = PHAssetResourceCreationOptions()
                photoOptions.originalFilename = result.url.lastPathComponent + ".JPG"
                videoOptions.originalFilename = result.url.lastPathComponent + ".MOV"
                request.addResource(with: .photo, fileURL: result.photo, options: photoOptions)
                request.addResource(with: .pairedVideo, fileURL: result.video!, options: videoOptions)
            }
        }
    }
}
