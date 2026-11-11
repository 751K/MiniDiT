import CryptoKit
import Foundation
import ImageIO

/// 索尼创意外观配置文件包，来自 github.com/751K/sony-look-bridge 的最新 release：每个机型一个 ZIP。
/// 导入 RAW 时发现该机型的 Look 还没装，就下载对应的包，核对 SHA256SUMS.txt 后，
/// 把 Camera Raw / Lightroom 的 DCP、XMP，Capture One 的 ICC 装到各自的位置，DxO PhotoLab 的 DCP 和 LUT
/// 装到 MiniDiT 自己的文件夹（DxO 从 .dop 里的路径读取）。已有的同名文件不覆盖。
actor LookPacks {
    static let shared = LookPacks()

    struct Camera: Sendable, Equatable {
        /// EXIF 机型（「ILCE-7M5」）。
        let model: String
        /// 包名（「Sony-A7-V」→ Sony-A7-V-Creative-Looks.zip）。
        let pack: String
        /// 配置文件名前缀（「SonyA7M5」）。
        let prefix: String
        /// 给人看的名字。
        let name: String
    }

    /// 与 sony-look-bridge 的 camera_packs/build_packs.py 一致。
    static let cameras: [Camera] = [
        .init(model: "ILCE-1", pack: "Sony-A1", prefix: "SonyA1", name: "α1"),
        .init(model: "ILCE-1M2", pack: "Sony-A1-II", prefix: "SonyA1M2", name: "α1 II"),
        .init(model: "ILCE-6700", pack: "Sony-A6700", prefix: "SonyA6700", name: "α6700"),
        .init(model: "ILCE-7M4", pack: "Sony-A7-IV", prefix: "SonyA7M4", name: "α7 IV"),
        .init(model: "ILCE-7M5", pack: "Sony-A7-V", prefix: "SonyA7M5", name: "α7 V"),
        .init(model: "ILCE-7CM2", pack: "Sony-A7C-II", prefix: "SonyA7CM2", name: "α7C II"),
        .init(model: "ILCE-7CR", pack: "Sony-A7CR", prefix: "SonyA7CR", name: "α7CR"),
        .init(model: "ILCE-7RM5", pack: "Sony-A7R-V", prefix: "SonyA7RM5", name: "α7R V"),
        .init(model: "ILCE-7RM6", pack: "Sony-A7R-VI", prefix: "SonyA7RM6", name: "α7R VI"),
        .init(model: "ILCE-7SM3", pack: "Sony-A7S-III", prefix: "SonyA7SM3", name: "α7S III"),
        .init(model: "ILCE-9M3", pack: "Sony-A9-III", prefix: "SonyA9M3", name: "α9 III"),
        .init(model: "ILME-FX2", pack: "Sony-FX2", prefix: "SonyFX2", name: "FX2"),
        .init(model: "ILME-FX3", pack: "Sony-FX3", prefix: "SonyFX3", name: "FX3"),
        .init(model: "ILME-FX30", pack: "Sony-FX30", prefix: "SonyFX30", name: "FX30"),
        .init(model: "DSC-RX1RM3", pack: "Sony-RX1R-III", prefix: "SonyRX1RM3", name: "RX1R III"),
        .init(model: "ZV-E1", pack: "Sony-ZV-E1", prefix: "SonyZVE1", name: "ZV-E1"),
        .init(model: "ZV-E10M2", pack: "Sony-ZV-E10-II", prefix: "SonyZVE10M2", name: "ZV-E10 II"),
    ]

    /// 需要哪些软件的配置文件。
    struct Parts: OptionSet, Sendable, Hashable {
        let rawValue: Int
        static let adobe = Parts(rawValue: 1), captureOne = Parts(rawValue: 2), dxo = Parts(rawValue: 4)
        static let lightroomAndCaptureOne: Parts = [.adobe, .captureOne]
    }

    enum Outcome: Sendable, Equatable {
        /// 已经装好。
        case present
        /// 这次装好了；Lightroom Classic 和 Capture One 要重新启动才会读到。
        case installed(Camera)
        /// 这台机型没有配置文件包。
        case unsupported
        case failed(String)
    }

    /// 安装位置；检查时换成临时目录。
    struct Places: Sendable {
        var release: URL
        var cameraProfiles: URL
        var cameraRawSettings: URL
        var colorSync: URL
        /// DxO PhotoLab 的 DCP 和 LUT。
        var dxo: URL
        static var standard: Places {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return .init(release: URL(string: "https://github.com/751K/sony-look-bridge/releases/latest/download/")!,
                         cameraProfiles: home.appending(path: "Library/Application Support/Adobe/CameraRaw/CameraProfiles"),
                         cameraRawSettings: home.appending(path: "Library/Application Support/Adobe/CameraRaw/Settings"),
                         colorSync: home.appending(path: "Library/ColorSync/Profiles"),
                         dxo: home.appending(path: "Library/Application Support/MiniDiT/Looks/DxO"))
        }
    }

    private var running: [String: Task<Outcome, Never>] = [:]
    /// 本次运行中已经有结果的机型：装好或失败过的不再重复下载，下次启动 MiniDiT 再试。
    private var settled: [String: Outcome] = [:]

    nonisolated let places: Places
    init(places: Places = .standard) { self.places = places }

    /// RAW 的 EXIF 机型（「ILCE-7M5」）。
    nonisolated static func model(ofRaw url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
              let model = tiff[kCGImagePropertyTIFFModel] as? String else { return nil }
        return model.trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func camera(model: String) -> Camera? {
        cameras.first { $0.model.caseInsensitiveCompare(model) == .orderedSame }
    }

    /// 需要的软件的文件都在：Camera Raw 的基础 DCP 和 ST 外观 XMP、Capture One 的 ST 外观 ICC、DxO 的基础 DCP 和 ST 外观 LUT。
    /// 用户常把配置文件放在子文件夹里整理，所以按文件名在整个文件夹里找。
    nonisolated func isInstalled(_ camera: Camera, parts: Parts = .lightroomAndCaptureOne) -> Bool {
        (!parts.contains(.adobe) || (Self.names(in: places.cameraProfiles).contains("\(camera.prefix) Linear Base.dcp".lowercased())
            && Self.names(in: places.cameraRawSettings).contains("\(camera.prefix) Look ST.xmp".lowercased())))
            && (!parts.contains(.captureOne) || Self.names(in: places.colorSync).contains("\(camera.prefix)-Look-ST.icc".lowercased()))
            && (!parts.contains(.dxo) || FileManager.default.fileExists(atPath: dxoBase(camera).path)
                && FileManager.default.fileExists(atPath: dxoLook(camera, code: "ST").path))
    }

    /// DxO 用的基础 DCP 和外观 LUT。
    nonisolated func dxoBase(_ camera: Camera) -> URL { places.dxo.appending(path: "\(camera.prefix) Linear Base v2.dcp") }
    nonisolated func dxoLook(_ camera: Camera, code: String) -> URL { places.dxo.appending(path: "\(camera.prefix) Look \(code).cube") }

    /// 文件夹（含子文件夹）里所有文件名，小写。
    nonisolated static func names(in folder: URL) -> Set<String> {
        guard let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        var out: Set<String> = []
        for case let url as URL in e { out.insert(url.lastPathComponent.lowercased()) }
        return out
    }

    /// 确保这张 RAW 的机型已装好配置文件。同一机型同时只下载一次。
    func ensure(forRaw url: URL, parts: Parts = .lightroomAndCaptureOne) async -> Outcome {
        guard let model = Self.model(ofRaw: url) else { return .unsupported }
        return await ensure(model: model, parts: parts)
    }

    /// 每次下载整个包、装上所有软件的文件；按 `parts` 判断是否需要下载。
    func ensure(model: String, parts: Parts = .lightroomAndCaptureOne) async -> Outcome {
        guard let camera = Self.camera(model: model) else { return .unsupported }
        if isInstalled(camera, parts: parts) { return .present }
        if let done = settled[camera.model], case .failed = done { return done }
        if let task = running[camera.model] { return await task.value }
        let places = places
        let task = Task.detached(priority: .utility) { () -> Outcome in
            do { try await Self.install(camera, places: places); return .installed(camera) }
            catch { return .failed(error.localizedDescription) }
        }
        running[camera.model] = task
        let outcome = await task.value
        running[camera.model] = nil
        settled[camera.model] = outcome
        return outcome
    }

    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    private static func install(_ camera: Camera, places: Places) async throws {
        let fm = FileManager.default
        let zipName = camera.pack + "-Creative-Looks.zip"
        let work = fm.temporaryDirectory.appending(path: "minidit-looks-" + UUID().uuidString)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        let sums = try await download(places.release.appending(path: "SHA256SUMS.txt"), to: work.appending(path: "SHA256SUMS.txt"))
        guard let expected = String(decoding: try Data(contentsOf: sums), as: UTF8.self).split(separator: "\n")
            .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
            .first(where: { $0.count == 2 && $0[1] == Substring(zipName) })?[0].lowercased() else {
            throw Failure(message: "校验清单中没有 \(zipName)。")
        }
        let zip = try await download(places.release.appending(path: zipName), to: work.appending(path: zipName))
        guard try sha256(zip) == expected else { throw Failure(message: "\(zipName) 校验值不符，未安装。") }

        let unpacked = work.appending(path: "unpacked")
        let ditto = Process(); ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, unpacked.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw Failure(message: "无法解压 \(zipName)。") }

        let root = unpacked.appending(path: camera.pack + "-Creative-Looks")
        let acr = root.appending(path: "Adobe Camera Raw and Lightroom"), c1 = root.appending(path: "Capture One")
        let dxo = root.appending(path: "DxO PhotoLab")
        let plan: [(from: URL, ext: String, to: URL)] = [(acr, "dcp", places.cameraProfiles), (acr, "xmp", places.cameraRawSettings), (c1, "icc", places.colorSync),
                                                         (dxo, "dcp", places.dxo), (dxo, "cube", places.dxo)]
        var copied = 0
        for step in plan {
            let files = try fm.contentsOfDirectory(at: step.from, includingPropertiesForKeys: nil).filter { $0.pathExtension.lowercased() == step.ext }
            guard !files.isEmpty else { throw Failure(message: "\(zipName) 中缺少 \(step.ext.uppercased()) 文件。") }
            try fm.createDirectory(at: step.to, withIntermediateDirectories: true)
            // 同名文件在任何子文件夹里已经有了就不再装一份，免得软件里出现重复的配置文件。
            let existing = names(in: step.to)
            for file in files {
                let target = step.to.appending(path: file.lastPathComponent)
                guard !existing.contains(file.lastPathComponent.lowercased()) else { continue }
                try fm.copyItem(at: file, to: target)
                copied += 1
            }
        }
        _ = copied
    }

    private static func download(_ url: URL, to target: URL) async throws -> URL {
        if url.isFileURL { try FileManager.default.copyItem(at: url, to: target); return target }
        let (temp, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw Failure(message: "下载 \(url.lastPathComponent) 失败（\((response as? HTTPURLResponse)?.statusCode ?? 0)）。")
        }
        try FileManager.default.moveItem(at: temp, to: target)
        return target
    }

    private static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
