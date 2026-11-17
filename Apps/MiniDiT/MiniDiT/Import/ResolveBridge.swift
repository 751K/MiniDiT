import AppKit
import Darwin
import SonyRemoteKit
import MiniDiTCore

enum ResolveBridge {
    static let bundleIDs = ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"]
    static var appURL: URL? { bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first }
    struct Project: Codable, Sendable, Equatable { var id: String; var name: String }
    struct Result: Codable, Sendable {
        var project: String, projectID: String
        var imported: Int, proxies: Int, skipped: Int, colored: Int, unmanaged: Int, timecodes: Int
        var timecodeWarnings: [String], metadataWarnings: [String], failedPaths: [String], receivedPaths: [String]
        /// 这次新建了 Resolve 项目（同名项目原本不存在）。
        var created: Bool? = nil
    }
    enum Failure: LocalizedError {
        case notInstalled, notReachable, script(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "未找到 DaVinci Resolve，请安装后重试。"
            case .notReachable: "无法连接 DaVinci Resolve。请在 Resolve 的偏好设置中将“外部脚本使用”设为“本地”。"
            case .script(let message): message
            }
        }
    }
    /// Capture XML-derived metadata now, so a retry never reads later settings or replacement sidecars.
    /// `project` 是目标 Resolve 项目名（MiniDiT 项目名）：有同名项目就打开，没有就新建。
    static func payload(_ events: [FCPXMLWriter.Event], setColorSpace: Bool, project: String) throws -> Data {
        let rows = events.map { event in
            ["bin": event.name, "clips": event.clips.map { clip in
                let info = ClipInfo.sidecar(for: clip.url).flatMap(ClipInfo.read)
                return ["path": clip.url.path, "proxy": clip.proxy?.path ?? "", "roll": clip.roll ?? "",
                        "marks": (info?.shotMarks ?? []).map { ["frame": $0.frame, "name": "Shot Mark \($0.shotMark ?? 1)"] as [String: Any] },
                        "timecode": info?.mediaTimecode?.text ?? "", "gamma": info?.gamma ?? "", "primaries": info?.primaries ?? ""] as [String: Any]
            }] as [String: Any]
        }
        return try JSONSerialization.data(withJSONObject: ["events": rows, "color": setColorSpace, "project": project])
    }
    /// 加入目标项目。`expected` 是第一次发送时 Resolve 返回的项目：重试时必须还是它。
    /// 旧记录没有冻结项目名时，用当时记下的项目名。
    @MainActor static func send(_ payload: Data, expected: Project?) async throws -> Result {
        guard var request = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else { throw Failure.script("发送记录无法读取。") }
        request["action"] = "import"
        if let expected { request["projectID"] = expected.id }
        if (request["project"] as? String ?? "").isEmpty, let name = expected?.name { request["project"] = name }
        return try JSONDecoder().decode(Result.self, from: try await self.request(JSONSerialization.data(withJSONObject: request)))
    }
    @MainActor private static func request(_ input: Data) async throws -> Data {
        guard let app = appURL else { throw Failure.notInstalled }
        let lib = app.appending(path: "Contents/Libraries/Fusion/fusionscript.so").path
        let running = bundleIDs.contains { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
        if !running {
            let config = NSWorkspace.OpenConfiguration(); config.activates = false
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
        let deadline = Date().addingTimeInterval(running ? 10 : 120)
        while true {
            try Task.checkCancellation()
            let (code, out, error) = try await run(lib: lib, input: input)
            if code == 0 { return Data(out.utf8) }
            if code != 3 {
                let message = error.isEmpty ? out : error
                throw Failure.script(message.components(separatedBy: .newlines).last(where: { !$0.isEmpty }) ?? "Resolve 未返回发送结果。")
            }
            guard Date() < deadline else { throw Failure.notReachable }
            try await Task.sleep(for: .seconds(2))
        }
    }
    /// File output avoids pipe-buffer deadlocks on large receipts. Only our helper process is stopped.
    private static func run(lib: String, input: Data) async throws -> (Int32, String, String) {
        let root = FileManager.default.temporaryDirectory.appending(path: "minidit-resolve-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appending(path: "request.json"), stdout = root.appending(path: "stdout"), stderr = root.appending(path: "stderr")
        try input.write(to: payload); try Data().write(to: stdout); try Data().write(to: stderr)
        let output = try FileHandle(forWritingTo: stdout), errors = try FileHandle(forWritingTo: stderr)
        let control = ProcessControl()
        let timeout = Task { try? await Task.sleep(for: .seconds(120)); if !Task.isCancelled { control.stop() } }
        defer { timeout.cancel() }
        let result: (Int32, String, String) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process(); process.executableURL = URL(filePath: "/usr/bin/python3")
                process.arguments = ["-I", "-c", script, lib, payload.path]; process.standardOutput = output; process.standardError = errors
                process.terminationHandler = { process in
                    try? output.close(); try? errors.close()
                    let out = (try? String(contentsOf: stdout, encoding: .utf8)) ?? ""
                    let err = (try? String(contentsOf: stderr, encoding: .utf8)) ?? ""
                    continuation.resume(returning: (process.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines), err.trimmingCharacters(in: .whitespacesAndNewlines)))
                }
                do { control.attach(process); try process.run(); control.stopIfRequested() }
                catch { try? output.close(); try? errors.close(); continuation.resume(throwing: error) }
            }
        } onCancel: { control.stop() }
        try Task.checkCancellation()
        if control.stopped { throw Failure.script("等待 Resolve 脚本响应超时；已保存的文件不受影响，可重试。") }
        return result
    }
    private final class ProcessControl: @unchecked Sendable {
        let lock = NSLock(); private var process: Process?; private var requested = false
        var stopped: Bool { lock.withLock { requested } }
        func attach(_ process: Process) { lock.withLock { self.process = process } }
        func stop() { lock.withLock { requested = true }; stopIfRequested() }
        func stopIfRequested() {
            let p = lock.withLock { requested ? process : nil }
            if let p, p.isRunning {
                p.terminate()
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                    if p.isRunning { _ = Darwin.kill(p.processIdentifier, SIGKILL) }
                }
            }
        }
    }
    static let script = #"""
