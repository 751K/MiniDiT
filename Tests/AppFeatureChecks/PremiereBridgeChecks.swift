import AppKit
import Foundation
import MiniDiTCore
@testable import MiniDiT

@main struct PremiereBridgeChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-pr-bridge-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let base = root.appending(path: "ipc")
        let expected = PremiereBridge.Project(id: "original-pr-guid", name: "隔离 PR 项目", path: "/tmp/Test.prproj")
        let exchange = Task<PremiereBridge.Project, Error> { try await PremiereBridge.exchange(action: "identify", base: base, timeout: 3) }
        let directory = try await requestDirectory(base)
        let request = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "request.json"))) as! [String: Any]
        precondition(request["action"] as? String == "identify" && request["protocolVersion"] as? Int == 1)
        let id = request["id"] as! String
        try await Task.sleep(for: .milliseconds(1200))
        let lease = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appending(path: "lease.json"))) as! [String: Any]
        precondition(lease["id"] as? String == id && (lease["expiresAt"] as! Double) > Date().timeIntervalSince1970)
        let response: [String: Any] = ["id": id, "value": ["id": expected.id, "name": expected.name, "path": expected.path]]
        try JSONSerialization.data(withJSONObject: response).write(to: directory.appending(path: "result.json"), options: .atomic)
        let received = try await exchange.value
        precondition(received == expected && !fm.fileExists(atPath: directory.path))
        let wrong = Task<PremiereBridge.Project, Error> { try await PremiereBridge.exchange(action: "identify", base: base, timeout: 2) }
        let wrongDirectory = try await requestDirectory(base)
        try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "value": ["id": "other", "name": "wrong", "path": ""]]).write(to: wrongDirectory.appending(path: "result.json"), options: .atomic)
        do { _ = try await wrong.value; fatalError("wrong receipt accepted") } catch { precondition(error.localizedDescription.contains("其他任务")) }
        let timedOut = Task<PremiereBridge.Project, Error> { try await PremiereBridge.exchange(action: "identify", base: base, timeout: 0.2) }
        let timeoutDirectory = try await requestDirectory(base)
        do { _ = try await timedOut.value; fatalError("timeout accepted") } catch { precondition(error.localizedDescription.contains("超时")) }
        precondition(!fm.fileExists(atPath: timeoutDirectory.path))
        let cancelled = Task<PremiereBridge.Project, Error> { try await PremiereBridge.exchange(action: "identify", base: base, timeout: 10) }
        let cancelDirectory = try await requestDirectory(base); cancelled.cancel()
        do { _ = try await cancelled.value; fatalError("cancel accepted") } catch { precondition(error is CancellationError) }
        precondition(!fm.fileExists(atPath: cancelDirectory.path))
        // CCX has the manifest at the archive root and includes the exact tested receiver sources.
        let source = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "Apps/MiniDiT/MiniDiT/Resources/PremierePlugin.bundle")
        let package = try await PremierePlugin.makePackage(source: source, output: root.appending(path: "MiniDiT.ccx"))
        let archive = Process(); archive.executableURL = URL(filePath: "/usr/bin/unzip"); archive.arguments = ["-q", package.path, "-d", root.appending(path: "unpacked").path]
        try archive.run(); archive.waitUntilExit(); precondition(archive.terminationStatus == 0)
        for file in ["manifest.json", "receiver.js", "mailbox.js", "index.js", "index.html"] {
            let unpacked = try Data(contentsOf: root.appending(path: "unpacked/" + file)), original = try Data(contentsOf: source.appending(path: file))
            precondition(unpacked == original)
        }
        _ = try await PremierePlugin.makePackage(source: source, output: package)
        precondition(fm.fileExists(atPath: package.path))
        print("PASS: native Premiere transport exchanges typed receipts, renews attempt leases, rejects other-attempt replies, cleans expired/cancelled requests, and packages the exact receiver as a root-manifest CCX")
    }
    static func requestDirectory(_ base: URL) async throws -> URL {
        for _ in 0..<100 {
            let directories = (try? FileManager.default.contentsOfDirectory(at: base.appending(path: "requests"), includingPropertiesForKeys: nil)) ?? []
            if let directory = directories.first(where: { FileManager.default.fileExists(atPath: $0.appending(path: "request.json").path) }) { return directory }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw VideoDelivery.Failure("request not found")
    }
}
