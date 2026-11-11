import Foundation
import Testing
@testable import MiniDiTCore

struct AgentProtocolTests {
    @Test func jsonAndRequestsRoundTrip() throws {
        let json: AgentJSON = .object(["null": .null, "bool": .bool(false), "number": .integer(4294967295),
            "path": .string("/tmp/素材\n第二行"), "items": .array([.string("a"), .integer(2)])])
        let data = try json.data()
        #expect(!data.contains(10), "stdio messages must encode newlines inside strings")
        #expect(try JSONDecoder().decode(AgentJSON.self, from: data) == json)
        let request = AgentControlRequest(method: "app.status")
        let decoded = try JSONDecoder().decode(AgentControlRequest.self, from: JSONEncoder().encode(request))
        #expect(decoded.id == request.id && decoded.version == 1)
    }
    @Test func catalogIsStrictAndDiscoverable() throws {
        #expect(Set(AgentTools.all.map(\.name)).count == AgentTools.all.count)
        #expect(Set(AgentTools.all.map(\.method)).count == AgentTools.all.count)
        for tool in AgentTools.all {
            #expect(tool.schema["additionalProperties"].bool == false)
            #expect(AgentTools.find(tool.name)?.method == tool.method)
        }
        let create = try #require(AgentTools.find("projects.create"))
        #expect(throws: AgentControlError.self) { try create.validate(.object([:])) }
        #expect(throws: AgentControlError.self) { try create.validate(.object(["date": .string("2026-11-09"), "password": .string("must-not-be-accepted")])) }
        let list = try #require(AgentTools.find("assets.list"))
        #expect(throws: AgentControlError.self) { try list.validate(.object(["limit": .integer(201)])) }
        #expect(throws: AgentControlError.self) { try list.validate(.object(["offset": .number(1.5)])) }
        try AgentTools.find("assets.filter")!.validate(.object(["query": .string("")]))
        #expect(throws: AgentControlError.self) { try AgentTools.find("assets.select")!.validate(.object(["ids": .array([.string("1")])])) }
    }
    #if os(macOS)
    @Test func endpointRejectsUnsafeDirectory() throws {
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-agent-permissions-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? fm.removeItem(at: root) }
        #expect(throws: AgentControlError.self) { try AgentSocket.secureDirectory(root.path) }
        let link = root.appending(path: "link")
        try fm.createSymbolicLink(at: link, withDestinationURL: root)
        #expect(throws: AgentControlError.self) { try AgentSocket.secureDirectory(link.path) }
    }
    #endif
}
