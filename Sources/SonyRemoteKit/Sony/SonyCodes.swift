import Foundation

// 常量来源：libgphoto2 camlibs/ptp2/ptp.h 等公开源码中的协议事实（见 docs/PROTOCOL.md）。

/// 索尼 SDIO 扩展操作码。
public enum SonyOperation {
    public static let sdioConnect: UInt16 = 0x9201
    public static let getExtDeviceInfo: UInt16 = 0x9202
    public static let getDevicePropDesc: UInt16 = 0x9203
    /// 绝对设置属性值（SetControlDeviceA）。
    public static let setExtDevicePropValue: UInt16 = 0x9205
    /// 按键 / 步进控制（SetControlDeviceB）。
    public static let controlDevice: UInt16 = 0x9207
    public static let getAllExtDevicePropInfo: UInt16 = 0x9209
}

/// 索尼设备属性码。
public enum SonyProperty {
    public static let whiteBalance: UInt16 = 0x5005
    public static let fNumber: UInt16 = 0x5007
    public static let focusMode: UInt16 = 0x500A
    public static let exposureProgramMode: UInt16 = 0x500E
    public static let exposureBias: UInt16 = 0x5010
    public static let shutterSpeed: UInt16 = 0xD20D
    public static let colorTemperature: UInt16 = 0xD20F
    public static let focusFound: UInt16 = 0xD213
    public static let objectInMemory: UInt16 = 0xD215
    public static let batteryLevel: UInt16 = 0xD218
    public static let movieRecordingState: UInt16 = 0xD21D
    public static let iso: UInt16 = 0xD21E
    public static let stillImageStoreDestination: UInt16 = 0xD222
    public static let exposureCompensation: UInt16 = 0xD224
    public static let priorityMode: UInt16 = 0xD25A
}

/// 通过 0x9207 发送的按键控制码。
public enum SonyControl {
    public static let shutterHalfPress: UInt16 = 0xD2C1   // S1，对焦
    public static let shutterFullPress: UInt16 = 0xD2C2   // S2，拍摄
    public static let movieRecord: UInt16 = 0xD2C8

    public static let down: UInt16 = 2
    public static let up: UInt16 = 1
}

public enum SonyEvent {
    public static let objectAdded: UInt16 = 0xC201
    public static let objectRemoved: UInt16 = 0xC202
    public static let propertyChanged: UInt16 = 0xC203
}

public enum SonyObjectHandle {
    /// 刚拍摄、等待传输的照片。
    public static let capturedImage: UInt32 = 0xFFFF_C001
    /// 实时取景帧。
    public static let liveView: UInt32 = 0xFFFF_C002
}

public enum SonyResponse {
    public static let authenticationFailed: UInt16 = 0xA101
    public static let invalidTransactionID: UInt16 = 0x2004
    public static let sessionAlreadyOpenAlt: UInt16 = 0x2013
}

/// GetExtDeviceInfo 里请求和返回的协议版本。
public enum SonyProtocolVersion {
    public static let v300: UInt16 = 0x012C
    public static let v200: UInt16 = 0x00C8
}
