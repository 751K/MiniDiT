import Darwin
import Foundation
import MiniDiTCore

/// 读写文件并算 xxHash64。都不在主线程上跑。
///
/// 读的时候关掉系统缓存（F_NOCACHE），这样校验读到的是盘上真实的数据，
/// 而不是刚写进内存、还没落盘的那份。
enum FileOps {
    static let chunk = 8 * 1024 * 1024

    /// 算整个文件的哈希。
    static func hash(_ url: URL) async throws -> UInt64 {
        let fd = try openRead(url)
        defer { close(fd) }
        var x = XXH64()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        while true {
            try Task.checkCancellation()
            let n = read(fd, buf.baseAddress, chunk)
            if n < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            x.update(UnsafeRawBufferPointer(rebasing: buf[0..<n]))
        }
        return x.digest()
    }

    /// 复制文件，同时算读到的数据的哈希。`progress` 报告已复制的字节数。
    /// 目标已存在会被覆盖。
    @discardableResult
    static func copy(from src: URL, to dst: URL, progress: @Sendable (UInt64) -> Void = { _ in }) async throws -> UInt64 {
        let input = try openRead(src)
        defer { close(input) }
        let output = open(dst.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if output < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var ok = false
        defer {
            close(output)
            if !ok { unlink(dst.path) }
        }
        var x = XXH64()
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
        defer { buf.deallocate() }
        var done: UInt64 = 0
        while true {
            try Task.checkCancellation()
            let n = read(input, buf.baseAddress, chunk)
            if n < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            if n == 0 { break }
            let part = UnsafeRawBufferPointer(rebasing: buf[0..<n])
            x.update(part)
            var off = 0
            while off < n {
                let w = write(output, part.baseAddress! + off, n - off)
                if w < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                off += w
            }
            done += UInt64(n)
            progress(done)
        }
        // 确认真的写到盘上了，再去读回来校验。
        if fsync(output) != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        ok = true
        return x.digest()
    }

    private static func openRead(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY)
        if fd < 0 { throw POSIXError(.init(rawValue: errno) ?? .ENOENT) }
        _ = fcntl(fd, F_NOCACHE, 1)
        return fd
    }
}
