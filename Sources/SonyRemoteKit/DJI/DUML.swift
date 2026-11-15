import Foundation

// 大疆 DUML 帧：蓝牙控制通道和 Wi-Fi 数据通道都用它。
// 协议资料来自 osmosis（KonradIT，MIT）的 MEDIA_PROTOCOL.md 和 OsmoOffload（MIT）的实现，见 THIRD_PARTY_NOTICES.md。
//
//   0   1  SOF 0x55
//   1   1  总长低 8 位（含两段 CRC）
//   2   1  (版本 1 << 2) | 总长高 2 位
//   3   1  CRC8(前 3 字节)
//   4   1  发送方  (id << 5) | type
//   5   1  接收方
//   6   2  消息 ID（小端，相机原样带回）
//   8   1  标志：0x40 请求、0xC0 回复、0x00 推送
//   9   1  命令集
//   10  1  命令 ID
//   11  N  负载
//   +N  2  CRC16(前面所有字节)，小端

public enum DUMLCRC {
    public static func crc8(_ data: some Sequence<UInt8>) -> UInt8 {
        var crc: UInt8 = 0x77
        for b in data {
            crc ^= b
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8C : crc >> 1 }
        }
        return crc
    }

    public static func crc16(_ data: some Sequence<UInt8>) -> UInt16 {
        var crc: UInt16 = 0x3692
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }
}

public struct DUMLFrame: Sendable, Equatable, CustomStringConvertible {
    public static let request: UInt8 = 0x40
    public static let response: UInt8 = 0xC0
    public static let overhead = 13

    public var sender: UInt8
    public var receiver: UInt8
    public var messageID: UInt16
    public var flags: UInt8
    public var commandSet: UInt8
    public var commandID: UInt8
    public var payload: [UInt8]

    public init(sender: UInt8 = DJIAddress.app, receiver: UInt8, messageID: UInt16, flags: UInt8 = DUMLFrame.request,
                commandSet: UInt8, commandID: UInt8, payload: [UInt8] = []) {
        self.sender = sender; self.receiver = receiver; self.messageID = messageID; self.flags = flags
        self.commandSet = commandSet; self.commandID = commandID; self.payload = payload
    }

    public var isRequest: Bool { flags & 0xE0 == Self.request }
    public func matches(_ set: UInt8, _ id: UInt8) -> Bool { commandSet == set && commandID == id }

    public func encoded() -> [UInt8] {
        let total = Self.overhead + payload.count
        precondition(total <= 0x3FF, "DUML 帧太长")
        var out: [UInt8] = [0x55, UInt8(total & 0xFF), 0x04 | UInt8((total >> 8) & 0x03)]
        out.append(DUMLCRC.crc8(out))
        out += [sender, receiver, UInt8(messageID & 0xFF), UInt8(messageID >> 8), flags, commandSet, commandID]
        out += payload
        let c = DUMLCRC.crc16(out)
        out += [UInt8(c & 0xFF), UInt8(c >> 8)]
        return out
    }

    /// 从 `bytes[at...]` 解出一帧，返回帧和用掉的字节数；不是合法的帧时 nil。
    public static func decode(_ bytes: [UInt8], at start: Int = 0) -> (DUMLFrame, Int)? {
        let n = bytes.count - start
        guard n >= overhead, bytes[start] == 0x55, bytes[start + 2] >> 2 == 1,
              DUMLCRC.crc8(bytes[start..<start + 3]) == bytes[start + 3] else { return nil }
        let total = Int(bytes[start + 1]) | (Int(bytes[start + 2] & 0x03) << 8)
        guard total >= overhead, total <= n else { return nil }
        let end = start + total
        let want = UInt16(bytes[end - 2]) | (UInt16(bytes[end - 1]) << 8)
        guard DUMLCRC.crc16(bytes[start..<end - 2]) == want else { return nil }
        let f = DUMLFrame(sender: bytes[start + 4], receiver: bytes[start + 5],
                          messageID: UInt16(bytes[start + 6]) | (UInt16(bytes[start + 7]) << 8),
                          flags: bytes[start + 8], commandSet: bytes[start + 9], commandID: bytes[start + 10],
                          payload: Array(bytes[start + 11..<end - 2]))
        return (f, total)
    }

    /// 逐字节扫描一段数据里所有 CRC 正确的帧（UDP 包里帧前面还有传输头）。
    public static func all(in bytes: [UInt8]) -> [DUMLFrame] {
        var out: [DUMLFrame] = []
        var i = 0
        while i + overhead <= bytes.count {
            if bytes[i] == 0x55, let (f, _) = decode(bytes, at: i) { out.append(f) }
            i += 1
        }
        return out
    }

