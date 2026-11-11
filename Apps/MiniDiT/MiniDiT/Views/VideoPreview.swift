import AVKit
import Observation
import SonyRemoteKit
import SwiftUI

@MainActor @Observable
final class VideoPlayback {
    let player = AVPlayer()
    var position = 0.0
    var duration = 0.0
    var playing = false
    var loading = false
    var failure: String?
    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var generation = 0

    func load(_ url: URL) async {
        stop()
        let current = generation
        loading = true
        let asset = AVURLAsset(url: url)
        do {
            let (playable, length) = try await asset.load(.isPlayable, .duration)
            guard !Task.isCancelled, current == generation else { return }
            guard playable, length.seconds.isFinite, length.seconds > 0 else {
                loading = false; failure = "系统无法播放这个视频格式。可在剪辑软件中打开原片。"; return
            }
            duration = length.seconds
            let item = AVPlayerItem(asset: asset)
            statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, current == self.generation else { return }
                    if item.status == .failed { self.failure = item.error?.localizedDescription ?? "无法解码这个片段"; self.loading = false }
                    if item.status == .readyToPlay { self.loading = false }
                }
            }
            player.replaceCurrentItem(with: item)
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, current == self.generation, time.seconds.isFinite else { return }
                    self.position = time.seconds
                    self.playing = self.player.rate != 0
                }
            }
        } catch {
            guard !Task.isCancelled, current == generation else { return }
            loading = false; failure = "无法播放：\(error.localizedDescription)"
        }
    }

    func stop() {
        generation += 1
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil; statusObserver = nil
        player.replaceCurrentItem(with: nil)
        playing = false; position = 0; duration = 0; failure = nil; loading = false
    }

    func toggle() {
        guard player.currentItem != nil, failure == nil else { return }
        if player.rate != 0 { player.pause(); playing = false }
        else {
            if position >= duration - 0.03 { seek(0) }
            player.play(); playing = true
        }
    }

    func seek(_ seconds: Double) {
        guard seconds.isFinite, duration > 0 else { return }
        position = max(0, min(seconds, max(0, duration - 1.0 / 60000)))
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: position, preferredTimescale: 60000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(_ frames: Int, rate: Double) {
        player.pause(); playing = false
        seek(position + Double(frames) / max(1, rate))
    }
}

private struct NativeVideoView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

