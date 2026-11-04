// 改编自 SSH 可行性原型（ssh-spike）。所有 libssh2 调用都在一个专用线程上执行，
// 相机的命令通道和事件通道复用同一个 SSH 会话（两个 direct-tcpip 通道到 localhost:15740）。
import CLibssh2
import CryptoKit
import Darwin
import Foundation

public enum SSHTunnelError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    case resolve(String)
    case connect(String)
    case connectTimeout
    case handshake(String)
    case hostKeyRejected
    case noSupportedAuthMethod(offered: String)
    case authenticationFailed(String)
    case channelOpen(String)
    case io(String)
    case closed

    public var description: String {
        switch self {
        case .resolve(let s): "resolve: \(s)"
        case .connect(let s): "connect: \(s)"
        case .connectTimeout: "connect timeout"
        case .handshake(let s): "handshake: \(s)"
        case .hostKeyRejected: "host key rejected by validator"
        case .noSupportedAuthMethod(let s): "server offers no password/keyboard-interactive (offered: \(s))"
        case .authenticationFailed(let s): "authentication failed: \(s)"
        case .channelOpen(let s): "direct-tcpip open failed: \(s)"
        case .io(let s): "io: \(s)"
        case .closed: "closed"
        }
    }

    public var errorDescription: String? {
        switch self {
        case .resolve, .connect: "连不上相机的 SSH 端口（22）。请确认手机连着相机的 Wi-Fi。（\(description)）"
        case .connectTimeout: "连接相机的 SSH 端口超时。"
        case .handshake(let s): "与相机建立加密连接失败：\(s)"
        case .hostKeyRejected: "相机指纹未确认，已取消连接。"
        case .noSupportedAuthMethod(let s): "相机不支持密码登录（支持：\(s)）。"
        case .authenticationFailed: "相机拒绝了登录。请核对相机「访问身份验证设置」里的用户名和密码。"
        case .channelOpen(let s): "相机拒绝了遥控通道：\(s)。请确认相机已开启「遥控拍摄」。"
        case .io(let s): "加密连接出错：\(s)"
        case .closed: "加密连接已断开。"
        }
    }
}

/// What the validator sees. `sha256Base64` matches `ssh-keygen -l` (OpenSSH default),
/// `md5Hex` matches `ssh-keygen -l -E md5` / older UIs.
public struct SSHHostKeyInfo: Sendable, CustomStringConvertible {
    public let keyType: String
    public let blob: Data
    public init(keyType: String, blob: Data) { self.keyType = keyType; self.blob = blob }
    public var sha256Base64: String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().replacingOccurrences(of: "=", with: "")
    }
    public var sha256Hex: String { SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined(separator: ":") }
    public var md5Hex: String { "MD5:" + Insecure.MD5.hash(data: blob).map { String(format: "%02x", $0) }.joined(separator: ":") }
    public var description: String { "\(keyType) \(sha256Base64) \(md5Hex)" }
}

public struct SSHAlgorithmPreferences: Sendable {
    /// libssh2 comma lists (nil = libssh2 default list).
    public var kex: String?
    public var hostKey: String?
    public var cipher: String?
    public var mac: String?
    public init(kex: String? = nil, hostKey: String? = nil, cipher: String? = nil, mac: String? = nil) {
        self.kex = kex; self.hostKey = hostKey; self.cipher = cipher; self.mac = mac
    }
    /// What the Sony tunnel uses per sony-alpha-python: `ssh -c aes128-ctr`. Fall back to others if the camera offers them.
    public static let sony = SSHAlgorithmPreferences(cipher: "aes128-ctr,aes256-ctr,aes128-gcm@openssh.com,aes256-gcm@openssh.com")
}

public struct SSHNegotiated: Sendable, CustomStringConvertible {
    public let kex, hostKey, cipherCS, cipherSC, macCS, macSC: String
    public let authMethodsOffered: String
    public let authMethodUsed: String
    public var description: String {
        "kex=\(kex) hostkey=\(hostKey) cipher=\(cipherCS)/\(cipherSC) mac=\(macCS)/\(macSC) auth-offered=\(authMethodsOffered) auth-used=\(authMethodUsed)"
    }
}

