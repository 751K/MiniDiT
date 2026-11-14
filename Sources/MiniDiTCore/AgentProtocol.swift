import Foundation

public enum AgentJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), number(Double), string(String), array([AgentJSON]), object([String: AgentJSON])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([AgentJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AgentJSON].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
    public subscript(_ key: String) -> AgentJSON { object?[key] ?? .null }
    public var object: [String: AgentJSON]? { if case .object(let v) = self { v } else { nil } }
    public var array: [AgentJSON]? { if case .array(let v) = self { v } else { nil } }
    public var string: String? { if case .string(let v) = self { v } else { nil } }
    public var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    public var int: Int? {
        guard case .number(let v) = self, v.isFinite, v.rounded() == v,
              v >= Double(Int.min), v < Double(Int.max) else { return nil }
        return Int(v)
    }
    public static func encoded<T: Encodable>(_ value: T) throws -> AgentJSON {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONDecoder().decode(AgentJSON.self, from: encoder.encode(value))
    }
    public func data(pretty: Bool = false) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    public static func integer(_ v: some BinaryInteger) -> AgentJSON { .number(Double(v)) }
    public static func optional(_ v: String?) -> AgentJSON { v.map(AgentJSON.string) ?? .null }
}

public struct AgentControlError: Error, Codable, Sendable, LocalizedError {
    public let code: String
    public let message: String
    public init(_ code: String, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { message }
}

public struct AgentControlRequest: Codable, Sendable {
    public let version: Int
    public let id: String
    public let method: String
    public let params: AgentJSON
    public init(method: String, params: AgentJSON = .object([:])) {
        version = 1; id = UUID().uuidString; self.method = method; self.params = params
    }
}
public struct AgentControlResponse: Codable, Sendable {
    public let id: String
    public let result: AgentJSON?
    public let error: AgentControlError?
    public init(id: String, result: AgentJSON? = nil, error: AgentControlError? = nil) {
        self.id = id; self.result = result; self.error = error
    }
}

public struct AgentTool: Sendable {
    public let method: String
    public let description: String
    public let properties: [String: AgentJSON]
    public let required: [String]
    public let readOnly: Bool
    public var name: String { "minidit_" + method.replacingOccurrences(of: ".", with: "_") }
    public var schema: AgentJSON { .object(["type": .string("object"), "properties": .object(properties),
        "required": .array(required.map(AgentJSON.string)), "additionalProperties": .bool(false)]) }
    public var mcp: AgentJSON { .object(["name": .string(name), "description": .string(description), "inputSchema": schema,
        "annotations": .object(["readOnlyHint": .bool(readOnly), "destructiveHint": .bool(!readOnly), "openWorldHint": .bool(!readOnly)])]) }
    public func validate(_ params: AgentJSON) throws {
        guard let args = params.object else { throw AgentControlError("invalid_params", "参数必须是 JSON 对象。") }
        for key in args.keys where properties[key] == nil { throw AgentControlError("invalid_params", "未知参数：\(key)") }
        for key in required where args[key] == nil { throw AgentControlError("invalid_params", "缺少参数：\(key)") }
        for (key, value) in args {
            let rule = properties[key]!
            let valid: Bool
            switch rule["type"].string {
            case "string": valid = value.string != nil && (rule["minLength"].int == 0 || !(value.string?.isEmpty ?? true))
            case "boolean": valid = value.bool != nil
            case "integer": valid = value.int != nil
            case "array": valid = value.array != nil && (value.array?.count ?? 0) <= 10000
            default: valid = false
            }
            guard valid else { throw AgentControlError("invalid_params", "参数类型或长度不正确：\(key)") }
            if let choices = rule["enum"].array, !choices.contains(value) { throw AgentControlError("invalid_params", "参数取值不正确：\(key)") }
            if let n = value.int {
                if let min = rule["minimum"].int, n < min { throw AgentControlError("invalid_params", "参数过小：\(key)") }
                if let max = rule["maximum"].int, n > max { throw AgentControlError("invalid_params", "参数过大：\(key)") }
            }
            if let text = value.string, text.utf8.count > 4096 { throw AgentControlError("invalid_params", "参数过长：\(key)") }
            if let elements = value.array {
                for element in elements {
                    if rule["items"]["type"].string == "integer", element.int == nil { throw AgentControlError("invalid_params", "\(key) 必须是整数数组。") }
                    if rule["items"]["type"].string == "string", element.string == nil { throw AgentControlError("invalid_params", "\(key) 必须是字符串数组。") }
                }
            }
        }
    }
}

public enum AgentTools {
    private static func text(_ description: String) -> AgentJSON { .object(["type": .string("string"), "description": .string(description)]) }
    private static func flag(_ description: String) -> AgentJSON { .object(["type": .string("boolean"), "description": .string(description)]) }
    private static func integer(_ min: Int, _ max: Int) -> AgentJSON { .object(["type": .string("integer"), "minimum": .integer(min), "maximum": .integer(max)]) }
    private static func choices(_ values: [String]) -> AgentJSON { .object(["type": .string("string"), "enum": .array(values.map(AgentJSON.string))]) }
    private static func array(_ type: String) -> AgentJSON { .object(["type": .string("array"), "items": .object(["type": .string(type)])]) }
    public static let all: [AgentTool] = [
        .init(method: "app.launch", description: "打开本机 MiniDiT。不会自动开始导入。", properties: [:], required: [], readOnly: false),
        .init(method: "app.status", description: "查询设备连接、所选项目、素材选择、导入进度、最近结果和需要用户处理的界面提示。", properties: [:], required: [], readOnly: true),
        .init(method: "projects.list", description: "列出已有项目及当前选中的导入目标。", properties: [:], required: [], readOnly: true),
        .init(method: "projects.create", description: "按日期和可选事件创建并选择项目；同名项目复用。只创建项目，不导入文件。可指定项目类型（photos 仅照片、videos 仅视频、all 两者，默认 all；同名项目沿用原类型）和照片、视频的默认根目录。", properties: ["date": text("YYYY-MM-DD"), "event": text("事件名称（可省略）"), "content": choices(["photos", "videos", "all"]), "photoRoot": text("照片根目录绝对路径"), "videoRoot": text("视频根目录绝对路径")], required: ["date"], readOnly: false),
        .init(method: "projects.select", description: "按 projects.list 返回的 UUID 选择导入项目。", properties: ["id": text("项目 UUID")], required: ["id"], readOnly: false),
        .init(method: "sources.list", description: "列出已连接的相机、卡和可打开的挂载存储卡。", properties: [:], required: [], readOnly: true),
        .init(method: "sources.connect", description: "通过主机名/IP 连接 Wi-Fi 相机，已有来源时添加相机。连接异步进行，轮询 app.status；首次账号和指纹确认在应用中处理。", properties: ["host": text("主机名或 IP，不含端口和凭据")], required: ["host"], readOnly: false),
        .init(method: "sources.open_card", description: "打开本机存储卡或卡目录；已有来源时添加。读取异步进行，轮询 app.status。", properties: ["path": text("存储卡或包含 DCIM 的目录绝对路径")], required: ["path"], readOnly: false),
        .init(method: "sources.refresh", description: "重新读取已连接设备，保留已有选择；轮询状态直到 refreshing=false。", properties: [:], required: [], readOnly: false),
        .init(method: "sources.disconnect", description: "断开全部来源；导入或续传待处理时拒绝。不会删除文件。", properties: [:], required: [], readOnly: false),
        .init(method: "assets.filter", description: "调整未导入条件、搜索和日期；媒体范围跟随当前项目的类型。days=[] 表示全部日期。返回当前可选择素材。", properties: ["onlyNew": flag("只显示未导入素材"), "query": .object(["type": .string("string"), "minLength": .integer(0), "description": .string("搜索文件名或设备，空字符串清除")]), "days": array("string"), "mark": choices(["all", "marked", "rated", "twoStars", "threeStars", "fourStars", "fiveStars", "shotMark", "rejected"])], required: [], readOnly: false),
        .init(method: "assets.list", description: "分页列出当前筛选范围内的拍摄素材；id 是拍摄 ID，files 是关联原始文件。用 assets.filter 调整范围。", properties: ["offset": integer(0, 10000000), "limit": integer(1, 200)], required: [], readOnly: true),
        .init(method: "assets.select", description: "按 assets.list 中的拍摄 ID 选择素材。只允许选择当前可见范围，mode 默认为 replace；不下载文件。", properties: ["ids": array("integer"), "mode": choices(["replace", "add", "remove"])], required: ["ids"], readOnly: false),
        .init(method: "import.preview", description: "检查已选项目、所选素材、存放路径、备份和后期软件，返回有效期五分钟的 planId。不会开始传输。设置允许删除原片时必须显式传 allowDeleteOriginals=true。", properties: ["allowDeleteOriginals": flag("明确允许沿用当前删除原片设置")], required: [], readOnly: true),
        .init(method: "import.start", description: "执行 import.preview 返回的 planId。选择、设备连接或设置变化后必须重新预览。同一 planId 重试只返回同一批次，不重复启动。", properties: ["planId": text("预览返回的 planId")], required: ["planId"], readOnly: false),
        .init(method: "import.cancel", description: "取消当前传输，保留已经保存的文件；没有传输时可放弃待续传任务。", properties: [:], required: [], readOnly: false),
        .init(method: "import.resume", description: "继续中断的原任务，沿用其项目和路径。异步进行，使用 app.status 查看进度。", properties: ["allowDeleteOriginals": flag("明确允许当前删除原片设置")], required: [], readOnly: false),
        .init(method: "imports.list", description: "列出最近的导入批次摘要；可按项目 UUID 筛选。", properties: ["projectId": text("项目 UUID"), "offset": integer(0, 10000000), "limit": integer(1, 100)], required: [], readOnly: true),
        .init(method: "imports.get", description: "分页读取批次文件记录，包括原片、代理/XML、副本实际路径、XXH64 及备份结果。", properties: ["id": text("导入批次 UUID"), "offset": integer(0, 10000000), "limit": integer(1, 100)], required: ["id"], readOnly: true)
    ]
    public static func find(_ method: String) -> AgentTool? { all.first { $0.method == method || $0.name == method } }
}
