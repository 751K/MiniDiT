import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit
@testable import MiniDiT

@main struct AgentChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        let previous = defaults.persistentDomain(forName: domain)
        defer { if let previous { defaults.setPersistentDomain(previous, forName: domain) } else { defaults.removePersistentDomain(forName: domain) } }
        defaults.removePersistentDomain(forName: domain)
        let fm = FileManager.default, root = URL(filePath: "/private/tmp").appending(path: "minidit-agent-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        let previousHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = previousHistory }
        let card = root.appending(path: "card"), photos = root.appending(path: "photos"), videos = root.appending(path: "videos")
        for path in [card.appending(path: "DCIM/100MSDCF"), card.appending(path: "PRIVATE/M4ROOT/CLIP"), photos, videos] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        try Data(repeating: 0x41, count: 1024).write(to: card.appending(path: "DCIM/100MSDCF/AGENT001.JPG"))
        try Data(repeating: 0x42, count: 2048).write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/AGENT001.MP4"))
        let model = AppModel(startServices: false, journalURL: root.appending(path: "journal.sqlite"))
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.sessions = []; model.currentSessionID = nil
        model.captureOneMode = .off; model.openAfterImport = .none; model.backupEnabled = false
        model.sendToFCP = false; model.sendToResolve = false; model.deleteAfterImport = false
        model.autoRefresh = false; model.onlyNew = false; model.importContent = .all
        model.photoFolderLayout = .session; model.videoFolderLayout = .session; model.splitVideoByRoll = false
        model.destination = photos; model.videoDestination = videos
        model.sourceKind = .card; model.cardRoot = card; model.connectedName = "Agent 检查卡"; model.library = LocalCardLibrary(root: card)
        await model.loadAll()
        _ = try model.agentCall("assets.filter", params: .object(["content": .string("all"), "onlyNew": .bool(false), "query": .string(""), "days": .array([])]))
        let assets = try model.agentCall("assets.list")["assets"].array!
        precondition(assets.count == 2)
        let ids = assets.map { $0["id"] }
        _ = try model.agentCall("assets.select", params: .object(["ids": .array(ids)]))
        try expect("project_required") { _ = try model.agentCall("import.preview") }
        let selected = model.grid.selected
        try expect("invalid_selection") { _ = try model.agentCall("assets.select", params: .object(["ids": .array([.integer(4294967295)])])) }
        precondition(model.grid.selected == selected)
        try expect("invalid_params") { _ = try model.agentCall("projects.create", params: .object(["date": .string("2026-02-30")])) }
        precondition(model.sessions.isEmpty)
        let project = try model.agentCall("projects.create", params: .object(["date": .string("2026-11-09"), "event": .string("Agent 检查")]))
        let projectID = UUID(uuidString: project["id"].string!)!
        precondition(model.currentSessionID == projectID && model.importJournal.batches.isEmpty)
        _ = try model.agentCall("projects.create", params: .object(["date": .string("2026-11-09"), "event": .string("Agent 检查")]))
        precondition(model.sessions.count == 1)
        let plan1 = try model.agentCall("import.preview")["planId"]
        model.destination = videos
        try expect("plan_changed") { _ = try model.agentCall("import.start", params: .object(["planId": plan1])) }
        model.destination = photos
        let plan2 = try model.agentCall("import.preview")["planId"]
        model.primaryConnectionID = UUID()
        try expect("plan_changed") { _ = try model.agentCall("import.start", params: .object(["planId": plan2])) }
        let plan3 = try model.agentCall("import.preview")["planId"]
        model.grid.replace(with: [])
        try expect("plan_changed") { _ = try model.agentCall("import.start", params: .object(["planId": plan3])) }
        model.grid.replace(with: selected)
        model.backupEnabled = true; model.backupFolder = nil
        try expect("backup_unavailable") { _ = try model.agentCall("import.preview") }
        let targetA = root.appending(path: "backup-A"), targetB = root.appending(path: "backup-B")
        for path in [targetA, targetB] { try fm.createDirectory(at: path, withIntermediateDirectories: true) }
        model.backupTargets = [.init(name: "A", root: targetA), .init(name: "B", root: targetB)]
        let multiPlan = try model.agentCall("import.preview")
        precondition(multiPlan["backupTargets"].array?.count == 2)
        let multiStatus = try model.agentCall("app.status")
        precondition(multiStatus["backupTargets"].array?.count == 2)
        model.backupTargets[1].required = false
        try expect("plan_changed") { _ = try model.agentCall("import.start", params: .object(["planId": multiPlan["planId"]])) }
        model.backupTargets[1].required = true
        try fm.removeItem(at: targetB)
        try expect("backup_unavailable") { _ = try model.agentCall("import.preview") }
        model.backupTargets[1].required = false
        _ = try model.agentCall("import.preview") // An offline optional target does not block the primary or A.
        model.backupEnabled = false
        model.deleteAfterImport = true
        try expect("deletion_acknowledgement_required") { _ = try model.agentCall("import.preview") }
        model.deleteAfterImport = false
        let expired = try model.agentCall("import.preview")["planId"].string!
        model.agentPlans[expired]!.expires = .distantPast
        try expect("plan_expired") { _ = try model.agentCall("import.start", params: .object(["planId": .string(expired)])) }
        precondition(model.importJournal.batches.isEmpty)
        print("PASS: required project, strict inputs, atomic selection validation, duplicate project reuse, changed settings/connections/selection reject stale plans, all target snapshots and second-target changes invalidate plans, required versus optional offline gates, deletion gates, expiry; preview performs no transfer")

        let endpoint = root.appending(path: "control.sock").path
        model.startAgentControl(path: endpoint)
        precondition(model.agentServer != nil)
        let status = try await Task.detached { try AgentSocket.request(.init(method: "app.status"), path: endpoint) }.value
        precondition(status["projectId"].string == projectID.uuidString)
        let cli = ProcessInfo.processInfo.environment["MINIDIT_TEST_CLI"] ?? "/tmp/minidit-project-results-build/.build/debug/minidit"
        let cliStatus = try await run(cli, args: ["status"], socket: endpoint)
        precondition(cliStatus.code == 0)
        let decodedStatus = try JSONDecoder().decode(AgentJSON.self, from: cliStatus.data)
        precondition(decodedStatus["projectId"].string == projectID.uuidString)
        let messages: [AgentJSON] = [
            .object(["jsonrpc": .string("2.0"), "id": .integer(1), "method": .string("initialize"), "params": .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object([:]), "clientInfo": .object(["name": .string("test"), "version": .string("1")])])]),
            .object(["jsonrpc": .string("2.0"), "method": .string("notifications/initialized")]),
            .object(["jsonrpc": .string("2.0"), "id": .integer(2), "method": .string("tools/list")]),
            .object(["jsonrpc": .string("2.0"), "id": .integer(3), "method": .string("tools/call"), "params": .object(["name": .string("minidit_app_status"), "arguments": .object([:])])]),
            .object(["jsonrpc": .string("2.0"), "id": .integer(4), "method": .string("tools/call"), "params": .object(["name": .string("minidit_projects_select"), "arguments": .object(["id": .string(UUID().uuidString)])])])
        ]
        let input = try messages.reduce(into: Data()) { $0.append(try $1.data()); $0.append(10) }
        let mcp = try await run(cli, args: ["mcp"], socket: endpoint, input: input)
        let replies = try mcp.data.split(separator: 10).map { try JSONDecoder().decode(AgentJSON.self, from: Data($0)) }
        precondition(mcp.code == 0 && replies.count == 4)
        precondition(replies[0]["result"]["protocolVersion"].string == "2025-11-25")
        precondition(replies[1]["result"]["tools"].array?.count == AgentTools.all.count)
        precondition(replies[2]["result"]["structuredContent"]["projectId"].string == projectID.uuidString)
        precondition(replies[3]["result"]["isError"].bool == true)
        let badCLI = try await run(cli, args: ["assets", "select", "--ids", "bad"], socket: endpoint)
        precondition(badCLI.code == 2)
        print("PASS: same-user Unix socket roundtrip; native CLI JSON and nonzero invalid-input exit; MCP initialize/notification/catalog/tool success/structured error with clean stdout")

        let plan = try model.agentCall("import.preview")["planId"]
        let startCLI = try await run(cli, args: ["import", "start", "--plan-id", plan.string!], socket: endpoint)
        precondition(startCLI.code == 0)
        let started = try JSONDecoder().decode(AgentJSON.self, from: startCLI.data)
        let repeatCLI = try await run(cli, args: ["import", "start", "--plan-id", plan.string!], socket: endpoint)
        precondition(repeatCLI.code == 0)
        let repeated = try JSONDecoder().decode(AgentJSON.self, from: repeatCLI.data)
        precondition(started["batchId"] == repeated["batchId"] && repeated["alreadyStarted"].bool == true)
        for _ in 0..<600 {
            if model.importTask == nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(model.importTask == nil && model.importJournal.batches.count == 1)
        let batch = model.importJournal.records(for: projectID).first!
        precondition(batch.savedCount == 2 && batch.files.allSatisfy { $0.projectID == projectID })
        precondition(model.sessions[0].files.count == 2)
        let records = try model.agentCall("imports.get", params: .object(["id": .string(batch.id.uuidString), "limit": .integer(1)]))
        precondition(records["files"].array?.count == 1 && records["totalFiles"].int == 2)
        precondition(fm.fileExists(atPath: card.appending(path: "DCIM/100MSDCF/AGENT001.JPG").path))
        print("PASS: real CLI-adapter import saves photo/video into the selected project, journal contains actual files, retry is idempotent, paginated result query, originals retained")
    }
    @MainActor static func expect(_ code: String, _ body: () throws -> Void) throws {
        do { try body(); fatalError("Expected error: \(code)") }
        catch let error as AgentControlError { precondition(error.code == code, "Expected \(code), got \(error.code): \(error.message)") }
    }
    static func run(_ executable: String, args: [String], socket: String, input: Data? = nil) async throws -> (code: Int32, data: Data) {
        try await Task.detached {
            let process = Process(), output = Pipe(), stdin = Pipe()
            process.executableURL = URL(filePath: executable); process.arguments = args
            process.environment = ProcessInfo.processInfo.environment.merging(["MINIDIT_SOCKET_PATH": socket]) { _, new in new }
            process.standardOutput = output; process.standardInput = stdin
            try process.run()
            if let input { stdin.fileHandleForWriting.write(input) }
            try stdin.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, data)
        }.value
    }
}
