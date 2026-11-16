import Foundation
import MiniDiTCore
#if os(macOS)
import Darwin

func emit(_ value: AgentJSON, pretty: Bool = false) {
    do { FileHandle.standardOutput.write(try value.data(pretty: pretty) + Data([10])) }
    catch { FileHandle.standardError.write(Data("MiniDiT: output encoding failed\n".utf8)) }
}
func perform(_ method: String, _ params: AgentJSON) throws -> AgentJSON {
    guard let tool = AgentTools.find(method) else { throw AgentControlError("unknown_method", "未知命令：\(method)") }
    try tool.validate(params)
    if tool.method == "app.launch" {
        let process = Process(); process.executableURL = URL(filePath: "/usr/bin/open")
        process.arguments = ["-b", "com.kong.SonyImport"]
        process.standardOutput = FileHandle.standardError
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw AgentControlError("app_not_found", "未找到已安装的 MiniDiT。") }
        for _ in 0..<100 {
            if let status = try? AgentSocket.request(.init(method: "app.status")) { return status }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AgentControlError("launch_timeout", "应用已启动，但本地控制接口尚未就绪。")
    }
    let path = ProcessInfo.processInfo.environment["MINIDIT_SOCKET_PATH"] ?? AgentSocket.path
    // 拍摄要等相机把文件传完；设置要等回读确认。
    let timeout: Int
    switch tool.method {
    case "tether.capture": timeout = 330
    case "tether.set_properties": timeout = 90
    case "tether.download": timeout = 3600
    case "tether.record_clip": timeout = (params["seconds"].int ?? 0) + (params["timeoutSeconds"].int ?? 120) + 3600
    case "tether.files": timeout = 120
    case "tether.stop": timeout = 60
    default: timeout = 10
    }
    return try AgentSocket.request(.init(method: tool.method, params: params), path: path, timeout: timeout)
}

func rpcError(_ id: AgentJSON, code: Int, message: String) -> AgentJSON {
    .object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .integer(code), "message": .string(message)])])
}