/// Holds data reachable from libssh2's C callbacks via the session "abstract" pointer.
final class CallbackContext {
    var username: String = ""
    var password: String = ""
    var promptsSeen: [String] = []
    var rounds = 0
}

private let libssh2Initialized: Int32 = libssh2_init(0)

/// One SSH connection to the camera. All libssh2 calls happen on one private thread.
/// Multiple `direct-tcpip` channels (PTP/IP command + event) are multiplexed over it.
public final class SSHSession: @unchecked Sendable {
    public let host: String
    public let port: UInt16
    public private(set) var negotiated: SSHNegotiated?
    public private(set) var hostKey: SSHHostKeyInfo?

    private var sock: Int32 = -1
    private var session: OpaquePointer?
    private let ctx = CallbackContext()
    private let ctxBox: Unmanaged<CallbackContext>

    // I/O loop state, guarded by `lock`.
    private let lock = NSLock()
    private var newOps: [Op] = []
    private var stopped = false
    private var wakeRead: Int32 = -1
    private var wakeWrite: Int32 = -1
    private var thread: Thread?
    private let setupQueue = DispatchQueue(label: "sshsession.setup")

    public init(host: String, port: UInt16 = 22) {
        _ = libssh2Initialized
        self.host = host
        self.port = port
        ctxBox = Unmanaged.passRetained(ctx)
    }

    deinit {
        ctxBox.release()
    }

    // MARK: - Connect

    /// 1) TCP connect + SSH handshake, 2) host key validator (async, can show UI), 3) auth, 4) start I/O loop.
    public func connect(
        username: String,
        password: String,
        algorithms: SSHAlgorithmPreferences = .sony,
        timeout: TimeInterval = 10,
        validateHostKey: @Sendable (SSHHostKeyInfo) async -> Bool
    ) async throws {
        let key = try await onSetupQueue { try self.tcpAndHandshake(algorithms: algorithms, timeout: timeout) }
        hostKey = key
        guard await validateHostKey(key) else {
            await onSetupQueue { self.teardown(reason: "host key rejected") }
            throw SSHTunnelError.hostKeyRejected
        }
        do {
            try await onSetupQueue { try self.authenticate(username: username, password: password) }
        } catch {
            await onSetupQueue { self.teardown(reason: "auth failed") }
            throw error
        }
        startLoop()
    }

    /// Handshake + `userauth_list` (the SSH "none" method) only: reports algorithms, host key and offered
    /// auth methods without sending any credential. Useful as a camera diagnostics screen.
    public func probe(username: String, algorithms: SSHAlgorithmPreferences = .sony, timeout: TimeInterval = 10) async throws -> (SSHHostKeyInfo, SSHNegotiated) {
        try await onSetupQueue {
            defer { self.teardown(reason: "probe") }
            let key = try self.tcpAndHandshake(algorithms: algorithms, timeout: timeout)
            let s = self.session!
            let offered = libssh2_userauth_list(s, username, UInt32(username.utf8.count)).map { String(cString: $0) } ?? ""
            func m(_ t: Int32) -> String { libssh2_session_methods(s, t).map { String(cString: $0) } ?? "?" }
            return (key, SSHNegotiated(kex: m(LIBSSH2_METHOD_KEX), hostKey: m(LIBSSH2_METHOD_HOSTKEY),
                                       cipherCS: m(LIBSSH2_METHOD_CRYPT_CS), cipherSC: m(LIBSSH2_METHOD_CRYPT_SC),
                                       macCS: m(LIBSSH2_METHOD_MAC_CS), macSC: m(LIBSSH2_METHOD_MAC_SC),
                                       authMethodsOffered: offered, authMethodUsed: "none (probe)"))
        }
    }

