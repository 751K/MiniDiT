#if os(macOS)
import Foundation
import Darwin

/// Local, same-user only. No TCP port, credentials file or remote listener.
public enum AgentSocket {
    public static var directory: String { "/private/tmp/minidit-agent-\(geteuid())" }
    public static var path: String { directory + "/control.sock" }
    public static let maximumFrame = 2 * 1024 * 1024

    public static func secureDirectory(_ path: String) throws {
        if mkdir(path, 0o700) != 0, errno != EEXIST { throw failure("无法创建本地控制目录") }
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw AgentControlError("unsafe_endpoint", "本地控制目录的所有者或权限不正确。")
        }
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [UInt8(0)]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw AgentControlError("invalid_endpoint", "Socket 路径过长。") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }
    static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var addr = try address(path)
        return withUnsafePointer(to: &addr) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    }
    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 10, tv_usec: 0), one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    static func sameUser(_ fd: Int32) -> Bool {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 && uid == geteuid()
    }
    public static func readFrame(_ fd: Int32) throws -> Data {
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while result.count <= maximumFrame {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { throw AgentControlError("connection_closed", "连接已关闭或请求超时。") }
            if let end = buffer[..<n].firstIndex(of: 10) {
                result.append(contentsOf: buffer[..<end])
                guard result.count <= maximumFrame else { break }
                return result
            }
            result.append(contentsOf: buffer[..<n])
        }
        throw AgentControlError("message_too_large", "本地控制消息超过大小限制。")
    }
    public static func writeFrame(_ data: Data, to fd: Int32) throws {
        guard data.count <= maximumFrame else { throw AgentControlError("message_too_large", "结果过大，请减小分页大小。") }
        let frame = data + Data([10])
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < frame.count {
                let n = send(fd, bytes.baseAddress!.advanced(by: offset), frame.count - offset, 0)
                if n < 0, errno == EINTR { continue }
                guard n > 0 else { throw failure("无法写入本地控制连接") }
                offset += n
            }
        }
    }
    static func failure(_ message: String) -> AgentControlError { .init("transport_error", message + ": " + String(cString: strerror(errno))) }

    public static func request(_ request: AgentControlRequest, path: String = path) throws -> AgentJSON {
        try secureDirectory((path as NSString).deletingLastPathComponent)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw failure("无法打开本地控制连接") }
        defer { close(fd) }; configure(fd)
        guard try withAddress(path, { connect(fd, $0, $1) }) == 0 else {
            throw AgentControlError("app_not_running", "无法连接 MiniDiT，请先运行 minidit launch 或打开应用。")
        }
        guard sameUser(fd) else { throw AgentControlError("permission_denied", "MiniDiT 服务不属于当前用户。") }
        try writeFrame(JSONEncoder().encode(request), to: fd)
        let response = try JSONDecoder().decode(AgentControlResponse.self, from: readFrame(fd))
        guard response.id == request.id else { throw AgentControlError("invalid_response", "响应 ID 不匹配。") }
        if let error = response.error { throw error }
        guard let result = response.result else { throw AgentControlError("invalid_response", "服务没有返回结果。") }
        return result
    }
}

public final class AgentSocketServer: @unchecked Sendable {
    private let listener: Int32
    private let endpoint: String
    private let lock: Int32
    private let handler: @MainActor @Sendable (AgentControlRequest) -> AgentControlResponse
    private let workers = DispatchQueue(label: "com.kong.minidit.agent.requests", qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 8)

    public init(path: String = AgentSocket.path, handler: @escaping @MainActor @Sendable (AgentControlRequest) -> AgentControlResponse) throws {
        self.endpoint = path; self.handler = handler
        try AgentSocket.secureDirectory((path as NSString).deletingLastPathComponent)
        let lockFD = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw AgentSocket.failure("无法锁定本地控制接口") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); throw AgentControlError("already_running", "已有 MiniDiT 控制服务。") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { close(lockFD); throw AgentSocket.failure("无法建立本地控制接口") }
        do {
            var info = stat()
            if lstat(path, &info) == 0 {
                guard (info.st_mode & S_IFMT) == S_IFSOCK, info.st_uid == geteuid() else { throw AgentControlError("unsafe_endpoint", "本地控制路径不是当前用户的 socket。") }
                guard unlink(path) == 0 else { throw AgentSocket.failure("无法清理旧 socket") }
            }
            guard try AgentSocket.withAddress(path, { bind(fd, $0, $1) }) == 0,
                  chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw AgentSocket.failure("无法监听本地控制接口") }
        } catch { close(fd); close(lockFD); throw error }
        self.listener = fd; self.lock = lockFD
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        DispatchQueue(label: "com.kong.minidit.agent.accept", qos: .utility).async { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue }; return }
                guard slots.wait(timeout: .now()) == .success else { close(client); continue }
                AgentSocket.configure(client)
                guard AgentSocket.sameUser(client) else { close(client); slots.signal(); continue }
                workers.async { [self] in
                    do {
                        let request = try JSONDecoder().decode(AgentControlRequest.self, from: AgentSocket.readFrame(client))
                        Task {
                            let response = await handler(request)
                            workers.async { [self] in
                                defer { close(client); slots.signal() }
                                do { try AgentSocket.writeFrame(JSONEncoder().encode(response), to: client) }
                                catch { /* A client may exit before reading the result. */ }
                            }
                        }
                    } catch {
                        defer { close(client); slots.signal() }
                        let failure = AgentControlResponse(id: "", error: .init("invalid_request", "无效或过大的请求。"))
                        if let data = try? JSONEncoder().encode(failure) { try? AgentSocket.writeFrame(data, to: client) }
                    }
                }
            }
        }
    }
    // The server intentionally lives for the app process; flock is released by the OS on exit.
}
#endif
