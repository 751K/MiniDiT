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
        .init(method: "tether.start", description: "开始索尼联机拍摄（Wi-Fi，相机需开启“电脑遥控”）。不传 host 时用当前连接的索尼相机。会断开当前来源，改为遥控相机；拍到的照片先存入联机缓存，并按当前项目设置自动导入（未选项目时等待）。连接异步进行，轮询 tether.status。", properties: ["host": text("相机主机名或 IP，不含端口和凭据（可省略）")], required: [], readOnly: false),
        .init(method: "tether.status", description: "查询联机拍摄状态：是否连接、拍摄模式、电量、各曝光参数的当前值与可选值、对焦/录像状态、已接收数量、最近一张的文件与 EXIF、自动导入设置和联机缓存位置。", properties: [:], required: [], readOnly: true),
        .init(method: "tether.shoot", description: "拍摄一张（半按对焦、全按、松开）。立即返回；照片接收和自动导入通过 tether.status 的 shotCount、lastShot 和 app.status 的 progress 观察。", properties: [:], required: [], readOnly: false),
        .init(method: "tether.set", description: "调整曝光参数。value（原始值）、label（tether.status 的选项文字，如 1/250、F4.0、400）或 step（相对档位，正数增大）三选一。当前拍摄模式下由相机决定的参数不能调整。", properties: ["setting": choices(["shutterSpeed", "aperture", "iso", "exposureCompensation", "whiteBalance"]), "value": integer(Int(Int32.min), Int(UInt32.max)), "label": text("选项文字"), "step": integer(-20, 20)], required: ["setting"], readOnly: false),
        .init(method: "tether.focus", description: "锁定（半按快门并保持）或释放对焦。", properties: ["locked": flag("true 锁定，false 释放")], required: ["locked"], readOnly: false),
        .init(method: "tether.record", description: "开始或停止录像。录像保存在相机存储卡上，不会传到 Mac。", properties: ["on": flag("true 开始，false 停止")], required: ["on"], readOnly: false),
        .init(method: "tether.live_view", description: "取当前的一帧实时取景，返回 JPEG 图像（MCP 中为图片内容）。需要取景开启。", properties: ["maxWidth": integer(160, 1600)], required: [], readOnly: true),
        .init(method: "tether.configure", description: "设置拍摄后是否自动导入当前项目、是否开启实时取景（关闭后照片接收更快）。", properties: ["autoImport": flag("拍摄后自动导入当前项目"), "liveView": flag("实时取景")], required: [], readOnly: false),
        .init(method: "tether.properties", description: "列出相机报告的全部属性：编号、SDK 名称、数据类型、是否可写（不可写时说明是仅显示还是未启用）、当前值、可选值或取值范围。已核实的属性带可读写法（1/1000、F5.6、3200K、ST、+3）。可按名称或编号筛选。", properties: ["query": text("名称或编号的片段，如 CreativeLook、D0F"), "writableOnly": flag("只列可写的")], required: [], readOnly: true),
        .init(method: "tether.get", description: "读取指定属性的当前值（现读，不用缓存）。名称用 tether.properties 里的 SDK 名称，或 0xD20D 这样的编号；常用别名：ISO、Shutter、Aperture、ColorTemp。", properties: ["names": array("string")], required: ["names"], readOnly: true),
        .init(method: "tether.set_properties", description: "按顺序设置一个或多个属性，每项设置后回读确认；读回值与请求不符、不可写、取值不合法、相机忙时报错并说明原因，已生效的项会列出。assignments 每项写成 NAME=VALUE，VALUE 可用可读写法或原始值，如 ISO=400、ShutterSpeed=1/1000、FNumber=F5.6、WhiteBalance=ColorTemp、Colortemp=3200K、CreativeLook=ST、CreativeLook_Contrast=+3。", properties: ["assignments": array("string"), "timeoutSeconds": integer(1, 30)], required: ["assignments"], readOnly: false),
        .init(method: "tether.capture", description: "拍一张并等待这次的所有文件（RAW + HEIF/JPEG）完整写到电脑后才返回：文件路径、大小和拍摄前的参数快照。照片同时保存在存储卡上。给 outDir 时另复制一份到该目录，重名报错、不覆盖。超时报错。", properties: ["outDir": text("复制到的目录绝对路径（可省略）"), "timeoutSeconds": integer(5, 300)], required: [], readOnly: false),
        .init(method: "tether.files", description: "列出存储卡上的文件（新的在前）：文件名、卡上路径、大小、拍摄时间、类型、卡槽。用远程传输读取，联机时可以直接用。", properties: ["latest": integer(1, 1000), "slot": integer(1, 2)], required: [], readOnly: true),
        .init(method: "tether.download", description: "按文件名从存储卡下载到 outDir；视频同时写出内嵌的 XML（C0001M01.XML）。目标已有同名文件时报 file_exists，一个都不下载。两个卡槽有同名文件时用 slot 指定（默认卡槽 1）。", properties: ["names": array("string"), "outDir": text("下载到的目录绝对路径"), "slot": integer(1, 2)], required: ["names", "outDir"], readOnly: false),
        .init(method: "tether.record_clip", description: "录一段指定秒数的视频，等片段出现在存储卡上；给 outDir 时把视频和同名 XML 下载到该目录（不覆盖）。返回片段信息和本地路径；下载时附实际时长 durationSeconds（α7 V 上开始、停止各有延迟，2 秒约录到 1.5 秒）。", properties: ["seconds": integer(1, 3600), "outDir": text("下载到的目录绝对路径（可省略）"), "timeoutSeconds": integer(5, 600)], required: ["seconds"], readOnly: false),
        .init(method: "tether.stop", description: "结束联机拍摄，断开相机。联机缓存里的照片仍作为来源保留，可继续选择和导入。", properties: [:], required: [], readOnly: false),
        .init(method: "imports.get", description: "分页读取批次文件记录，包括原片、代理/XML、副本实际路径、XXH64 及备份结果。", properties: ["id": text("导入批次 UUID"), "offset": integer(0, 10000000), "limit": integer(1, 100)], required: ["id"], readOnly: true)
    ]
    public static func find(_ method: String) -> AgentTool? { all.first { $0.method == method || $0.name == method } }
}
