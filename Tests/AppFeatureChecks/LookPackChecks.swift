import CryptoKit
import Foundation
@testable import MiniDiT

/// 用本地的假 release 跑真实的安装流程：下载、核对校验值、解压、装到三个位置、不覆盖已有文件。
@main struct LookPackChecks {
    static func main() async throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-looks-check-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let release = root.appending(path: "release"), build = root.appending(path: "build/Sony-ZV-E1-Creative-Looks")
        let acr = build.appending(path: "Adobe Camera Raw and Lightroom"), c1 = build.appending(path: "Capture One"), dxo = build.appending(path: "DxO PhotoLab")
        for d in [release, acr, c1, dxo] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("dcp".utf8).write(to: acr.appending(path: "SonyZVE1 Linear Base.dcp"))
        for code in ["ST", "FL"] {
            try Data("xmp \(code)".utf8).write(to: acr.appending(path: "SonyZVE1 Look \(code).xmp"))
            try Data("icc \(code)".utf8).write(to: c1.appending(path: "SonyZVE1-Look-\(code).icc"))
        }
        try Data("cube".utf8).write(to: dxo.appending(path: "SonyZVE1 Look ST.cube"))
        try Data("dxo dcp".utf8).write(to: dxo.appending(path: "SonyZVE1 Linear Base v2.dcp"))
        let zip = release.appending(path: "Sony-ZV-E1-Creative-Looks.zip")
        let ditto = Process(); ditto.executableURL = URL(filePath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", build.path, zip.path]; try ditto.run(); ditto.waitUntilExit()
        let hash = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        try "\(hash)  Sony-ZV-E1-Creative-Looks.zip\n0000  Sony-A1-Creative-Looks.zip\n".write(to: release.appending(path: "SHA256SUMS.txt"), atomically: true, encoding: .utf8)

        let home = root.appending(path: "home")
        let places = LookPacks.Places(release: release, cameraProfiles: home.appending(path: "CameraProfiles"),
                                      cameraRawSettings: home.appending(path: "Settings"), colorSync: home.appending(path: "ColorSync"),
                                      dxo: home.appending(path: "DxO"))
        // 用户把一个 Look 整理进了子文件夹：不再装第二份，也不覆盖。
        try fm.createDirectory(at: places.cameraRawSettings.appending(path: "My Looks"), withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: places.cameraRawSettings.appending(path: "My Looks/SonyZVE1 Look FL.xmp"))

        let packs = LookPacks(places: places)
        let camera = LookPacks.camera(model: "zv-e1")!
        precondition(camera.prefix == "SonyZVE1" && !packs.isInstalled(camera))
        let first = await packs.ensure(model: "ZV-E1")
        precondition(first == .installed(camera), "\(first)")
        precondition(packs.isInstalled(camera))
        precondition(fm.fileExists(atPath: places.cameraProfiles.appending(path: "SonyZVE1 Linear Base.dcp").path))
        precondition(fm.fileExists(atPath: places.colorSync.appending(path: "SonyZVE1-Look-FL.icc").path))
        precondition(!fm.fileExists(atPath: places.cameraRawSettings.appending(path: "SonyZVE1 Look FL.xmp").path), "子文件夹里已有的不再装")
        let mine = try String(contentsOf: places.cameraRawSettings.appending(path: "My Looks/SonyZVE1 Look FL.xmp"), encoding: .utf8)
        precondition(mine == "mine")
        precondition(packs.isInstalled(camera, parts: .dxo) && fm.fileExists(atPath: packs.dxoLook(camera, code: "ST").path), "DxO 的 DCP 和 LUT 装进 MiniDiT 的文件夹")
        precondition(!fm.fileExists(atPath: places.cameraProfiles.appending(path: "SonyZVE1 Linear Base v2.dcp").path), "DxO 的 DCP 不放进 Camera Raw")
        let again = await packs.ensure(model: "ZV-E1"), unknown = await packs.ensure(model: "ILCE-7M3")
        precondition(again == .present && unknown == .unsupported)

        // 校验值不符：不装任何文件。
        let otherHome = root.appending(path: "other")
        let other = LookPacks(places: .init(release: release, cameraProfiles: otherHome.appending(path: "CameraProfiles"),
                                            cameraRawSettings: otherHome.appending(path: "Settings"), colorSync: otherHome.appending(path: "ColorSync"),
                                            dxo: otherHome.appending(path: "DxO")))
        try fm.copyItem(at: zip, to: release.appending(path: "Sony-A1-Creative-Looks.zip"))
        if case .failed(let message) = await other.ensure(model: "ILCE-1") { precondition(message.contains("校验值不符"), message) } else { fatalError("bad checksum accepted") }
        precondition(LookPacks.names(in: otherHome).isEmpty)
        // 真实 release 的机型表与包名一致。
        precondition(LookPacks.cameras.count == 17 && Set(LookPacks.cameras.map(\.pack)).count == 17)
        // 设了 MINIDIT_LOOKS_LIVE 时从真实 release 下载一个包，装到临时目录。
        if ProcessInfo.processInfo.environment["MINIDIT_LOOKS_LIVE"] != nil {
            let liveHome = root.appending(path: "live")
            let live = LookPacks(places: .init(release: LookPacks.Places.standard.release, cameraProfiles: liveHome.appending(path: "CameraProfiles"),
                                               cameraRawSettings: liveHome.appending(path: "Settings"), colorSync: liveHome.appending(path: "ColorSync"),
                                               dxo: liveHome.appending(path: "DxO")))
            let outcome = await live.ensure(model: "ZV-E1")
            precondition(outcome == .installed(camera), "\(outcome)")
            let counts = ["CameraProfiles", "Settings", "ColorSync", "DxO"].map { LookPacks.names(in: liveHome.appending(path: $0)).count }
            print("PASS (live): downloaded the real ZV-E1 pack from the latest release, checksum matched; installed DCP/XMP/ICC counts \(counts)")
        }
        // DxO：按模板写 .dop，路径转义，已有 .dop 不动。
        let template = try String(contentsOf: URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Apps/MiniDiT/MiniDiT/Resources/DxOLookTemplate.dop"), encoding: .utf8)
        let shots = root.appending(path: "shots"); try fm.createDirectory(at: shots, withIntermediateDirectories: true)
        let raw = shots.appending(path: "DSC0001.ARW"); try Data("raw".utf8).write(to: raw)
        let quoted = root.appending(path: "Looks \"A\"/SonyZVE1 Look FL.cube")
        let wrote = try DxOLooks.writeSidecar(raw: raw, dcp: packs.dxoBase(camera), lut: quoted, template: template)
        precondition(wrote == .written)
        let dop = try String(contentsOf: raw.appendingPathExtension("dop"), encoding: .utf8)
        precondition(!dop.contains("{{") && dop.contains("Name = \"DSC0001.ARW\"") && dop.contains("Looks \\\"A\\\"/SonyZVE1 Look FL.cube"), dop)
        precondition(dop.components(separatedBy: "ColorLookupActive = true").count == 3 && dop.components(separatedBy: "ColorRenderingType = \"DCP\"").count == 3,
                     "外观设置同时写在 Base 和 Overrides")
        try Data("user".utf8).write(to: raw.appendingPathExtension("dop"))
        let keptResult = try DxOLooks.writeSidecar(raw: raw, dcp: packs.dxoBase(camera), lut: quoted, template: template)
        precondition(keptResult == .kept)
        let untouched = try String(contentsOf: raw.appendingPathExtension("dop"), encoding: .utf8)
        precondition(untouched == "user")
        print("PASS: DxO sidecar written from the PhotoLab template with escaped paths in Base and Overrides; an existing .dop is kept")
        print("PASS: missing creative look packs download from the release, match SHA256SUMS, install Camera Raw DCP/XMP and Capture One ICC without overwriting or duplicating existing files; bad checksums install nothing")
    }
}