import importlib.machinery, importlib.util, json, sys, os, fcntl, hashlib
lib = sys.argv[1]
loader = importlib.machinery.ExtensionFileLoader("fusionscript", lib)
spec = importlib.util.spec_from_loader("fusionscript", loader)
fs = importlib.util.module_from_spec(spec)
loader.exec_module(fs)
resolve = fs.scriptapp("Resolve")
if not resolve:
    sys.exit(3)
pm = resolve.GetProjectManager()
if not pm:
    sys.exit(3)
with open(sys.argv[2], encoding="utf-8") as f:
    request = json.load(f)
# 目标是与 MiniDiT 项目同名的 Resolve 项目：有就打开，没有就在项目库根目录新建。
target_name = (request.get("project") or "").strip() or "MiniDiT"
expected_id = request.get("projectID", "")

def find_in_folder(name):
    # 从当前文件夹往下逐层找；找到时项目管理器停在它所在的文件夹，LoadProject 才能打开它。
    if name in (pm.GetProjectListInCurrentFolder() or []):
        return True
    for folder in pm.GetFolderListInCurrentFolder() or []:
        if pm.OpenFolder(folder):
            if find_in_folder(name):
                return True
            pm.GotoParentFolder()
    return False

def save_current(current):
    # 切换前保存当前项目，不丢用户的改动；未命名的临时项目不保存。
    if current and current.GetName() != "Untitled Project":
        pm.SaveProject()

def open_target():
    current = pm.GetCurrentProject()
    if current and current.GetName() == target_name and (not expected_id or str(current.GetUniqueId()) == expected_id):
        return current, False
    pm.GotoRootFolder()
    if find_in_folder(target_name):
        save_current(current)
        loaded = pm.LoadProject(target_name)
        if not loaded:
            raise RuntimeError("无法打开 Resolve 项目“%s”，未导入素材。" % target_name)
        return loaded, False
    if expected_id:
        raise RuntimeError("Resolve 中未找到原项目“%s”，未导入素材。" % target_name)
    pm.GotoRootFolder()
    save_current(current)
    made = pm.CreateProject(target_name)
    if not made:
        raise RuntimeError("无法新建 Resolve 项目“%s”，未导入素材。" % target_name)
    return made, True

project, created = open_target()
project_id = str(project.GetUniqueId() or "")
if not project_id:
    raise RuntimeError("Resolve 未提供项目标识，未导入素材。")
if expected_id and project_id != expected_id:
    raise RuntimeError("Resolve 中的“%s”已非原项目，未导入素材。" % target_name)
expected_id = project_id
def check_project():
    current = pm.GetCurrentProject()
    if not current or str(current.GetUniqueId()) != expected_id:
        raise RuntimeError("导入时 Resolve 项目已切换，未向其他项目发送素材；可重试。")
check_project()
# An old helper may outlive an app restart. Serialize retries before inspecting the actual media pool.
lock_root = os.path.expanduser("~/Library/Application Support/MiniDiT/ResolveLocks")
os.makedirs(lock_root, mode=0o700, exist_ok=True)
lock = open(os.path.join(lock_root, hashlib.sha256(project_id.encode()).hexdigest() + ".lock"), "a")
try:
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    print("Resolve 正在处理上一批发送，请稍后重试。", file=sys.stderr)
    sys.exit(4)
check_project()
events = request["events"]
want_color = request.get("color", False)
mp = project.GetMediaPool()
root = mp.GetRootFolder()
imported = proxies = skipped = colored = unmanaged = timecodes = 0
timecode_warnings, metadata_warnings, failed_paths, received_paths = [], [], [], []
mode = project.GetSetting("colorScienceMode") or ""
separate = project.GetSetting("separateColorSpaceAndGamma") == "1"

def identity(path):
    try:
        s = os.stat(path)
        return ("file", s.st_dev, s.st_ino)
    except OSError:
        return ("path", os.path.normpath(os.path.realpath(path)))

