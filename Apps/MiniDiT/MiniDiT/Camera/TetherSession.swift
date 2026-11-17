import AppKit
import Foundation
import ImageIO
import Observation
import SonyRemoteKit

/// 联机拍摄：通过 Wi-Fi 遥控索尼相机（PC 遥控），取景、调参数、拍摄；拍好的照片先下到本机的联机缓存，
/// 再由 AppModel 当作一张「存储卡」交给平常的导入流程（命名、备份、Capture One / Lightroom 都照旧）。
@MainActor @Observable
final class TetherSession {
    let cameraName: String
    let spool: TetherSpool
    private let camera: SonyCamera

    var status = CameraStatus()
    var liveFrame: NSImage?
    /// 最近一帧取景的 JPEG 原始数据（给 agent 用）。
    @ObservationIgnored var liveFrameData: Data?
    /// 取景计时：最近的帧各自的取帧耗时（毫秒）、字节数和到达时间，算帧率和耗时（tether.status 的 liveViewStats）。
    @ObservationIgnored var liveSamples: [(at: Date, fetchMs: Double, bytes: Int)] = []
    @ObservationIgnored var liveSize: CGSize = .zero
    /// 两次取帧之间的等待（毫秒），可用 tetherLiveViewDelayMs 覆盖。α7 V 实测：相机约每 40 毫秒（25 帧/秒）出一帧，
    /// 请求会等到下一帧才返回（Wi-Fi 下取一帧 1024×680、约 65 KB，约 23 毫秒）。等 50 毫秒时每次都错过一帧，只有 10–12 帧/秒；
    /// 等 10 毫秒能跟上 25 帧/秒；完全不等也是 25 帧/秒，但连接一直被取景占着，拍照、读属性要排更久的队，偶尔一帧要 200 毫秒。
    static var liveDelayMs: Int { (UserDefaults.standard.object(forKey: "tetherLiveViewDelayMs") as? Int) ?? 10 }
    var liveViewOn = true { didSet { if liveViewOn != oldValue { restartLiveView() } } }
    var shooting = false
    var downloading = false
    var focusLocked = false
    /// 最近一次点按取景画面的位置（0…1，相对取景画面）；取消触摸或断开后为 nil。
    var touchPoint: CGPoint?
    /// 调焦：正在拖动或拉焦时的目标位置（界面先显示它，相机回报跟上后清掉）。
    var focusTarget: Int64?
    /// 记下的对焦点（A、B），本次联机内有效。
    var focusMarks: [String: Int64] = [:]
    @ObservationIgnored var focusPending: Int64?
    @ObservationIgnored var focusSending = false
    @ObservationIgnored var focusGeneration = 0
    @ObservationIgnored var pullTask: Task<Void, Never>?
    /// 跟焦位置 ↔ 距离换算表（录像模式、镜头支持时从相机读一次）。
    var distanceTable: LensDistanceTable?
    @ObservationIgnored var distanceTableState = 0   // 0 未读、1 读取中、2 读过（成功或失败都不再重试，换模式后重置）
    /// 相机随取景送来的对焦框、人脸框、跟踪框。
    var focalFrames: FocalFrameInfo?
    /// 相机断开了（关机、离开网络）。缓存里已有的照片仍在。
    var lost = false
    var message: String?
    var lastShot: URL?
    var lastShotImage: NSImage?
    var lastShotExif: ShotExif?
    var shotCount = 0
    /// 本次拍到的照片（新的在前）；窗口里的胶片条和回看用。
    var shots: [TetherShot] = []
    /// 正在回看的那张（nil = 跟随最新一张）。
    var reviewedShotID: String?
    var reviewImage: NSImage?
    var reviewExif: ShotExif?
    var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored var thumbnailLoading: Set<String> = []
    /// 切换模式、取白等较长的操作进行中（显示在取景上）。
    var busy: String?
    /// 开始录像的时间（计时用）。
    var recordingSince: Date?

    /// 新照片已写进缓存。
    @ObservationIgnored var onFiles: (([URL]) -> Void)?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var liveTask: Task<Void, Never>?
    @ObservationIgnored private let log: (String) -> Void