struct VideoPreviewSurface: View {
    @Environment(AppModel.self) private var model
    let url: URL
    let info: ClipInfo?
    @State private var exportingLivePhoto = false
    @State private var exportCenter = 0.0
    @State private var showingTimecode = false
    @State private var jump = ""
    @State private var jumpError: String?
    @FocusState private var editingTC: Bool
    private var playback: VideoPlayback { model.videoPlayback }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                NativeVideoView(player: playback.player)
                if playback.loading { ProgressView("正在准备播放…").tint(.white) }
                if let failure = playback.failure {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.title)
                        Text(failure).multilineTextAlignment(.center)
                        Button("用默认播放器打开") { NSWorkspace.shared.open(url) }.glassButton()
                    }
                    .padding(24).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            controls
        }
        .task(id: url) { await playback.load(url) }
        .onChange(of: model.previewLivePhotoShot, initial: true) { _, requested in
            guard let requested, requested == model.previewShot, model.previewVideoURL == url else { return }
            model.previewLivePhotoShot = nil
            exportCenter = 1.5
            exportingLivePhoto = true
        }
        .onDisappear { playback.stop() }
        .sheet(isPresented: $exportingLivePhoto) {
            let item = model.previewShot.flatMap { model.shots[$0] }.flatMap { model.item($0.primary) }
            LivePhotoExportSheet(source: url, name: item.map { URL(filePath: $0.filename).deletingPathExtension().lastPathComponent } ?? url.deletingPathExtension().lastPathComponent,
                center: exportCenter, marks: info?.shotMarks ?? [], markFrameRate: ClipInfo.fpsValue(info?.formatFps ?? "") ?? 25,
                capturedAt: item?.captureDate, isProxy: model.previewIsProxy)
        }
        .environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Button { playback.toggle() } label: {
                Image(systemName: playback.playing ? "pause.fill" : "play.fill")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .help("播放 / 暂停（空格）").accessibilityLabel(playback.playing ? "暂停" : "播放")
            HStack(spacing: 2) {
                Button { playback.step(-1, rate: ClipInfo.fpsValue(info?.formatFps ?? "") ?? 25) } label: {
                    Image(systemName: "backward.frame").frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .help("上一帧（←）").accessibilityLabel("上一帧")
                Button { playback.step(1, rate: ClipInfo.fpsValue(info?.formatFps ?? "") ?? 25) } label: {
                    Image(systemName: "forward.frame").frame(width: 24, height: 28).contentShape(Rectangle())
                }
                .help("下一帧（→）").accessibilityLabel("下一帧")
            }
            Slider(value: Binding(get: { playback.position }, set: { playback.seek($0) }), in: 0...max(0.01, playback.duration))
                .accessibilityLabel("视频播放位置")
            if model.previewIsProxy {
                Text("代理").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button {
                jumpError = nil
                jump = currentTimecode
                showingTimecode = true
            } label: {
                Text(currentTimecode).monospacedDigit().fixedSize()
                    .frame(height: 28).contentShape(Rectangle())
            }
            .disabled(info?.startTimecode == nil)
            .help(info?.startTimecode == nil ? "片段内时间（素材未提供时间码）" : "跳转到源时间码")
            .accessibilityLabel("当前时间码：\(currentTimecode)")
            .popover(isPresented: $showingTimecode) { timecodePopover }
            Button { playback.player.isMuted.toggle() } label: {
                Image(systemName: playback.player.isMuted ? "speaker.slash" : "speaker.wave.2")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .help("切换静音").accessibilityLabel("切换静音")
            Divider().frame(height: 18)
            if let marks = info?.shotMarks, !marks.isEmpty {
                Menu {
                    ForEach(Array(marks.enumerated()), id: \.offset) { _, mark in
                        let seconds = Double(mark.frame) / (ClipInfo.fpsValue(info?.formatFps ?? "") ?? 25)
                        Button("◆ \(mark.shotMark ?? 1) · \(info?.startTimecode?.adding(seconds: seconds).text ?? Self.elapsed(seconds))") { playback.seek(seconds) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bookmark")
                        Text("\(marks.count)").monospacedDigit()
                    }
                    .frame(height: 28).contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Shot Mark · \(marks.count)").accessibilityLabel("拍摄标记，共 \(marks.count) 个")
            }
            Menu {
                Button("导出实况照片…", systemImage: "livephoto") { exportLivePhoto() }
                    .disabled(playback.loading || playback.failure != nil || playback.duration < 0.5)
                Divider()
                Button("用默认播放器打开", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("导出实况照片…").accessibilityLabel("导出与打开")
        }
        .font(.system(size: 13))
        .buttonStyle(.plain)
        .padding(.horizontal, 14).padding(.vertical, 6)
        .frame(maxWidth: 760)
        .glassCapsule()
    }

    private var timecodePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("跳转到时间码").font(.headline)
            if let start = info?.startTimecode {
                HStack(spacing: 8) {
                    TextField("时间码", text: $jump)
                        .textFieldStyle(.roundedBorder).monospacedDigit()
                        .focused($editingTC).onSubmit { jumpToTimecode(start) }
                        .accessibilityLabel("跳转到源时间码")
                    Button("跳转") { jumpToTimecode(start) }.glassButton()
                }
                Text("\(start.text) – \(info?.endTimecode ?? start.text) · \(start.format)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let jumpError {
                Text(jumpError).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16).frame(width: 300)
        .onAppear { editingTC = true }
    }

    private func exportLivePhoto() {
        playback.player.pause()
        playback.playing = false
        let current = playback.player.currentTime().seconds
        exportCenter = current.isFinite ? current : playback.position
        exportingLivePhoto = true
    }

    private var currentTimecode: String { info?.startTimecode?.adding(seconds: playback.position).text ?? Self.elapsed(playback.position) }
    private static func elapsed(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }
    private func jumpToTimecode(_ start: VideoTimecode) {
        var input = jump.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.count == 8, input.allSatisfy(\.isNumber) {
            let d = Array(input)
            input = "\(String(d[0...1])):\(String(d[2...3])):\(String(d[4...5]))\(start.dropFrame ? ";" : ":")\(String(d[6...7]))"
        }
        guard let target = VideoTimecode(input, rate: start.rate), let offset = start.offset(to: target), offset < playback.duration else {
            jumpError = "请输入片段范围内的\(start.format)时间码：\(start.text) – \(info?.endTimecode ?? "")"; return
        }
        jumpError = nil; playback.seek(offset); editingTC = false; showingTimecode = false
    }
}
