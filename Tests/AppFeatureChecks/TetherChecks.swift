import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
@testable import MiniDiT

/// 联机拍摄：对着模拟索尼相机（fake-sony-camera，127.0.0.1:15740）连接、取景、改 ISO、拍两张（第二张重名）、
/// 自动导入当前项目、录像开关、结束联机。用法：run.sh --tether <fake-sony-camera 可执行文件> [--cli <minidit 可执行文件>]
@main struct TetherChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        setvbuf(stdout, nil, _IOLBF, 0)
        precondition(Bundle.main.bundleIdentifier == nil)
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--tether"), i + 1 < args.count else { fatalError("需要 fake-sony-camera 的路径") }
        let defaults = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        let previous = defaults.persistentDomain(forName: domain)
        defer {
            if let previous { defaults.setPersistentDomain(previous, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        defaults.removePersistentDomain(forName: domain)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "minidit-tether-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = oldHistory }
        TetherSpool.baseOverride = root.appending(path: "spool")

        let fake = Process()
        fake.executableURL = URL(filePath: args[i + 1])
        fake.arguments = ["15740", "-bind", "127.0.0.1"]
        fake.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        fake.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try fake.run()
        defer { fake.terminate() }
        // 等模拟相机开始监听。
        for _ in 0..<50 {
            let s = socket(AF_INET, SOCK_STREAM, 0)
            var a = sockaddr_in(); a.sin_family = sa_family_t(AF_INET); a.sin_port = in_port_t(15740).bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
            close(s)
            if ok { break }
            try await Task.sleep(for: .milliseconds(200))
        }

        let model = AppModel(startServices: false, journalURL: root.appending(path: "journal.sqlite"))
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.captureOneMode = .off; model.openAfterImport = .none
        model.sendToFCP = false; model.sendToResolve = false; model.deleteAfterImport = false
        model.autoRefresh = false; model.onlyNew = false
        model.photoFolderLayout = .session; model.videoFolderLayout = .session
        model.destination = root.appending(path: "photos")
        model.videoDestination = root.appending(path: "videos")
        model.backupEnabled = false; model.backupFolder = nil
        let project = ShootSession(day: "20261116", name: "联机检查", content: .all)
        model.sessions = [project]; model.currentSessionID = project.id

        model.startTether(FoundCamera(host: "127.0.0.1", kind: .direct, knownName: "模拟 α"))
        try await wait("连接") { model.tether != nil && model.phase == .ready }
        let t = model.tether!
        precondition(model.isTetherSource(AppModel.primarySource) && model.connectedName == "联机拍摄 · 模拟 α")
        precondition(model.tetherWindowRequest == 1, "连上后要请求打开联机窗口")
        try await wait("读取设置") { !t.status.settings.isEmpty }
        try await wait("取景") { t.liveFrame != nil }
        print("PASS: tether connects to the fake Sony camera, opens its spool as the source, reads settings and shows live view")

        t.set(.iso, value: 400)
        try await wait("ISO") { t.status.settings.first { $0.kind == .iso }?.currentValue == 400 }
        print("PASS: changing ISO from the tether window reaches the camera")

        let photos = model.destination.appending(path: project.name)
        func imported() -> [String] {
            ((try? fm.contentsOfDirectory(atPath: photos.path)) ?? []).filter { $0.uppercased().hasSuffix(".JPG") }.sorted()
        }
        t.shoot()
        try await wait("第一张导入") { imported().count == 1 && model.progress == nil }
        precondition(t.shotCount == 1 && t.lastShot?.lastPathComponent == "DSC01234.JPG" && t.lastShotImage != nil)
        t.shoot()
        try await wait("第二张导入") { imported().count == 2 && model.progress == nil }
        let spooled = try fm.contentsOfDirectory(atPath: t.spool.folder.path).sorted()
        precondition(spooled == ["DSC01234-1.JPG", "DSC01234.JPG"], "重名的照片不能覆盖：\(spooled)")
        precondition(model.allShots.count == 2 && model.allShots.allSatisfy { model.isImported(shot: $0.id) })
        print("PASS: each shot is downloaded to the spool, a repeated file name gets -1 instead of overwriting, and both are auto-imported into the current project: \(imported())")

        t.toggleRecording()
        try await wait("录像") { t.status.isRecording }
        t.toggleRecording()
        try await wait("停止录像") { !t.status.isRecording }
        print("PASS: movie record toggles on the camera")

        model.currentSessionID = nil
        t.shoot()
        try await wait("没选项目时只进缓存") { t.shotCount == 3 && model.allShots.count == 3 }
        try await Task.sleep(for: .seconds(1))
        precondition(imported().count == 2, "没选项目不能导入")
        model.currentSessionID = project.id
        try await wait("选了项目后补导") { imported().count == 3 && model.progress == nil }
        print("PASS: without a project shots wait in the spool and are imported once a project is chosen")

        let spool = t.spool.root
        model.stopTether()
        precondition(model.tether == nil && model.connectedName == "联机缓存 · 模拟 α" && model.library != nil)
        model.ejectCard()
        precondition(model.library == nil && fm.fileExists(atPath: spool.path), "关闭缓存不能删照片，也不能去推出系统盘")
        print("PASS: ending the tether keeps the spool browsable; closing it just disconnects")

        // CLI 与 MCP：同一套 tether.* 操作经本机 socket 控制应用。
        guard let c = args.firstIndex(of: "--cli"), c + 1 < args.count else { print("SKIP: CLI/MCP（没有给 --cli）"); return }
        let cli = args[c + 1]
        let sockDir = URL(filePath: "/private/tmp").appending(path: "minidit-tether-sock-" + UUID().uuidString)
        try fm.createDirectory(at: sockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: sockDir) }
        let endpoint = sockDir.appending(path: "control.sock").path
        model.startAgentControl(path: endpoint)
        func call(_ a: [String]) async throws -> (code: Int32, json: AgentJSON) {
            let r = try await run(cli, args: a, socket: endpoint)
            return (r.code, try JSONDecoder().decode(AgentJSON.self, from: r.data))
        }
        let idle = try await call(["tether", "status"])
        precondition(idle.code == 0 && idle.json["active"].bool == false, "\(idle)")
        let early = try await call(["tether", "shoot"])
        precondition(early.json["error"]["code"].string == "not_tethering")
        let started = try await call(["tether", "start", "--host", "127.0.0.1"])
        precondition(started.code == 0, "\(started.json)")
        try await wait("CLI 联机") { model.tether?.liveFrameData != nil && model.phase == .ready && !(model.tether?.status.settings.isEmpty ?? true) }
        let t2 = model.tether!
        let status = try await call(["tether", "status"])
        precondition(status.json["active"].bool == true && status.json["camera"].string != nil
                     && status.json["settings"].array?.contains { $0["setting"].string == "iso" && !($0["options"].array ?? []).isEmpty } == true)
        let none = try await call(["tether", "set", "--setting", "iso"])
        precondition(none.code == 2 && none.json["error"]["code"].string == "invalid_params")
        let bad = try await call(["tether", "set", "--setting", "iso", "--label", "12345"])
        precondition(bad.code == 1 && bad.json["error"]["code"].string == "invalid_value")
        print("PASS: CLI tether status/start/set: not_tethering before start, async start by host, settings with options, strict value/label/step validation")

        func msg(_ id: Int, _ tool: String, _ arguments: [String: AgentJSON] = [:]) -> AgentJSON {
            .object(["jsonrpc": .string("2.0"), "id": .integer(id), "method": .string("tools/call"),
                     "params": .object(["name": .string(tool), "arguments": .object(arguments)])])
        }
        let messages: [AgentJSON] = [
            .object(["jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])])]),
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]),
            .object(["jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("tools/list")]),
            msg(3, "minidit_tether_live_view", ["maxWidth": .integer(320)]),
            msg(4, "minidit_tether_set", ["setting": .string("iso"), "label": .string("200")]),
            msg(5, "minidit_tether_shoot"),
        ]
        let input = try messages.reduce(into: Data()) { $0.append(try $1.data()); $0.append(10) }
        let mcp = try await run(cli, args: ["mcp"], socket: endpoint, input: input)
        let replies = try mcp.data.split(separator: 10).map { try JSONDecoder().decode(AgentJSON.self, from: Data($0)) }
        precondition(mcp.code == 0 && replies.count == 5)
        let names = Set(replies[1]["result"]["tools"].array!.compactMap { $0["name"].string })
        precondition(["minidit_tether_start", "minidit_tether_status", "minidit_tether_shoot", "minidit_tether_set", "minidit_tether_focus",
                      "minidit_tether_record", "minidit_tether_live_view", "minidit_tether_configure", "minidit_tether_stop"].allSatisfy(names.contains))
        let frame = replies[2]["result"]
        precondition(frame["isError"].bool == false && frame["content"].array?.first?["type"].string == "image"
                     && frame["content"].array?.first?["mimeType"].string == "image/jpeg"
                     && frame["structuredContent"]["data"] == .null && (frame["structuredContent"]["width"].int ?? 999) <= 320)
        let jpeg = Data(base64Encoded: frame["content"].array![0]["data"].string!)!
        precondition(jpeg.starts(with: [0xFF, 0xD8]) && NSImage(data: jpeg) != nil)
        precondition(replies[3]["result"]["structuredContent"]["to"].string == "200", "\(replies[3])")
        precondition(replies[4]["result"]["structuredContent"]["accepted"].bool == true)
        try await wait("MCP ISO") { t2.status.settings.first { $0.kind == .iso }?.currentValue == 200 }
        try await wait("MCP 拍摄并导入") { t2.shotCount == 1 && model.progress == nil && model.allShots.first.map { model.isImported(shot: $0.id) } == true }
        let after = try await call(["tether", "status"])
        precondition(after.json["shotCount"].int == 1 && after.json["lastShot"]["imported"].bool == true, "\(after.json)")
        print("PASS: MCP lists tether tools, live view comes back as image content (no base64 duplicated in structured result), set by label and shoot work, the shot is auto-imported")

        // 任意属性：列出、读取、设置（回读确认）、拍完等文件。
        let listed = try await call(["tether", "properties", "--query", "iso"])
        precondition(listed.code == 0 && listed.json["properties"].array?.contains { $0["name"].string == "IsoSensitivity" && $0["options"].array != nil } == true, "\(listed.json)")
        let got = try await call(["tether", "get", "--names", "ISO,ShutterSpeed,0x5007"])
        precondition(got.json["values"].array?.count == 3 && got.json["values"].array?[1]["value"]["label"].string == "1/250", "\(got.json)")
        let set = try await call(["tether", "set-properties", "--assignments", "ISO=ISO 400,ShutterSpeed=1/500,FNumber=F5.6"])
        precondition(set.code == 0 && set.json["results"].array?.map { $0["value"]["label"].string ?? "" } == ["400", "1/500", "F5.6"], "\(set.json)")
        precondition(state(t2) == [400, 0x0001_01F4, 560])
        let unknown = try await call(["tether", "set-properties", "--assignments", "Nope=1"])
        precondition(unknown.code == 1 && unknown.json["error"]["code"].string == "unknown_property")
        let invalid = try await call(["tether", "set-properties", "--assignments", "FNumber=F6.3"])
        precondition(invalid.json["error"]["code"].string == "invalid_value" && invalid.json["error"]["message"].string?.contains("F5.6") == true, "\(invalid.json)")
        let locked = try await call(["tether", "set-properties", "--assignments", "ISO=200,ExposureProgramMode=P"])
        precondition(locked.json["error"]["code"].string == "not_writable" && locked.json["error"]["message"].string?.contains("IsoSensitivity") == true, "\(locked.json)")
        print("PASS: tether.properties / get / set_properties: SDK names, readable values both ways, readback-confirmed writes, unknown / invalid (with options) / not-writable errors that list what already took effect")

        model.tetherAutoImport = false
        let out = root.appending(path: "out")
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let shot = try await call(["tether", "capture", "--out-dir", out.path])
        precondition(shot.code == 0, "\(shot.json)")
        let name = shot.json["files"].array![0]["filename"].string!
        precondition(fm.fileExists(atPath: out.appending(path: name).path) && shot.json["copies"].array?.count == 1
                     && shot.json["settings"]["ShutterSpeed"]["label"].string == "1/500" && (shot.json["files"].array![0]["bytes"].int ?? 0) > 1000, "\(shot.json)")
        // 模拟相机每张都叫 DSC01234.JPG，缓存里依次加 -1、-2……：下一张的名字可以算出来。
        let next = "DSC01234-\(t2.spool.files().count).JPG"
        try Data([1]).write(to: out.appending(path: next))
        let clash = try await call(["tether", "capture", "--out-dir", out.path])
        let kept = try Data(contentsOf: out.appending(path: next))
        precondition(clash.json["error"]["code"].string == "file_exists" && kept == Data([1]), "\(clash.json)")
        let info = try await call(["tether", "status"])
        precondition(info.json["info"]["battery"]["label"].string == "76%", "\(info.json["info"])")
        print("PASS: tether.capture waits for the file, copies it to outDir with the settings snapshot, refuses to overwrite an existing file; status carries camera info")

        // 存储卡内容（远程传输，走联机这条连接）、下载、录一段并取回。
        let files = try await call(["tether", "files", "--latest", "5"])
        precondition(files.code == 0 && files.json["files"].array?.count == 5 && (files.json["total"].int ?? 0) > 5, "\(files.json)")
        let first = files.json["files"].array![0]["filename"].string!
        let dl = root.appending(path: "dl")
        try fm.createDirectory(at: dl, withIntermediateDirectories: true)
        let got1 = try await call(["tether", "download", "--names", first, "--out-dir", dl.path])
        precondition(got1.code == 0 && fm.fileExists(atPath: dl.appending(path: first).path), "\(got1.json)")
        let again = try await call(["tether", "download", "--names", first, "--out-dir", dl.path])
        precondition(again.json["error"]["code"].string == "file_exists")
        let missing = try await call(["tether", "download", "--names", "NOPE.JPG", "--out-dir", dl.path])
        precondition(missing.json["error"]["code"].string == "not_found")
        let clip = try await call(["tether", "record-clip", "--seconds", "1", "--out-dir", dl.path, "--timeout-seconds", "20"])
        precondition(clip.code == 0, "\(clip.json)")
        let clipFile = clip.json["files"].array![0]
        let xmlPath = clipFile["xml"].string!
        let xmlText = (try? String(contentsOfFile: xmlPath, encoding: .utf8)) ?? ""
        precondition(clipFile["filename"].string?.hasSuffix(".MP4") == true && fm.fileExists(atPath: clipFile["path"].string!)
                     && xmlPath.hasSuffix("M01.XML") && xmlText.contains("NonRealTimeMeta")
                     && !fm.fileExists(atPath: dl.appending(path: "." + clipFile["filename"].string! + ".partial").path), "\(clip.json)")
        precondition(!t2.status.isRecording && clipFile["durationSeconds"] == .number(1), "\(clipFile)")
        print("PASS: tether.files lists the card over the tether connection, download refuses to overwrite and reports missing names, record_clip records, waits for the clip and fetches MP4 + M01.XML")

        let configured = try await call(["tether", "configure", "--live-view", "false", "--auto-import", "false"])
        precondition(configured.json["liveView"].bool == false && !model.tetherAutoImport)
        let off = try await call(["tether", "live-view"])
        precondition(off.json["error"]["code"].string == "live_view_off")
        let stopped = try await call(["tether", "stop"])
        precondition(stopped.code == 0 && stopped.json["active"].bool == false && model.tether == nil)
        print("PASS: CLI configure turns off live view and auto-import; tether stop ends the session")
    }

    @MainActor static func state(_ t: TetherSession) -> [Int64] {
        [0xD21E, 0xD20D, 0x5007].map { t.properties[$0]?.intValue ?? -1 }
    }

    static func run(_ executable: String, args: [String], socket: String, input: Data? = nil) async throws -> (code: Int32, data: Data) {
        try await Task.detached {
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = URL(filePath: executable); process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(["MINIDIT_SOCKET_PATH": socket]) { _, new in new }
            process.standardOutput = output; process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }.value
    }

    @MainActor static func wait(_ what: String, _ done: () -> Bool) async throws {
        for _ in 0..<750 {
            if done() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        print(AppLog.shared.lines.suffix(25).joined(separator: "\n"))
        fatalError("超时：\(what)")
    }
}