    init(camera: SonyCamera, name: String, spool: TetherSpool, log: @escaping (String) -> Void) {
        self.camera = camera
        self.cameraName = name
        self.spool = spool
        self.log = log
    }

    func start() {
        let notes = camera.notifications
        tasks.append(Task { [weak self] in
            for await n in notes {
                guard let self else { return }
                switch n {
                case .statusChanged: await self.refresh()
                case .fileAvailable: await self.download()
                case .disconnected: self.connectionLost(); return
                }
            }
        })
        // 相机上直接按快门拍的照片不一定发事件：每秒看一次待传数量。
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.lost else { return }
                await self.refresh()
                if self.status.pendingTransfers > 0 { await self.download() }
                try? await Task.sleep(for: .seconds(1))
            }
        })
        restartLiveView()
    }

    func stop() async {
        for t in tasks { t.cancel() }
        tasks = []
        liveTask?.cancel()
        liveTask = nil
        // 连接时把优先权改成了 PC：断开前交还给相机，相机上的拨盘才能继续用。
        if !lost {
            for r in await camera.restoreChanged(only: [SonyProperty.priorityMode]) {
                log(r.error.map { "联机拍摄：PriorityKey 没能改回相机优先（\($0)）" } ?? "联机拍摄：PriorityKey 已改回相机优先")
            }
        }
        await camera.disconnect()
    }

    /// 把本次联机改过的属性改回原值（后改的先还原）。只还原经 setVerified 改过的属性和连接时改的 PriorityKey。
    func restoreChanged() async -> [SonyCamera.RestoreResult] {
        guard !lost else { return [] }
        let results = await camera.restoreChanged()
        await refresh()
        return results
    }

    private func connectionLost() {
        guard !lost else { return }
        lost = true
        touchPoint = nil
        liveTask?.cancel()
        liveFrame = nil
        message = "与相机的连接已断开。已经拍下的照片保存在联机缓存中。"
        log("联机拍摄：相机断开")
    }

    // MARK: 取景

    private func restartLiveView() {
        liveTask?.cancel()
        liveTask = nil
        guard liveViewOn, !lost else { liveFrame = nil; liveFrameData = nil; return }
        let camera = camera
        liveTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                do {
                    let t0 = Date()
                    if let data = try await camera.liveViewFrame(), let image = NSImage(data: data) {
                        let now = Date()
                        if let self {
                            self.liveSamples.append((now, now.timeIntervalSince(t0) * 1000, data.count))
                            if self.liveSamples.count > 60 { self.liveSamples.removeFirst(self.liveSamples.count - 60) }
                            self.liveSize = image.size
                        }
                        self?.liveFrame = image
                        self?.liveFrameData = data
                        let frames = await camera.focalFrames
                        if self?.focalFrames != frames { self?.focalFrames = frames }
                    }
                    failures = 0
                    let delay = Self.liveDelayMs
                    if delay > 0 { try await Task.sleep(for: .milliseconds(delay), tolerance: .milliseconds(2)) } else { await Task.yield() }
                } catch is CancellationError {
                    return
                } catch {
                    failures += 1
                    if failures == 5 { self?.log("联机拍摄：取景失败 \(error.localizedDescription)") }
                    try? await Task.sleep(for: .milliseconds(failures > 5 ? 1000 : 300))
                }
            }
        }
    }

    // MARK: 控制

    /// 最近一次读到的全部属性（状态里的镜头、卡剩余张数等从这里取）。
    var properties: [UInt16: SonyPropertyDesc] = [:]
    /// 本次联机改过的属性和原值（tether.stop 可按此还原）。
    @ObservationIgnored var changed: [(code: UInt16, original: PTPValue)] = []

    func refresh() async {
        guard !lost, let s = try? await camera.refreshStatus() else { return }
        if s.isRecording != status.isRecording { recordingSince = s.isRecording ? Date() : nil }
        if s != status { status = s }
        if let all = try? await camera.allProperties(refresh: false) {
            let map = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { _, b in b })
            if map != properties { properties = map; updateDistanceTable() }
        }
        changed = await camera.changedProperties
    }

    func shoot() {
        guard !shooting, !lost else { return }
        shooting = true
        message = nil
        Task {
            defer { shooting = false }
            do {
                try await camera.capture()
                focusLocked = false
                await download()
            } catch {
                fail("拍摄失败", error)
            }
        }
    }

    func setFocusLock(_ on: Bool) {
        guard !lost else { return }
        Task {
            do {
                try await camera.halfPress(on)
                focusLocked = on
                await refresh()
            } catch {
                fail("对焦失败", error)
            }
        }
    }

    func toggleRecording() {
        guard !lost else { return }
        let on = !status.isRecording
        Task {
            do {
                try await camera.setRecording(on)
                try? await Task.sleep(for: .milliseconds(300))
                await refresh()
            } catch {
                fail(on ? "开始录像失败" : "停止录像失败", error)
            }
        }
    }

    func set(_ kind: CameraSettingKind, value: Int64) {
        Task {
            do { try await camera.set(kind, value: value); await refresh() }
            catch { fail("调整\(kind.title)失败", error) }
        }
    }

    func step(_ kind: CameraSettingKind, by delta: Int) {
        Task {
            do { try await camera.step(kind, by: delta); await refresh() }
            catch { fail("调整\(kind.title)失败", error) }
        }
    }

    func logLine(_ s: String) { log(s) }

    private func fail(_ what: String, _ error: Error) {
        message = "\(what)：\(error.localizedDescription)"
        log("联机拍摄：\(what) \(String(reflecting: error))")
    }

    // MARK: agent 接口用：任意属性、拍完等文件

    struct CaptureTimeout: Error { let received: [URL] }
    struct RecordingTimeout: Error { let wanted: Bool }

    /// 存储卡内容（远程传输，走同一条连接）。
    func contentLibrary() async throws -> SonyRemoteTransferLibrary { try await camera.contentLibrary() }

    /// 开始 / 停止录像，等相机报告的录像状态变过来（最多 timeout 秒）。
    func setRecordingWaiting(_ on: Bool, timeout: TimeInterval = 8) async throws {
        try await camera.setRecording(on)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            await refresh()
            if status.isRecording == on { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RecordingTimeout(wanted: on)
    }

    func properties() async throws -> [SonyPropertyDesc] { try await camera.allProperties() }

    func sendFocusPosition(_ v: Int64) async throws { try await camera.setFocusPosition(v) }
    func lensInformationRaw(type: UInt32) async throws -> Data { try await camera.lensInformationRaw(type: type) }
    func sendFocusMagnifier(ratio: Int64, x: Int?, y: Int?) async throws { try await camera.setFocusMagnifier(ratio: ratio, x: x, y: y) }
    func remoteTouch(x: Int, y: Int) async throws { try await camera.remoteTouch(x: x, y: y) }
    func cancelRemoteTouch() async throws { try await camera.cancelRemoteTouch() }
    func customWBButton(_ step: SonyCamera.CustomWBStep) async throws { try await camera.customWBButton(step) }
    func customWBCapture(_ value: PTPValue, type: PTPDataType) async throws { try await camera.customWBCapture(value, type: type) }

    func setVerified(_ code: UInt16, _ value: PTPValue, timeout: TimeInterval) async throws -> SonyPropertyDesc {
        let d = try await camera.setVerified(code, value, timeout: timeout)
        await refresh()
        return d
    }

    /// 拍一张，等这一张的所有文件（RAW + HEIF/JPEG）都完整写进缓存才返回。
    /// 「完整」= 相机没有待传文件、没有正在下载，并且新文件列表连续 0.6 秒不变。
    func captureWaiting(timeout: TimeInterval) async throws -> [URL] {
        guard !lost else { throw SonyCameraError.notSonyRemoteCapable }
        guard !shooting else { throw CancellationError() }
        shooting = true
        message = nil
        defer { shooting = false }
        let before = Set(spool.files())
        try await camera.capture()
        focusLocked = false
        let deadline = Date().addingTimeInterval(timeout)
        var seen: [URL] = []
        var stableSince = Date()
        while Date() < deadline {
            await download()
            await refresh()
            let new = spool.files().filter { !before.contains($0) }
            if new != seen { seen = new; stableSince = Date() }
            if !seen.isEmpty, !downloading, status.pendingTransfers == 0, Date().timeIntervalSince(stableSince) >= 0.6 {
                return seen
            }
            if lost { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw CaptureTimeout(received: seen)
    }

    // MARK: 下载

    private func download() async {
        guard !downloading, !lost else { return }
        downloading = true
        defer { downloading = false }
        do {
            let files = try await camera.downloadPendingFiles()
            guard !files.isEmpty else { return }
            var urls: [URL] = []
            for f in files {
                let url = try spool.write(f.data, name: f.filename)
                urls.append(url)
                log("联机拍摄：收到 \(url.lastPathComponent)（\(f.data.count) 字节）")
            }
            shotCount += urls.count
            shots = Self.groupShots(spool.files())
            reviewedShotID = nil
            showLatest(urls)
            onFiles?(urls)
            await refresh()
        } catch {
            fail("接收照片失败", error)
        }
    }

    private func showLatest(_ urls: [URL]) {
        // RAW + JPG 一起来时优先显示 JPG（解码快、颜色是机内效果）。
        let pick = urls.first { ["JPG", "JPEG", "HIF", "HEIF"].contains($0.pathExtension.uppercased()) } ?? urls.last
        guard let pick else { return }
        lastShot = pick
        lastShotExif = ShotExif(url: pick)
        lastShotImage = Self.previewImage(pick, maxPixel: 1600)
    }

    static func previewImage(_ url: URL, maxPixel: Int) -> NSImage? {
        previewCGImage(url, maxPixel: maxPixel).map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
    }

    /// 后台解码用（不碰界面对象）。
    nonisolated static func previewCGImage(_ url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }
}

/// 联机缓存：每次联机拍摄一个文件夹（按存储卡的样子放在 DCIM/100TETHR 下，导入时当作一张卡来读）。
/// 位置：~/Library/Application Support/MiniDiT/Tether/。照片导入项目后，这里的副本仍保留，可在 Finder 中清理。
struct TetherSpool: Sendable {
    let root: URL
    var folder: URL { root.appending(path: "DCIM/100TETHR", directoryHint: .isDirectory) }

    /// 功能检查用：换到临时目录，不碰真实的缓存。
    nonisolated(unsafe) static var baseOverride: URL?

    static var base: URL {
        baseOverride ?? URL.applicationSupportDirectory.appending(path: "MiniDiT/Tether", directoryHint: .isDirectory)
    }

    static func create(camera: String, in base: URL = TetherSpool.base, now: Date = .now) throws -> TetherSpool {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let safe = camera.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let spool = TetherSpool(root: base.appending(path: "\(f.string(from: now)) \(safe)", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: spool.folder, withIntermediateDirectories: true)
        removeEmpty(in: base, keeping: spool.root)
        return spool
    }

    /// 没拍任何照片的旧缓存文件夹删掉。
    static func removeEmpty(in base: URL, keeping: URL) {
        let fm = FileManager.default
        for dir in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        where dir.standardizedFileURL != keeping.standardizedFileURL {
            let files = (try? fm.subpathsOfDirectory(atPath: dir.path))?.filter {
                !$0.hasPrefix(".") && !$0.contains("/.") && !(fm.isDirectory(dir.appending(path: $0)))
            } ?? ["?"]
            if files.isEmpty { try? fm.removeItem(at: dir) }
        }
    }

    /// 写入照片。重名时（比如相机的文件编号重置过）加「-1」「-2」，不覆盖已有的照片。
    func write(_ data: Data, name: String) throws -> URL {
        let fm = FileManager.default
        let clean = (name as NSString).lastPathComponent
        let base = (clean as NSString).deletingPathExtension, ext = (clean as NSString).pathExtension
        var url = folder.appending(path: clean)
        var n = 1
        while fm.fileExists(atPath: url.path) {
            url = folder.appending(path: ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            n += 1
        }
        // 先写到隐藏的临时文件再改名：别处列目录时不会看到写了一半的照片，改名也不会覆盖已有文件。
        let partial = folder.appending(path: ".\(UUID().uuidString).partial")
        try data.write(to: partial)
        do { try fm.moveItem(at: partial, to: url) } catch { try? fm.removeItem(at: partial); throw error }
        return url
    }

    /// 缓存里已有的照片（不含写到一半的临时文件）。
    func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func contains(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(root.standardizedFileURL.path)
    }
}

private extension FileManager {
    func isDirectory(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }
}
