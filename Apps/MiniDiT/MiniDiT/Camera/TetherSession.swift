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
    var liveViewOn = true { didSet { if liveViewOn != oldValue { restartLiveView() } } }
    var shooting = false
    var downloading = false
    var focusLocked = false
    /// 相机断开了（关机、离开网络）。缓存里已有的照片仍在。
    var lost = false
    var message: String?
    var lastShot: URL?
    var lastShotImage: NSImage?
    var lastShotExif: ShotExif?
    var shotCount = 0

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
        await camera.disconnect()
    }

    private func connectionLost() {
        guard !lost else { return }
        lost = true
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
                    if let data = try await camera.liveViewFrame(), let image = NSImage(data: data) {
                        self?.liveFrame = image
                        self?.liveFrameData = data
                    }
                    failures = 0
                    try await Task.sleep(for: .milliseconds(50))
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
    @ObservationIgnored var properties: [UInt16: SonyPropertyDesc] = [:]

    func refresh() async {
        guard !lost, let s = try? await camera.refreshStatus() else { return }
        if s != status { status = s }
        if let all = try? await camera.allProperties(refresh: false) {
            properties = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { _, b in b })
        }
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

    private func fail(_ what: String, _ error: Error) {
        message = "\(what)：\(error.localizedDescription)"
        log("联机拍摄：\(what) \(String(reflecting: error))")
    }

    // MARK: agent 接口用：任意属性、拍完等文件

    struct CaptureTimeout: Error { let received: [URL] }

    func properties() async throws -> [SonyPropertyDesc] { try await camera.allProperties() }

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
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxPixel]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
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
