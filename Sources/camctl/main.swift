import Foundation
import Security
import SonyRemoteKit
#if canImport(Darwin)
import Darwin
#endif

// camctl：索尼相机控制工具。目前只有只读的 `props`，用来摸清机身提供哪些属性。
// 每条命令向 stdout 输出一个 JSON 对象；失败时退出码非零，输出 {"error": "...", "code": "..."}。

setvbuf(stdout, nil, _IOLBF, 0)

struct Failure: Error { let code: String; let message: String }

func fail(_ code: String, _ message: String) -> Never {
    let obj: [String: String] = ["error": message, "code": code]
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) {
        FileHandle.standardOutput.write(d + Data([10]))
    }
    exit(code == "usage" ? 2 : 1)
}

func note(_ s: String) { FileHandle.standardError.write(Data("camctl: \(s)\n".utf8)) }

let usage = """
camctl props --host HOST [--port 15740] [--user USER] [--raw-out FILE]

  Read-only. Connects in remote-control mode (enable "PC Remote" on the camera), lists every
  property the camera reports, then disconnects. Writes no properties.
  --user        Access-authentication user (camera uses SSH). Password from CAMCTL_PASSWORD or prompt.
                Without --user, a camera that only offers SSH is opened with the credentials MiniDiT
                saved in the login keychain (macOS asks you to allow access the first time).
  --raw-out     Also save the raw 0x9209 / 0x9202 responses (FILE and FILE.ext) for offline checking.
"""

// MARK: 参数

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first, !["-h", "--help", "help"].contains(command) else { print(usage); exit(0) }
args.removeFirst()
var options: [String: String] = [:]
while !args.isEmpty {
    let k = args.removeFirst()
    guard k.hasPrefix("--"), !args.isEmpty else { fail("usage", "bad argument \(k)\n\(usage)") }
    options[String(k.dropFirst(2))] = args.removeFirst()
}
guard command == "props" else { fail("usage", "unknown command \(command); only `props` exists so far") }
guard let host = options["host"] else { fail("usage", "--host is required") }
let port = options["port"].flatMap(UInt16.init) ?? PTPIPClient.defaultPort

// MARK: 本机身份与指纹（~/Library/Application Support/camctl/）

let support = URL.applicationSupportDirectory.appending(path: "camctl", directoryHint: .isDirectory)
try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

/// 相机按 GUID 记住电脑；固定下来，免得每次都像一台新电脑。
func loadIdentity() -> PTPIPHostIdentity {
    let url = support.appending(path: "identity.json")
    if let d = try? Data(contentsOf: url), let hex = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
       hex.count == 32 {
        let bytes = stride(from: 0, to: 32, by: 2).compactMap { i -> UInt8? in
            let s = hex.index(hex.startIndex, offsetBy: i)
            return UInt8(hex[s..<hex.index(s, offsetBy: 2)], radix: 16)
        }
        if bytes.count == 16 { return PTPIPHostIdentity(guid: bytes, friendlyName: "camctl") }
    }
    let id = PTPIPHostIdentity.random(name: "camctl")
    try? Data(id.guid.map { String(format: "%02x", $0) }.joined().utf8).write(to: url)
    return id
}

/// SSH 指纹：第一次连接记下来，之后不一致就拒绝。
@Sendable func checkFingerprint(_ key: SSHHostKeyInfo, host: String, dir: URL) -> Bool {
    let url = dir.appending(path: "known_hosts.json")
    var known = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    if let old = known[host] {
        if old != key.sha256Base64 { note("host key for \(host) changed (was \(old), now \(key.sha256Base64)); refusing") }
        return old == key.sha256Base64
    }
    known[host] = key.sha256Base64
    try? JSONEncoder().encode(known).write(to: url)
    note("trusting \(host) key \(key.keyType) SHA256:\(key.sha256Base64) (first use)")
    return true
}