    private func onSetupQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            setupQueue.async { cont.resume(with: Result { try body() }) }
        }
    }

    private func onSetupQueue(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { cont in setupQueue.async { body(); cont.resume() } }
    }

    private func lastError() -> String {
        guard let session else { return "no session" }
        var msg: UnsafeMutablePointer<CChar>?
        var len: Int32 = 0
        let code = libssh2_session_last_error(session, &msg, &len, 0)
        return "\(code) \(msg.map { String(cString: $0) } ?? "")"
    }

    private func tcpAndHandshake(algorithms: SSHAlgorithmPreferences, timeout: TimeInterval) throws -> SSHHostKeyInfo {
        sock = try Self.tcpConnect(host: host, port: port, timeout: timeout)
        guard let s = libssh2_session_init_ex(nil, nil, nil, ctxBox.toOpaque()) else {
            throw SSHTunnelError.handshake("libssh2_session_init_ex failed")
        }
        session = s
        libssh2_session_set_blocking(s, 1)
        libssh2_session_set_timeout(s, Int(timeout * 1000))
        func pref(_ m: Int32, _ v: String?) throws {
            guard let v else { return }
            let rc = libssh2_session_method_pref(s, m, v)
            if rc != 0 { throw SSHTunnelError.handshake("method_pref(\(m), \(v)): \(lastError())") }
        }
        try pref(LIBSSH2_METHOD_KEX, algorithms.kex)
        try pref(LIBSSH2_METHOD_HOSTKEY, algorithms.hostKey)
        try pref(LIBSSH2_METHOD_CRYPT_CS, algorithms.cipher)
        try pref(LIBSSH2_METHOD_CRYPT_SC, algorithms.cipher)
        try pref(LIBSSH2_METHOD_MAC_CS, algorithms.mac)
        try pref(LIBSSH2_METHOD_MAC_SC, algorithms.mac)
        if libssh2_session_handshake(s, libssh2_socket_t(sock)) != 0 {
            throw SSHTunnelError.handshake(lastError())
        }
        var len = 0
        var type: Int32 = 0
        guard let raw = libssh2_session_hostkey(s, &len, &type) else {
            throw SSHTunnelError.handshake("no host key: \(lastError())")
        }
        let blob = Data(bytes: raw, count: len)
        // The key-type string is the first SSH string inside the blob.
        var keyType = "type\(type)"
        if blob.count > 4 {
            let n = Int(blob[0]) << 24 | Int(blob[1]) << 16 | Int(blob[2]) << 8 | Int(blob[3])
            if n > 0, n < 64, blob.count >= 4 + n { keyType = String(decoding: blob[4..<(4 + n)], as: UTF8.self) }
        }
        return SSHHostKeyInfo(keyType: keyType, blob: blob)
    }

    private func authenticate(username: String, password: String) throws {
        guard let s = session else { throw SSHTunnelError.closed }
        ctx.username = username
        ctx.password = password
        ctx.promptsSeen = []
        ctx.rounds = 0
        let listPtr = libssh2_userauth_list(s, username, UInt32(username.utf8.count))
        let offered = listPtr.map { String(cString: $0) } ?? (libssh2_userauth_authenticated(s) != 0 ? "(none needed)" : "")
        var used = "none"
        if libssh2_userauth_authenticated(s) == 0 {
            let methods = offered.split(separator: ",").map(String.init)
            var lastErr = ""
            // Sony / sony-alpha-python: keyboard-interactive. Try it first, then plain password.
            if methods.contains("keyboard-interactive") {
                let rc = libssh2_userauth_keyboard_interactive_ex(s, username, UInt32(username.utf8.count), kbdintCallback)
                if rc == 0 { used = "keyboard-interactive" } else {
                    let prompts = ctx.promptsSeen.map { "「\($0)」" }.joined(separator: " ")
                    lastErr = "键盘交互失败（\(ctx.rounds) 轮，提问：\(prompts.isEmpty ? "无" : prompts)）：\(lastError())"
                }
            }
            // 键盘交互失败后连接可能已被相机断开；还连着才继续试密码方式。
            let stillConnected = libssh2_session_last_errno(s) != LIBSSH2_ERROR_SOCKET_DISCONNECT
            if used == "none", methods.contains("password"), stillConnected {
                let rc = libssh2_userauth_password_ex(s, username, UInt32(username.utf8.count), password, UInt32(password.utf8.count), nil)
                if rc == 0 { used = "password" } else { lastErr += "；密码方式失败：\(lastError())" }
            }
            if used == "none" {
                if !methods.contains("keyboard-interactive") && !methods.contains("password") {
                    throw SSHTunnelError.noSupportedAuthMethod(offered: offered)
                }
                throw SSHTunnelError.authenticationFailed("相机提供的登录方式：\(offered)；\(lastErr)")
            }
        }
        func m(_ t: Int32) -> String { libssh2_session_methods(s, t).map { String(cString: $0) } ?? "?" }
        negotiated = SSHNegotiated(
            kex: m(LIBSSH2_METHOD_KEX), hostKey: m(LIBSSH2_METHOD_HOSTKEY),
            cipherCS: m(LIBSSH2_METHOD_CRYPT_CS), cipherSC: m(LIBSSH2_METHOD_CRYPT_SC),
            macCS: m(LIBSSH2_METHOD_MAC_CS), macSC: m(LIBSSH2_METHOD_MAC_SC),
            authMethodsOffered: offered, authMethodUsed: used)
        libssh2_session_set_blocking(s, 0)
        libssh2_keepalive_config(s, 1, 15)
    }

    /// Prompts actually shown by the server during keyboard-interactive (for diagnostics).
    public var keyboardInteractivePrompts: [String] { ctx.promptsSeen }

    private func teardown(reason: String) {
        if let s = session {
            libssh2_session_disconnect_ex(s, SSH_DISCONNECT_BY_APPLICATION, reason, "")
            libssh2_session_free(s)
            session = nil
        }
        if sock >= 0 { Darwin.close(sock); sock = -1 }
    }

    static func tcpConnect(host: String, port: UInt16, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        guard rc == 0, let first = res else { throw SSHTunnelError.resolve(String(cString: gai_strerror(rc))) }
        defer { freeaddrinfo(res) }
        var lastErr = "no address"
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            defer { ai = a.pointee.ai_next }
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd < 0 { continue }
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            var r = Darwin.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen)
            if r != 0 && errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                r = poll(&pfd, 1, Int32(timeout * 1000))
                if r == 0 { Darwin.close(fd); throw SSHTunnelError.connectTimeout }
                var soerr: Int32 = 0
                var sl = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &sl)
                r = soerr == 0 ? 0 : -1
                if soerr != 0 { errno = soerr }
            }
            if r == 0 {
                _ = fcntl(fd, F_SETFL, flags)
                return fd
            }
            lastErr = String(cString: strerror(errno))
            Darwin.close(fd)
        }
        throw SSHTunnelError.connect(lastErr)
    }

    // MARK: - Channels

    /// Opens a `direct-tcpip` channel, i.e. what `ssh -L` does per accepted local connection.
    /// For the camera: `openDirectTCPIP(host: "localhost", port: 15740)` once for the command socket and once for the event socket.
    package func openDirectTCPIP(host targetHost: String, port targetPort: UInt16) async throws -> SSHChannelStream {
        let id: Int = try await withCheckedThrowingContinuation { cont in
            enqueue(.open(host: targetHost, port: Int32(targetPort), cont: cont))
        }
        return SSHChannelStream(session: self, id: id)
    }

    public func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        wake()
    }

    /// close() and wait until the I/O thread has sent SSH_MSG_DISCONNECT and freed libssh2 state.
    public func shutdown() async {
        close()
        let running = lock.withLock { thread != nil }
        guard running else { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async { self.finished.wait(); self.finished.signal(); c.resume() }
        }
    }
    private let finished = DispatchSemaphore(value: 0)

    // MARK: - I/O loop

    enum Op {
        case open(host: String, port: Int32, cont: CheckedContinuation<Int, Error>)
        case write(ch: Int, data: Data, offset: Int, cont: CheckedContinuation<Void, Error>)
        case read(ch: Int, max: Int, cont: CheckedContinuation<Data, Error>)
        case closeChannel(ch: Int)

        func fail(_ e: Error) {
            switch self {
            case .open(_, _, let c): c.resume(throwing: e)
            case .write(_, _, _, let c): c.resume(throwing: e)
            case .read(_, _, let c): c.resume(throwing: e)
            case .closeChannel: break
            }
        }
    }

    func enqueue(_ op: Op) {
        lock.lock()
        if stopped || thread == nil {
            lock.unlock()
            op.fail(SSHTunnelError.closed)
            return
        }
        newOps.append(op)
        lock.unlock()
        wake()
    }

    private func wake() {
        var b: UInt8 = 1
        if wakeWrite >= 0 { _ = Darwin.write(wakeWrite, &b, 1) }
    }

    private func startLoop() {
        var fds: [Int32] = [0, 0]
        pipe(&fds)
        wakeRead = fds[0]; wakeWrite = fds[1]
        _ = fcntl(wakeRead, F_SETFL, O_NONBLOCK)
        _ = fcntl(wakeWrite, F_SETFL, O_NONBLOCK)
        let t = Thread { [self] in self.runLoop() }
        t.name = "ssh-io \(host)"
        t.qualityOfService = .userInitiated
        lock.lock(); thread = t; lock.unlock()
        t.start()
    }

    private enum Step { case done, again }

    private func runLoop() {
        guard let s = session else { return }
        var active: [Op] = []
        var channels: [Int: OpaquePointer] = [:]   // live channels; an id missing here means closed
        var closing: [Int: OpaquePointer] = [:]
        var nextID = 1
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var lastKeepalive = Date()
        var replacement: Op?

        func step(_ op: Op) -> Step {
            switch op {
            case let .open(h, p, cont):
                if let ch = libssh2_channel_direct_tcpip_ex(s, h, p, "127.0.0.1", 0) {
                    let id = nextID; nextID += 1
                    channels[id] = ch
                    cont.resume(returning: id); return .done
                }
                if libssh2_session_last_errno(s) == LIBSSH2_ERROR_EAGAIN { return .again }
                cont.resume(throwing: SSHTunnelError.channelOpen(lastError())); return .done
            case let .write(id, data, offset, cont):
                guard let ch = channels[id] else { cont.resume(throwing: SSHTunnelError.closed); return .done }
                let n = data.withUnsafeBytes { p in
                    libssh2_channel_write_ex(ch, 0, p.baseAddress!.assumingMemoryBound(to: CChar.self) + offset, data.count - offset)
                }
                if n == LIBSSH2_ERROR_EAGAIN { return .again }
                if n < 0 { cont.resume(throwing: SSHTunnelError.io("write \(lastError())")); return .done }
                let newOffset = offset + n
                if newOffset >= data.count { cont.resume(); return .done }
                replacement = .write(ch: id, data: data, offset: newOffset, cont: cont) // partial write: keep the rest
                return .again
            case let .read(id, max, cont):
                guard let ch = channels[id] else { cont.resume(throwing: SSHTunnelError.closed); return .done }
                let want = min(max, buf.count)
                let n = buf.withUnsafeMutableBytes { p in
                    libssh2_channel_read_ex(ch, 0, p.baseAddress!.assumingMemoryBound(to: CChar.self), want)
                }
                if n > 0 { cont.resume(returning: Data(buf[0..<n])); return .done }
                if n == LIBSSH2_ERROR_EAGAIN || (n == 0 && libssh2_channel_eof(ch) == 0) { return .again }
                if n == 0 { cont.resume(throwing: SSHTunnelError.closed); return .done }
                cont.resume(throwing: SSHTunnelError.io("read \(lastError())")); return .done
            case let .closeChannel(id):
                // Removing from `channels` makes pending reads/writes on it fail with .closed on their next step.
                if let ch = channels.removeValue(forKey: id) { closing[id] = ch }
                guard let ch = closing[id] else { return .done }
                let rc = libssh2_channel_close(ch)
                if rc == LIBSSH2_ERROR_EAGAIN { return .again }
                libssh2_channel_free(ch)
                closing[id] = nil
                return .done
            }
        }

        while true {
            lock.lock()
            let stop = stopped
            active.append(contentsOf: newOps)
            newOps.removeAll()
            lock.unlock()
            if stop { break }

            var progressed = false
            var i = 0
            while i < active.count {
                replacement = nil
                let op = active[i]
                let r = step(op)
                if r == .done { active.remove(at: i); progressed = true; continue }
                if let rep = replacement { active[i] = rep; progressed = true }
                i += 1
            }

            if Date().timeIntervalSince(lastKeepalive) > 5 {
                var next: Int32 = 0
                _ = libssh2_keepalive_send(s, &next)
                lastKeepalive = Date()
            }
            if progressed { continue }

            let dirs = libssh2_session_block_directions(s)
            var ev: Int16 = 0
            if dirs & LIBSSH2_SESSION_BLOCK_INBOUND != 0 || active.isEmpty || dirs == 0 { ev |= Int16(POLLIN) }
            if dirs & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { ev |= Int16(POLLOUT) }
            var pfds = [pollfd(fd: sock, events: active.isEmpty ? 0 : ev, revents: 0),
                        pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            _ = poll(&pfds, 2, active.isEmpty ? 1000 : 200)
            if pfds[1].revents != 0 {
                var junk = [UInt8](repeating: 0, count: 64)
                while Darwin.read(wakeRead, &junk, 64) > 0 {}
            }
        }

        // Shutdown.
        lock.lock()
        active.append(contentsOf: newOps); newOps.removeAll()
        lock.unlock()
        for op in active { op.fail(SSHTunnelError.closed) }
        libssh2_session_set_blocking(s, 1)
        libssh2_session_set_timeout(s, 2000)
        teardown(reason: "bye")
        Darwin.close(wakeRead); Darwin.close(wakeWrite)
        finished.signal()
    }
}