/// Standard MCP stdio transport, protocol revision 2025-11-25.
func serveMCP() {
    var initialized = false, ready = false
    while let line = readLine() {
        guard line.utf8.count <= AgentSocket.maximumFrame else { emit(rpcError(.null, code: -32700, message: "Message too large")); continue }
        let request: AgentJSON
        do { request = try JSONDecoder().decode(AgentJSON.self, from: Data(line.utf8)) }
        catch { emit(rpcError(.null, code: -32700, message: "Parse error")); continue }
        guard request.object != nil, request["jsonrpc"].string == "2.0", let method = request["method"].string else {
            emit(rpcError(.null, code: -32600, message: "Invalid Request")); continue
        }
        let id = request["id"], params = request["params"]
        let notification = request.object?["id"] == nil
        if notification {
            if method == "notifications/initialized", initialized { ready = true }
            continue
        }
        guard id.string != nil || id.int != nil else { emit(rpcError(.null, code: -32600, message: "Invalid request ID")); continue }
        var result: AgentJSON
        switch method {
        case "initialize":
            guard !initialized, params["protocolVersion"].string != nil, params["clientInfo"].object != nil,
                  params["capabilities"].object != nil else { emit(rpcError(id, code: -32602, message: "Invalid initialization")); continue }
            initialized = true
            result = .object(["protocolVersion": .string("2025-11-25"), "capabilities": .object(["tools": .object(["listChanged": .bool(false)])]),
                "serverInfo": .object(["name": .string("MiniDiT"), "version": .string("1.0.0")]),
                "instructions": .string("Use minidit_app_status to inspect state. Select/create a project, filter/list/select assets, then minidit_import_preview and minidit_import_start with the returned planId. Mutations are reflected in the local app. Credentials and fingerprint approval remain in the app. Source files are never deleted unless preview explicitly acknowledges the enabled deletion preference. Sony tethered shooting: minidit_tether_start, then poll minidit_tether_status; minidit_tether_set / minidit_tether_shoot / minidit_tether_live_view (returns an image). Shots auto-import into the selected project.")])
        case "ping": result = .object([:])
        case "tools/list":
            guard ready else { emit(rpcError(id, code: -32002, message: "Initialize first")); continue }
            result = .object(["tools": .array(AgentTools.all.map(\.mcp))])
        case "tools/call":
            guard ready else { emit(rpcError(id, code: -32002, message: "Initialize first")); continue }
            guard let name = params["name"].string, let tool = AgentTools.all.first(where: { $0.name == name }) else {
                emit(rpcError(id, code: -32602, message: "Unknown tool")); continue
            }
            let args = params.object?["arguments"] ?? .object([:])
            do {
                let value = try perform(tool.method, args)
                if let image = value["data"].string, let mime = value["mimeType"].string, var meta = value.object {
                    // 取景帧：图片内容给模型看，结构化结果里不再重复一遍 base64。
                    meta["data"] = nil
                    result = .object(["content": .array([.object(["type": .string("image"), "data": .string(image), "mimeType": .string(mime)]),
                        .object(["type": .string("text"), "text": .string(String(decoding: try AgentJSON.object(meta).data(), as: UTF8.self))])]),
                        "structuredContent": .object(meta), "isError": .bool(false)])
                } else {
                    result = .object(["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: try value.data(), as: UTF8.self))])]),
                        "structuredContent": value.object == nil ? .object(["result": value]) : value, "isError": .bool(false)])
                }
            } catch {
                let failure = (error as? AgentControlError) ?? AgentControlError("operation_failed", error.localizedDescription)
                let value = (try? AgentJSON.encoded(failure)) ?? .null
                result = .object(["content": .array([.object(["type": .string("text"), "text": .string(String(decoding: (try? value.data()) ?? Data(), as: UTF8.self))])]), "isError": .bool(true)])
            }
        default:
            emit(rpcError(id, code: -32601, message: "Method not found; supported MCP revision: 2025-11-25")); continue
        }
        emit(.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
    }
}

func cli(_ arguments: [String]) throws {
    if arguments.isEmpty || arguments == ["--help"] || arguments == ["help"] {
        print("""
        MiniDiT CLI — controls the running local app; all command results are JSON.

        minidit launch | status
        minidit projects list
        minidit projects create --date 2026-11-09 --event 海边拍摄
        minidit projects select --id PROJECT_UUID
        minidit sources connect --host 127.0.0.1
        minidit sources open-card --path /Volumes/CARD
        minidit assets filter --content all --only-new false --query '' --days []
        minidit assets list --limit 50
        minidit assets select --ids 1,2,3
        minidit import preview
        minidit import start --plan-id PLAN_UUID
        minidit imports list
        minidit imports get --id BATCH_UUID
        minidit import cancel | resume
        minidit tether start [--host 192.168.1.23]   Sony tethered shooting (Wi-Fi PC Remote)
        minidit tether status | shoot | stop [--restore-settings true]
        minidit tether set --setting iso --label 400   (or --value N / --step 1)
        minidit tether focus --locked true | tether record --on true
        minidit tether live-view --max-width 1024      JPEG as base64 in "data"
        minidit tether live-view --out-file /abs/frame.jpg   save the full frame (never overwrites)
        minidit tether configure --auto-import true --live-view false
        minidit tools                     JSON tool catalog and argument schemas
        minidit call METHOD '{"arg":"value"}'
        minidit mcp                       MCP stdio server (2025-11-25)

        No project means no normal import. Preview tokens expire after five minutes;
        changes to selection/devices/settings require a new preview. Repeating a
        start with the same plan does not start a duplicate batch.
        """)
        return
    }
    if arguments == ["--version"] { print("minidit 1.0.0"); return }
    if arguments == ["mcp"] { serveMCP(); return }
    if arguments == ["tools"] {
        emit(.array(AgentTools.all.map { .object(["method": .string($0.method), "tool": $0.mcp]) }), pretty: true); return
    }
    if arguments.first == "call" {
        guard arguments.count == 2 || arguments.count == 3 else { throw AgentControlError("invalid_params", "用法：minidit call METHOD 'JSON'") }
        let params = arguments.count == 3 ? try JSONDecoder().decode(AgentJSON.self, from: Data(arguments[2].utf8)) : .object([:])
        emit(try perform(arguments[1], params), pretty: true); return
    }
    var words = arguments, method: String
    if ["status", "launch"].contains(words[0]) { method = "app." + words.removeFirst() }
    else {
        guard words.count >= 2, !words[1].hasPrefix("--") else { throw AgentControlError("invalid_params", "请指定命令和操作，或运行 minidit --help。") }
        method = words.removeFirst() + "." + words.removeFirst().replacingOccurrences(of: "-", with: "_")
    }
    guard let tool = AgentTools.find(method) else { throw AgentControlError("unknown_method", "未知命令：" + method) }
    var values: [String: AgentJSON] = [:]
    while !words.isEmpty {
        let flag = words.removeFirst()
        guard flag.hasPrefix("--") else { throw AgentControlError("invalid_params", "参数需要 -- 前缀：" + flag) }
        let parts = flag.dropFirst(2).split(separator: "-")
        let key = (parts.first.map(String.init) ?? "") + parts.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        guard let schema = tool.properties[key], values[key] == nil else { throw AgentControlError("invalid_params", "未知或重复的参数：" + key) }
        guard !words.isEmpty else { throw AgentControlError("invalid_params", "参数缺少取值：" + key) }
        let value = words.removeFirst()
        switch schema["type"].string {
        case "boolean":
            guard value == "true" || value == "false" else { throw AgentControlError("invalid_params", key + " 需要 true 或 false。") }
            values[key] = .bool(value == "true")
        case "integer":
            guard let n = Int(value) else { throw AgentControlError("invalid_params", key + " 需要整数。") }
            values[key] = .integer(n)
        case "array":
            if value.hasPrefix("[") { values[key] = try JSONDecoder().decode(AgentJSON.self, from: Data(value.utf8)) }
            else if schema["items"]["type"].string == "integer" {
                values[key] = .array(try value.split(separator: ",").map { part in
                    guard let number = Int(part) else { throw AgentControlError("invalid_params", "ids 需要逗号分隔的整数。") }
                    return .integer(number)
                })
            } else { values[key] = .array(value.split(separator: ",").map { .string(String($0)) }) }
        default: values[key] = .string(value)
        }
    }
    emit(try perform(method, .object(values)), pretty: true)
}

do { try cli(Array(CommandLine.arguments.dropFirst())) }
catch {
    let failure = (error as? AgentControlError) ?? AgentControlError("operation_failed", error.localizedDescription)
    emit(.object(["error": (try? .encoded(failure)) ?? .null]))
    exit(failure.code == "invalid_params" || failure.code == "unknown_method" ? 2 : 1)
}
#else
print("MiniDiT CLI requires macOS.")
#endif