/// MiniDiT 保存的相机登录（钥匙串通用密码，服务 com.kong.SonyImport.camera-ssh，账户 = SSH 指纹）。
/// 密码只在本进程里用来建立加密连接，不输出、不写日志。
func minidItCredentials(fingerprint: String) -> SSHCredentials? {
    let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                            kSecAttrService as String: "com.kong.SonyImport.camera-ssh",
                            kSecAttrAccount as String: fingerprint,
                            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
    return try? JSONDecoder().decode(SSHCredentials.self, from: data)
}

// MARK: 可读名称和数值

let names: [UInt16: String] = [
    0x5005: "WhiteBalance", 0x5007: "FNumber", 0x500A: "FocusMode", 0x500E: "ExposureProgramMode",
    0x5010: "ExposureBiasCompensation", 0x5013: "StillCaptureMode", 0xD203: "ImageSize", 0xD20D: "ShutterSpeed",
    0xD20E: "BatteryLevelIndicator", 0xD20F: "ColorTemp", 0xD211: "AspectRatio", 0xD213: "FocusFound",
    0xD215: "ObjectInMemory", 0xD218: "BatteryLevel", 0xD21D: "MovieRecordingState", 0xD21E: "ISO",
    0xD221: "LiveViewStatus", 0xD222: "StillImageStoreDestination", 0xD224: "ExposureCompensation",
    0xD226: "ISO2", 0xD231: "LiveViewSettingEffect", 0xD248: "Slot1Status", 0xD249: "Slot1RemainingShots",
    0xD24A: "Slot1RemainingTime", 0xD251: "DeviceOverheatStatus", 0xD252: "JpegQuality", 0xD253: "CompressionSetting",
    0xD25A: "PriorityMode", 0xD264: "RemoteControlRestrictionStatus", 0xD268: "PcSaveImageSize",
    0xD269: "PcSaveImageFormat", 0xD26A: "LiveViewImageQuality", 0xD295: "ContentsTransferEnabled",
]

func readable(_ code: UInt16, _ v: Int64) -> String? { SonyPropertyCatalog.label(code, v) }

func typeName(_ t: PTPDataType) -> String {
    switch t {
    case .undefined: "UNDEF"
    case .int8: "INT8"; case .uint8: "UINT8"; case .int16: "INT16"; case .uint16: "UINT16"
    case .int32: "INT32"; case .uint32: "UINT32"; case .int64: "INT64"; case .uint64: "UINT64"
    case .int128: "INT128"; case .uint128: "UINT128"
    case .aint8: "AINT8"; case .auint8: "AUINT8"; case .aint16: "AINT16"; case .auint16: "AUINT16"
    case .aint32: "AINT32"; case .auint32: "AUINT32"; case .aint64: "AINT64"; case .auint64: "AUINT64"
    case .string: "STR"
    }
}

func hex(_ c: UInt16) -> String { String(format: "0x%04X", c) }

func value(_ code: UInt16, _ v: PTPValue) -> Any {
    switch v {
    case .int(let n):
        var o: [String: Any] = ["raw": n, "hex": String(format: "0x%llX", UInt64(bitPattern: n))]
        if let r = readable(code, n) { o["readable"] = r }
        return o
    case .string(let s): return ["raw": s]
    case .array(let a): return ["raw": a]
    case .none: return NSNull()
    }
}

// MARK: 读取