    public var description: String {
        String(format: "DUML(%02x→%02x id=%04x fl=%02x %02x/%02x ", sender, receiver, messageID, flags, commandSet, commandID)
            + (payload.isEmpty ? "-" : payload.map { String(format: "%02x", $0) }.joined()) + ")"
    }
}

/// 蓝牙通知是分片到达的：把任意长度的数据块拼成完整的帧，遇到垃圾字节就往后找下一个 0x55。
public struct DUMLStreamParser: Sendable {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func feed(_ chunk: some Sequence<UInt8>) -> [DUMLFrame] {
        buffer += chunk
        var out: [DUMLFrame] = []
        while true {
            if let i = buffer.firstIndex(of: 0x55) { buffer.removeFirst(i) } else { buffer.removeAll(); return out }
            guard buffer.count >= DUMLFrame.overhead else { return out }
            guard DUMLCRC.crc8(buffer[0..<3]) == buffer[3] else { buffer.removeFirst(); continue }
            let total = Int(buffer[1]) | (Int(buffer[2] & 0x03) << 8)
            guard total >= DUMLFrame.overhead else { buffer.removeFirst(); continue }
            guard buffer.count >= total else { return out }
            if let (f, used) = DUMLFrame.decode(buffer) { out.append(f); buffer.removeFirst(used) }
            else { buffer.removeFirst() }
        }
    }
}

/// DUML 地址字节 = (id << 5) | type。
public enum DJIAddress {
    public static let app: UInt8 = 0x02
    public static let camera: UInt8 = 0x01
    public static let wifi: UInt8 = 0x07
    /// 会话唤醒 / 保活端点（type 0x10，id 7），不是相机本身。
    public static let session: UInt8 = 0xF0
    /// 0x53/0x10 唤醒的目标（type 0x1C，id 0）。
    public static let wake: UInt8 = 0x1C
}

/// 蓝牙上用到的命令。
public enum DJIBLECommand {
    static func packString(_ s: String) -> [UInt8] {
        let raw = Array(s.utf8.prefix(255))
        return [UInt8(raw.count)] + raw
    }

    /// 0x00/0x2b `04 00`：打开会话，配对前的第一条。
    public static func sessionOpen(_ id: UInt16) -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.session, messageID: id, commandSet: 0x00, commandID: 0x2B, payload: [0x04, 0x00])
    }
    /// 0x00/0x2b `01 01`：保活，整个会话期间约 1 秒一次（空闲 5 秒左右相机就断开）。
    public static func keepalive(_ id: UInt16) -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.session, messageID: id, commandSet: 0x00, commandID: 0x2B, payload: [0x01, 0x01])
    }
    /// 0x53/0x10：唤醒。Pocket 3 会回 e0，但照样醒，不当错误。
    public static func wake(_ id: UInt16) -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.wake, messageID: id, commandSet: 0x53, commandID: 0x10, payload: [0, 0, 0, 0])
    }
    /// 0x07/0x45：配对。回复 `00 01` 已配对过；`00 02` 要在相机上确认，确认后相机发来 0x07/0x46 请求。
    /// `identifier` 是相机记住这台电脑用的键：每次安装生成一次并保存，重试时不能变。
    public static func pair(_ id: UInt16, identifier: String, token: String = "osmo") -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.wifi, messageID: id, commandSet: 0x07, commandID: 0x45,
                  payload: packString(identifier) + packString(token))
    }
    /// 回应相机的 0x07/0x46（用户点了允许）：用相机那条请求自己的消息 ID。
    public static func pairApprovedAck(_ id: UInt16) -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.wifi, messageID: id, flags: DUMLFrame.response, commandSet: 0x07, commandID: 0x46, payload: [0])
    }
    public static func wifiSSID(_ id: UInt16) -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.wifi, messageID: id, commandSet: 0x07, commandID: 0x07)
    }
    public static func wifiPassword(_ id: UInt16) -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.wifi, messageID: id, commandSet: 0x07, commandID: 0x0E)
    }
    /// 0x07/0x47：把相机自己的热点信息发回去，热点约 15 秒后出现。只在热点迟迟不出现时用。
    public static func connectWiFi(_ id: UInt16, ssid: String, password: String) -> DUMLFrame {
        DUMLFrame(receiver: DJIAddress.wifi, messageID: id, commandSet: 0x07, commandID: 0x47,
                  payload: packString(ssid) + packString(password))
    }

    /// `[状态][长度][字符串]` 形式的回复。
    public static func packedString(_ payload: [UInt8]) -> String? {
        guard payload.count >= 2 else { return nil }
        let n = Int(payload[1])
        guard payload.count >= 2 + n else { return nil }
        return String(decoding: payload[2..<2 + n], as: UTF8.self)
    }
}
