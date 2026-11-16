import Foundation

/// 只读摸底：连上索尼相机（遥控模式），把相机报告的全部属性原样读出来，不写任何属性。
/// 用于确认某台机身（比如 α7 V）到底提供哪些属性、编码是什么，再决定怎么做控制工具。
///
/// 发出的操作只有：GetDeviceDescriptionFile、OpenSession、GetDeviceInfo、SDIO_Connect 1/2/3、
/// GetExtDeviceInfo、GetAllExtDevicePropInfo。SDIO_Connect 是索尼遥控必需的握手，不改相机设置。
/// 和 SonyCamera.connect 不同：不设 PriorityMode，也不改照片存储位置。
public struct SonyPropertyDump: Sendable {
    public struct Entry: Sendable {
        public let desc: SonyPropertyDesc
        /// 这条记录在原始数据里的起止字节（便于离线核对解析）。
        public let offset: Int
        public let length: Int
    }

    public let deviceInfo: CameraDeviceInfo?
    public let protocolVersion: UInt16
    /// GetExtDeviceInfo 的两张表：属性码、控制码（按相机给出的顺序）。
    public let advertisedProperties: [UInt16]
    public let advertisedControls: [UInt16]
    public let entries: [Entry]
    /// GetAllExtDevicePropInfo 开头声明的记录数。
    public let declaredCount: Int?
    /// 解析在哪里停下、为什么（nil = 全部解析完）。
    public let parseError: String?
    /// GetAllExtDevicePropInfo 的原始数据。
    public let raw: Data
    public let rawExtDeviceInfo: Data
    /// DigitalImagingDesc.xml 里的能力标记。
    public let capabilities: [String: String]

    public static func read(host: String, port: UInt16 = PTPIPClient.defaultPort, identity: PTPIPHostIdentity,
                            tunnel: CameraSSHTunnel? = nil,
                            progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> SonyPropertyDump {
        let client = PTPIPClient(host: host, port: port, identity: identity, tunnel: tunnel)
        progress("connecting")
        try await client.connect()
        do {
            let caps = await SonySDIO.capabilities(client)
            progress("opening session")
            try await SonySDIO.openSession(client, mode: nil)
            progress("SDIO handshake")
            let ext = try await SonySDIO.handshake(client)
            let info: CameraDeviceInfo? = await {
                guard let r = try? await client.transaction(PTPOperation.getDeviceInfo, requireOK: false),
                      r.code == PTPResponse.ok else { return nil }
                return CameraDeviceInfo.parse(r.data)
            }()
            let extRaw = try await client.transaction(SonyOperation.getExtDeviceInfo, [UInt32(SonyProtocolVersion.v300), 1]).data
            let lists = (try? parseLists(extRaw)) ?? (ext.version, Array(ext.codes).sorted(), [])
            progress("reading properties")
            let raw = try await client.transaction(SonyOperation.getAllExtDevicePropInfo).data
            let parsed = parse(raw)
            await client.shutdown()
            return SonyPropertyDump(deviceInfo: info, protocolVersion: lists.0, advertisedProperties: lists.1,
                                    advertisedControls: lists.2, entries: parsed.entries, declaredCount: parsed.declared,
                                    parseError: parsed.error, raw: raw, rawExtDeviceInfo: extRaw, capabilities: caps)
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// 0x9202：u16 版本 + u32 个属性码 + u32 个控制码。
    public static func parseLists(_ data: Data) throws -> (UInt16, [UInt16], [UInt16]) {
        var r = PTPReader(data)
        let version = try r.u16()
        let props = r.remaining >= 4 ? try r.array { try $0.u16() } : []
        let controls = r.remaining >= 4 ? try r.array { try $0.u16() } : []
        return (version, props, controls)
    }

    /// 逐条解析 0x9209，记下每条的位置；解析不了时停下并说明位置和原因（已解析的保留）。
    public static func parse(_ data: Data) -> (entries: [Entry], declared: Int?, error: String?) {
        var r = PTPReader(data)
        guard let n = try? r.u32(), (try? r.skip(4)) != nil else { return ([], nil, "data shorter than 8-byte header") }
        var out: [Entry] = []
        while r.remaining >= 6 {
            let start = r.offset
            do {
                let d = try SonyPropertyDesc.parse(&r)
                out.append(Entry(desc: d, offset: start, length: r.offset - start))
            } catch {
                let code = data.count >= start + 2 ? UInt16(data[data.startIndex + start]) | UInt16(data[data.startIndex + start + 1]) << 8 : 0
                return (out, Int(n), String(format: "stopped at byte %d (record %d, code 0x%04X): ", start, out.count, code) + "\(error)")
            }
        }
        if r.remaining > 0 { return (out, Int(n), "\(r.remaining) trailing bytes after record \(out.count)") }
        return (out, Int(n), nil)
    }
}