let identity = loadIdentity()
let result: SonyPropertyDump
do {
    var tunnel: CameraSSHTunnel?
    if options["user"] == nil, port == PTPIPClient.defaultPort, !(await CameraDiscovery.probe(host: host, port: port, timeout: 1.5)) {
        // 没开直连端口：相机开了访问认证。用 MiniDiT 存在钥匙串里的这台相机的账号（按 SSH 指纹找）。
        guard let (key, _) = try? await CameraSSHTunnel.probe(host: host, timeout: 5) else {
            fail("connection_failed", "no camera at \(host): ports 15740 and 22 are both unreachable")
        }
        guard let saved = minidItCredentials(fingerprint: key.sha256Base64) else {
            fail("auth_required", "camera uses access authentication and MiniDiT has no saved login for it (or keychain access was denied); pass --user")
        }
        guard saved.trustedFingerprint == nil || saved.trustedFingerprint == key.sha256Base64 else {
            fail("fingerprint_mismatch", "camera host key differs from the one MiniDiT trusted")
        }
        note("using MiniDiT's saved login for SHA256:\(key.sha256Base64)")
        let expected = key.sha256Base64
        tunnel = try await CameraSSHTunnel.open(host: host, credentials: saved) { $0.sha256Base64 == expected }
    } else if let user = options["user"] {
        var password = ProcessInfo.processInfo.environment["CAMCTL_PASSWORD"] ?? ""
        if password.isEmpty, let p = getpass("camera password for \(user)@\(host): ") { password = String(cString: p) }
        let h = host, dir = support
        tunnel = try await CameraSSHTunnel.open(host: host, credentials: SSHCredentials(username: user, password: password)) { key in
            checkFingerprint(key, host: h, dir: dir)
        }
    }
    result = try await SonyPropertyDump.read(host: host, port: port, identity: identity, tunnel: tunnel) { note($0) }
} catch let e as SSHTunnelError {
    if case .authenticationFailed = e { fail("auth_failed", "access authentication failed: \(e)") }
    fail("connection_failed", "\(e)")
} catch PTPIPTransportError.initFailed(let reason) {
    fail("connection_refused", "camera refused the PTP/IP session (reason 0x\(String(reason, radix: 16))); is PC Remote on and no other device connected?")
} catch let e as SonyCameraError {
    fail("not_remote_capable", e.localizedDescription)
} catch {
    fail("connection_failed", "\(error)")
}

if let path = options["raw-out"] {
    do {
        try result.raw.write(to: URL(filePath: path), options: .withoutOverwriting)
        try result.rawExtDeviceInfo.write(to: URL(filePath: path + ".ext"), options: .withoutOverwriting)
    } catch { fail("write_failed", "could not write raw dump (existing files are never overwritten): \(error)") }
}

let advertised = Set(result.advertisedProperties)
let parsedCodes = Set(result.entries.map(\.desc.code))
let props: [[String: Any]] = result.entries.map { e in
    let d = e.desc
    var o: [String: Any] = [
        "code": hex(d.code), "dataType": typeName(d.dataType), "getSet": Int(d.getSet), "isEnabled": Int(d.isEnabled),
        "writable": d.isWritable, "current": value(d.code, d.current), "default": value(d.code, d.factoryDefault),
        "advertised": advertised.contains(d.code), "offset": e.offset, "length": e.length,
    ]
    o["name"] = names[d.code] ?? NSNull()
    o["sdkName"] = SonyPropertyCatalog.sdkPropertyNames[d.code] ?? NSNull()
    switch d.form {
    case .none: o["form"] = ["type": "none"]
    case let .range(lo, hi, step): o["form"] = ["type": "range", "min": lo, "max": hi, "step": step]
    case .enumeration(let list): o["form"] = ["type": "enum", "values": list.map { value(d.code, .int($0)) }]
    }
    return o
}
var out: [String: Any] = [
    "host": host,
    "protocolVersion": hex(result.protocolVersion),
    "declaredCount": result.declaredCount ?? NSNull(),
    "parsedCount": result.entries.count,
    "parseError": result.parseError ?? NSNull(),
    "advertisedPropertyCount": result.advertisedProperties.count,
    "advertisedButNotReported": result.advertisedProperties.filter { !parsedCodes.contains($0) }.map { c -> [String: Any] in
        ["code": hex(c), "sdkName": SonyPropertyCatalog.sdkPropertyNames[c] ?? NSNull()] },
    "controls": result.advertisedControls.map { c -> [String: Any] in
        ["code": hex(c), "sdkName": SonyPropertyCatalog.sdkControlNames[UInt32(c)] ?? NSNull()] },
    "capabilities": result.capabilities,
    "properties": props,
]
if let i = result.deviceInfo {
    out["camera"] = ["manufacturer": i.manufacturer, "model": i.model, "firmware": i.version, "serialNumber": i.serialNumber]
}
if let path = options["raw-out"] { out["rawFiles"] = [path, path + ".ext"] }
do {
    let d = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(d + Data([10]))
} catch {
    fail("encode_failed", "\(error)")
}
