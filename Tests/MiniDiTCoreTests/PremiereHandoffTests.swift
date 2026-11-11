import Foundation
import Testing
import MiniDiTCore

@Suite struct PremiereHandoffTests {
    @Test func persistsSeparateRollsAndSameNamedFilesWithCanonicalProxyPaths() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appending(path: "A.MP4"), alias = root.appending(path: "alias.MP4")
        try Data([1, 2]).write(to: original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        let clip = PremiereHandoff.Clip(url: alias, proxy: original, marks: [.init(name: "Shot Mark 1", seconds: 1.001, duration: 1001.0 / 24000)])
        #expect(clip.path == alias.path && clip.canonicalPath == original.resolvingSymlinksInPath().path)
        let handoff = PremiereHandoff(groups: [
            .init(binPath: ["婚礼", "A001"], clips: [clip]),
            .init(binPath: ["婚礼", "B001"], clips: [.init(url: URL(filePath: "/other-card/A.MP4"), proxy: nil)])])
        #expect(try JSONDecoder().decode(PremiereHandoff.self, from: JSONEncoder().encode(handoff)) == handoff)
        #expect(handoff.groups[0].clips[0].canonicalPath != handoff.groups[1].clips[0].canonicalPath)
        var record = VideoDelivery(software: .premiere, projectIDs: [UUID()], payload: try JSONEncoder().encode(handoff), files: [])
        record.premiereProjectID = "PR-guid"; record.premiereProjectName = "婚礼后期"; record.state = .sending
        let decoded = try JSONDecoder().decode(VideoDelivery.self, from: JSONEncoder().encode(record))
        #expect(decoded == record && decoded.recovered.canRetry && decoded.premiereProjectID == "PR-guid")
    }
}
