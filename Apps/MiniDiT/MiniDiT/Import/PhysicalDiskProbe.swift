import Foundation
import MiniDiTCore

/// Read-only diskutil queries run off the main actor and are shared by paths on
/// the same mounted volume. No shell, privileged operation or on-disk identifier.
enum PhysicalDiskProbe {
    nonisolated static func identities(for roots: [URL]) -> [String: PhysicalDiskIdentity] {
        guard let disks = query(["list", "-plist", "physical"]) else { return [:] }
        let map = PhysicalDiskMap(physicalDisks: disks)
        var volumes: [String: PhysicalDiskIdentity] = [:], results: [String: PhysicalDiskIdentity] = [:]
        for root in roots {
            if Task.isCancelled { return [:] }
            var existing = root.standardizedFileURL.resolvingSymlinksInPath()
            while !FileManager.default.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
                existing.deleteLastPathComponent()
            }
            guard let values = try? existing.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey]),
                  values.volumeIsLocal == true, let volume = values.volume else { continue }
            let key = volume.path
            if volumes[key] == nil {
                volumes[key] = query(["info", "-plist", key]).map { map.identity(volumeInfo: $0) } ?? .init()
            }
            results[root.standardizedFileURL.resolvingSymlinksInPath().path] = volumes[key]
        }
        return results
    }
    nonisolated private static func query(_ arguments: [String]) -> Data? {
        if Task.isCancelled { return nil }
        let process = Process(), output = Pipe()
        process.executableURL = URL(filePath: "/usr/sbin/diskutil")
        process.arguments = arguments; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: deadline)
        defer { deadline.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !Task.isCancelled else { return nil }
        return data
    }
}