def existing_clips(folder):
    result = {}
    for item in folder.GetClipList() or []:
        path = item.GetClipProperty("File Path") or ""
        if path:
            result[identity(path)] = item
    for child in folder.GetSubFolderList() or []:
        result.update(existing_clips(child))
    return result
def plan(gamma, primaries):
    g, pr = gamma.lower(), primaries.lower()
    if "s-log3" in g:
        cine = "cine" in pr
        gamut = "S-Gamut3.Cine" if cine else "S-Gamut3"
        return {"combo": [gamut + "/S-Log3"], "cs": ["Sony " + gamut], "gamma": ["Sony S-Log3", "S-Log3"],
                "idt": ["Sony SLog3 SGamut3Cine" if cine else "Sony SLog3 SGamut3"]}
    if "s-log2" in g:
        return {"combo": ["S-Gamut/S-Log2"], "cs": ["Sony S-Gamut"], "gamma": ["Sony S-Log2", "S-Log2"], "idt": ["Sony SLog2 SGamut"]}
    if "hlg" in g:
        return {"combo": ["Rec.2100 HLG"], "cs": ["Rec.2020"], "gamma": ["Rec.2100 HLG"], "idt": []}
    return None

def first(item, key, values):
    return any(item.SetClipProperty(key, v) for v in values)

def set_color(item, c):
    global colored, unmanaged
    pl = plan(c.get("gamma", ""), c.get("primaries", "")) if want_color else None
    if not pl:
        return
    if mode.startswith("aces"):
        ok = first(item, "IDT", pl["idt"])
    elif "ColorManaged" in mode:
        if separate:
            ok = first(item, "Input Color Space", pl["cs"])
            ok = first(item, "Input Gamma", pl["gamma"]) and ok
        else:
            ok = first(item, "Input Color Space", pl["combo"])
    else:
        unmanaged += 1
        return
    if ok:
        colored += 1
    else:
        metadata_warnings.append(c.get("path", "") + ": 输入色彩空间设置失败")

def check_timecode(item, c):
    global timecodes
    tc = c.get("timecode", "")
    if not tc:
        return
    # 原片能自行读出时保持原样；否则补入 Clip Attributes，且读回确认。
    current = item.GetClipProperty("Start TC") or ""
    drop = "1" if ";" in tc else "0"
    if str(item.GetClipProperty("Drop frame")) != drop:
        item.SetClipProperty("Drop frame", drop)
    if current != tc:
        item.SetClipProperty("Start TC", tc)
        current = item.GetClipProperty("Start TC") or ""
    if current == tc and str(item.GetClipProperty("Drop frame")) == drop:
        timecodes += 1
    else:
        timecode_warnings.append(c.get("path", "").rsplit("/", 1)[-1] + ": " + tc + " → " + current)

existing = existing_clips(root)
for e in events:
    check_project()
    todo = [c for c in e["clips"] if identity(c["path"]) not in existing]
    had = set(existing)
    if todo:
        folder = next((f for f in (root.GetSubFolderList() or []) if f.GetName() == e["bin"]), None) or mp.AddSubFolder(root, e["bin"])
        if folder and mp.SetCurrentFolder(folder):
            try:
                mp.ImportMedia([c["path"] for c in todo])
            except Exception as error:
                metadata_warnings.append("部分素材加入时出现错误：" + str(error))
        existing = existing_clips(root)
    for c in e["clips"]:
        check_project()
        item = existing.get(identity(c["path"]))
        if not item:
            failed_paths.append(c["path"])
            continue
        received_paths.append(c["path"])
        if identity(c["path"]) in had:
            skipped += 1
        else:
            imported += 1
        try:
            check_timecode(item, c)
            set_color(item, c)
            markers = item.GetMarkers() or {}
            for m in c.get("marks", []):
                frame = m["frame"]
                previous = markers.get(frame, markers.get(str(frame)))
                if previous:
                    if previous.get("name") != m["name"]:
                        metadata_warnings.append(c["path"] + ": 标记位置已被使用，保留了原标记")
                elif not item.AddMarker(frame, "Blue", m["name"], "", 1):
                    metadata_warnings.append(c["path"] + ": 拍摄标记未能加入")
            if c.get("roll") and not item.SetMetadata({"Reel Number": c["roll"], "Roll Card #": c["roll"]}):
                metadata_warnings.append(c["path"] + ": 卷号未能写入")
            proxy = c.get("proxy", "")
            if proxy:
                if not item.GetClipProperty("Proxy Media Path"):
                    item.LinkProxyMedia(proxy)
                if identity(item.GetClipProperty("Proxy Media Path") or "") == identity(proxy):
                    proxies += 1
                else:
                    metadata_warnings.append(c["path"] + ": 代理未能链接")
        except Exception as error:
            metadata_warnings.append(c["path"] + ": " + str(error))
check_project()
pm.SaveProject()
print(json.dumps({"project": project.GetName(), "projectID": project_id, "created": created, "imported": imported, "proxies": proxies, "skipped": skipped,
                  "colored": colored, "unmanaged": unmanaged, "timecodes": timecodes, "timecodeWarnings": timecode_warnings,
                  "metadataWarnings": metadata_warnings, "failedPaths": failed_paths, "receivedPaths": received_paths}))
"""#
}