/// 键盘交互：问用户名（回显、或提示里有 user/login/name）就答用户名，其余都答密码（和 sshpass + OpenSSH 的做法一致）。
private let kbdintCallback: @convention(c) (
    UnsafePointer<CChar>?, Int32, UnsafePointer<CChar>?, Int32, Int32,
    UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>?, UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>?,
    UnsafeMutablePointer<UnsafeMutableRawPointer?>?
) -> Void = { _, _, _, _, numPrompts, prompts, responses, abstract in
    guard let raw = abstract?.pointee else { return }
    let ctx = Unmanaged<CallbackContext>.fromOpaque(raw).takeUnretainedValue()
    ctx.rounds += 1
    for i in 0..<Int(numPrompts) {
        var promptText = ""
        var echo = false
        if let p = prompts?[i] {
            if let text = p.text {
                promptText = String(decoding: UnsafeBufferPointer(start: text, count: p.length), as: UTF8.self)
            }
            echo = p.echo != 0
        }
        ctx.promptsSeen.append(promptText.trimmingCharacters(in: .whitespacesAndNewlines))
        let lower = promptText.lowercased()
        let asksUser = !lower.contains("pass") && (echo || lower.contains("user") || lower.contains("login") || lower.contains("name"))
        let answer = strdup(asksUser ? ctx.username : ctx.password) // libssh2 用自己的 free() 释放
        responses?[i].text = answer
        responses?[i].length = UInt32(strlen(answer!))
    }
}

/// SSH 隧道里的一条 direct-tcpip 通道，作为 PTPIPSocket 的底层字节流。
package final class SSHChannelStream: ByteStream, @unchecked Sendable {
    private let session: SSHSession
    private let channel: Int
    private let closedFlag = OnceFlag()

    init(session: SSHSession, id: Int) {
        self.session = session
        self.channel = id
    }

    package func send(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            session.enqueue(.write(ch: channel, data: data, offset: 0, cont: cont))
        }
    }

    package func receive(maximumLength: Int) async throws -> Data {
        do {
            return try await withCheckedThrowingContinuation { cont in
                session.enqueue(.read(ch: channel, max: maximumLength, cont: cont))
            }
        } catch SSHTunnelError.closed {
            throw PTPIPTransportError.closed
        }
    }

    package func close() {
        if closedFlag.claim() { session.enqueue(.closeChannel(ch: channel)) }
    }
}
