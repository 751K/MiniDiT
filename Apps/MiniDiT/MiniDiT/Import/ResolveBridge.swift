import AppKit
import SonyRemoteKit

/// 导入的视频加进 DaVinci Resolve：通过 Resolve 的外部脚本接口（系统自带的 python3 加载 Resolve 里的 fusionscript），
/// 在当前打开的项目里每个视频文件夹建一个媒体夹（已有同名的就用它），导入片段；
/// Resolve 会自动认出旁边「Proxy」文件夹里的同名代理，没认出的再手动链接。
/// 按片段 XML 里记录的伽马 / 色域写上输入色彩空间（S-Log3、S-Log2、HLG），不套 LUT；
/// 项目要开着色彩管理（RCM 或 ACES）才写得进去，没开的不动项目设置，只在结果里说明。
/// Resolve 没开时先打开它，等它能接受脚本。
enum ResolveBridge {
    static let bundleIDs = ["com.blackmagic-design.DaVinciResolve", "com.blackmagic-design.DaVinciResolveLite"]

    static var appURL: URL? {
        bundleIDs.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    struct Result: Decodable {
        let project: String
        let imported: Int
        let proxies: Int
        let skipped: Int
        /// 写上了输入色彩空间的片段数。
        let colored: Int
        /// 是 Log / HLG、但项目没开色彩管理而没写的片段数。
        let unmanaged: Int
    }

    enum Failure: LocalizedError {
        case notInstalled, notReachable, script(String)
        var errorDescription: String? {
            switch self {
            case .notInstalled: "未找到 DaVinci Resolve"
            case .notReachable: "DaVinci Resolve 没有响应脚本：请在 Resolve 的“偏好设置 › 系统 › 常规”中把“外部脚本使用”设为“本地”"
            case .script(let s): s
            }
        }
    }

    /// 在后台跑，可能要等 Resolve 启动（最多 2 分钟）。
    static func send(_ events: [FCPXMLWriter.Event], setColorSpace: Bool) async throws -> Result {
        guard let app = appURL else { throw Failure.notInstalled }
        let lib = app.appending(path: "Contents/Libraries/Fusion/fusionscript.so").path
        let payload = events.map { e in
            ["bin": e.name, "clips": e.clips.map { c in
                let info = ClipInfo.sidecar(for: c.url).flatMap(ClipInfo.read)
                return ["path": c.url.path, "proxy": c.proxy?.path ?? "", "roll": c.roll ?? "",
                        "marks": (info?.shotMarks ?? []).map { ["frame": $0.frame, "name": "Shot Mark \($0.shotMark ?? 1)"] as [String: Any] },
                        "gamma": info?.gamma ?? "", "primaries": info?.primaries ?? ""]
            }] as [String: Any]
        }
        let input = try JSONSerialization.data(withJSONObject: ["events": payload, "color": setColorSpace] as [String: Any])
        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIDs[0]).isEmpty
            || !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIDs[1]).isEmpty
        if !running {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: cfg)
        }
        // 刚启动的 Resolve 要过一阵才接脚本，隔几秒试一次。
        let deadline = Date().addingTimeInterval(running ? 10 : 120)
        while true {
            let (code, out, err) = try await run(lib: lib, input: input)
            if code == 0, let r = try? JSONDecoder().decode(Result.self, from: Data(out.utf8)) { return r }
            if code != 3 { throw Failure.script(err.isEmpty ? out : err) }
            if Date() > deadline { throw Failure.notReachable }
            try await Task.sleep(for: .seconds(3))
        }
    }

    private static func run(lib: String, input: Data) async throws -> (Int32, String, String) {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/python3")
            p.arguments = ["-I", "-c", script, lib]
            let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe
            p.standardOutput = outPipe
            p.standardError = errPipe
            p.terminationHandler = { p in
                let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                cont.resume(returning: (p.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines),
                                        err.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            do {
                try p.run()
                inPipe.fileHandleForWriting.write(input)
                try? inPipe.fileHandleForWriting.close()
            } catch { cont.resume(throwing: error) }
        }
    }

    /// 退出码 3：Resolve 还连不上（没开 / 还在启动 / 没开外部脚本）。
    private static let script = #"""
import importlib.machinery, importlib.util, json, sys
lib = sys.argv[1]
loader = importlib.machinery.ExtensionFileLoader("fusionscript", lib)
spec = importlib.util.spec_from_file_location("fusionscript", lib, loader=loader)
fs = importlib.util.module_from_spec(spec)
loader.exec_module(fs)
resolve = fs.scriptapp("Resolve")
if not resolve:
    sys.exit(3)
project = resolve.GetProjectManager().GetCurrentProject()
if not project:
    sys.exit(3)
request = json.load(sys.stdin)
events = request["events"]
want_color = request.get("color", False)
mp = project.GetMediaPool()
root = mp.GetRootFolder()
imported = proxies = skipped = colored = unmanaged = 0
mode = project.GetSetting("colorScienceMode") or ""
separate = project.GetSetting("separateColorSpaceAndGamma") == "1"

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
            first(item, "Input Gamma", pl["gamma"])
        else:
            ok = first(item, "Input Color Space", pl["combo"])
    else:
        unmanaged += 1
        return
    if ok:
        colored += 1
for e in events:
    folder = next((f for f in (root.GetSubFolderList() or []) if f.GetName() == e["bin"]), None) or mp.AddSubFolder(root, e["bin"])
    have = {c.GetClipProperty("File Path") for c in (folder.GetClipList() or [])}
    todo = [c for c in e["clips"] if c["path"] not in have]
    skipped += len(e["clips"]) - len(todo)
    if not todo:
        continue
    mp.SetCurrentFolder(folder)
    items = mp.ImportMedia([c["path"] for c in todo]) or []
    imported += len(items)
    by_path = {c["path"]: c for c in todo}
    for it in items:
        c = by_path.get(it.GetClipProperty("File Path"), {})
        set_color(it, c)
        for m in c.get("marks", []):
            # Shot Mark → 片段标记（蓝色，一帧长）。
            it.AddMarker(m["frame"], "Blue", m["name"], "", 1)
        if c.get("roll"):
            # Reel Name 由项目设置从文件名推出来，改不了；卷号写进元数据的 Reel Number 和 Roll Card #。
            it.SetMetadata({"Reel Number": c["roll"], "Roll Card #": c["roll"]})
        p = c.get("proxy", "")
        if not p:
            continue
        if not it.GetClipProperty("Proxy Media Path"):
            it.LinkProxyMedia(p)
        if it.GetClipProperty("Proxy Media Path"):
            proxies += 1
print(json.dumps({"project": project.GetName(), "imported": imported, "proxies": proxies, "skipped": skipped,
                  "colored": colored, "unmanaged": unmanaged}))
"""#
}
