import Foundation
import SonyRemoteKit

// SSH 访问身份验证的端到端测试：通过 SSH 隧道连接模拟相机，走完浏览存储卡、下载、遥控拍照的完整流程。
// 由 Scripts/test-ssh-e2e.sh 启动（它会先起模拟相机和测试 SSH 服务器）。
// 用法：ssh-e2e <SSH 端口> <用户名> <密码> <期望的 SHA256 指纹>

let args = CommandLine.arguments
guard args.count == 5, let sshPort = UInt16(args[1]) else {
    print("用法：ssh-e2e <SSH 端口> <用户名> <密码> <SHA256 指纹>")
    exit(2)
}
let user = args[2], password = args[3], expectedFP = args[4]
let host = "127.0.0.1"
let identity = PTPIPHostIdentity.random(name: "ssh-e2e")

var failures = 0
@MainActor func check(_ ok: Bool, _ what: String) {
    print(ok ? "PASS  \(what)" : "FAIL  \(what)")
    if !ok { failures += 1 }
}

final class Seen: @unchecked Sendable { var fp: String? }

// 1. 指纹不符时不发送密码、直接中止。
do {
    _ = try await CameraSSHTunnel.open(host: host, port: sshPort, credentials: SSHCredentials(username: user, password: password)) { _ in false }
    check(false, "拒绝指纹时应中止连接")
} catch SSHTunnelError.hostKeyRejected {
    check(true, "拒绝指纹时中止连接（没有发送密码）")
} catch {
    check(false, "拒绝指纹时报错类型不对：\(error)")
}

// 2. 密码错误。
do {
    _ = try await CameraSSHTunnel.open(host: host, port: sshPort, credentials: SSHCredentials(username: user, password: "wrong")) { _ in true }
    check(false, "错误密码应被拒绝")
} catch let e as SSHTunnelError {
    if case .authenticationFailed = e { check(true, "错误密码被拒绝：\(e.localizedDescription)") }
    else { check(false, "错误密码报错类型不对：\(e)") }
}

// 3. 只握手：读出指纹和加密方式。
let (probeKey, probeAlg) = try await CameraSSHTunnel.probe(host: host, port: sshPort)
check(probeKey.sha256Base64 == expectedFP, "握手读出的指纹与服务器一致（\(probeKey.keyType) \(probeKey.sha256Base64)）")
check(probeAlg.authMethodsOffered.contains("keyboard-interactive"), "服务器提供键盘交互登录（\(probeAlg.authMethodsOffered)）")

// 4. 浏览存储卡（内容传输模式）。
let seen = Seen()
let tunnel = try await CameraSSHTunnel.open(host: host, port: sshPort,
                                            credentials: SSHCredentials(username: user, password: password)) { key in
    seen.fp = key.sha256Base64
    return key.sha256Base64 == expectedFP
}
check(seen.fp == expectedFP, "登录前校验了指纹")
check(tunnel.negotiated?.cipherCS == "aes128-ctr", "加密方式 aes128-ctr（\(tunnel.negotiated?.description ?? "?")）")
check(tunnel.negotiated?.authMethodUsed == "keyboard-interactive", "用键盘交互方式登录")

let lib = try await SonyContentsTransfer.openLibrary(host: host, identity: identity, tunnel: tunnel)
let folders = try await lib.folders()
check(folders.count >= 2, "通过隧道列出文件夹：\(folders.map(\.name))")
if let folder = folders.first {
    let handles = try await lib.handles(in: folder)
    let item = try await lib.item(handles[0])
    let thumb = try await lib.thumbnail(handles[0])
    check(thumb.map { $0.count > 100 } ?? false, "读到缩略图（\(thumb?.count ?? 0) 字节）")
    let url = FileManager.default.temporaryDirectory.appending(path: "ssh-e2e-\(UUID().uuidString)")
    let start = Date()
    try await lib.download(item, to: url) { _, _ in }
    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    let secs = Date().timeIntervalSince(start)
    check(size == item.size, String(format: "下载 %@ 完整（%llu 字节，%.2f 秒）", item.filename, size, secs))
    try? FileManager.default.removeItem(at: url)
}
await lib.close()

// 5. 遥控拍摄（新的隧道）：取景、拍照、下载。
let tunnel2 = try await CameraSSHTunnel.open(host: host, port: sshPort,
                                             credentials: SSHCredentials(username: user, password: password)) { $0.sha256Base64 == expectedFP }
let cam = try await SonyCamera.connect(host: host, identity: identity, tunnel: tunnel2, startupDelay: 0)
check(await cam.displayName == "ILCE-7M4", "通过隧道完成遥控握手（\(await cam.displayName)）")
let status = try await cam.refreshStatus()
check(!status.settings.isEmpty, "读到曝光参数：\(status.settings.map(\.valueText))")
var frames = 0
let lvStart = Date()
while Date().timeIntervalSince(lvStart) < 2 {
    if try await cam.liveViewFrame() != nil { frames += 1 }
}
check(frames > 10, "取景 2 秒收到 \(frames) 帧")
try await cam.capture()
let files = try await cam.downloadPendingFiles()
check(files.count == 1 && files[0].data.count > 1000, "拍照并下载：\(files.map { "\($0.filename) \($0.data.count) 字节" })")
await cam.disconnect()

print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
