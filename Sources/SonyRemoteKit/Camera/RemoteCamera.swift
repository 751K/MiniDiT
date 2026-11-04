import Foundation

/// 界面上展示的可调参数。
public enum CameraSettingKind: String, CaseIterable, Identifiable, Sendable {
    case shutterSpeed, aperture, iso, exposureCompensation, whiteBalance

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .shutterSpeed: "快门"
        case .aperture: "光圈"
        case .iso: "ISO"
        case .exposureCompensation: "曝光补偿"
        case .whiteBalance: "白平衡"
        }
    }
}

public struct SettingOption: Identifiable, Hashable, Sendable {
    public let value: Int64
    public let label: String
    public var id: Int64 { value }
    public init(value: Int64, label: String) { self.value = value; self.label = label }
}

public struct CameraSetting: Identifiable, Sendable, Equatable {
    public let kind: CameraSettingKind
    public var currentValue: Int64?
    public var valueText: String
    public var options: [SettingOption]
    public var isEditable: Bool
    public var id: CameraSettingKind { kind }

    public init(kind: CameraSettingKind, currentValue: Int64?, valueText: String, options: [SettingOption], isEditable: Bool) {
        self.kind = kind
        self.currentValue = currentValue
        self.valueText = valueText
        self.options = options
        self.isEditable = isEditable
    }
}

public struct CameraStatus: Sendable, Equatable {
    public var settings: [CameraSetting]
    public var modeText: String
    public var batteryText: String?
    public var isRecording: Bool
    public var isFocused: Bool
    /// 相机内等待传到手机的文件数。
    public var pendingTransfers: Int

    public init(settings: [CameraSetting] = [], modeText: String = "", batteryText: String? = nil,
                isRecording: Bool = false, isFocused: Bool = false, pendingTransfers: Int = 0) {
        self.settings = settings
        self.modeText = modeText
        self.batteryText = batteryText
        self.isRecording = isRecording
        self.isFocused = isFocused
        self.pendingTransfers = pendingTransfers
    }
}

public struct CapturedFile: Sendable {
    public let filename: String
    public let data: Data
    public init(filename: String, data: Data) { self.filename = filename; self.data = data }
}

public enum CameraNotification: Sendable, Equatable {
    /// 参数、状态有变化，应重新读取 status。
    case statusChanged
    /// 相机有新文件可以下载。
    case fileAvailable
    case disconnected
}

/// APP 与具体相机实现之间的接口。
public protocol RemoteCamera: AnyObject, Sendable {
    var displayName: String { get async }
    var notifications: AsyncStream<CameraNotification> { get }

    func refreshStatus() async throws -> CameraStatus
    /// 取一帧实时取景 JPEG；相机还没准备好时返回 nil。
    func liveViewFrame() async throws -> Data?

    func halfPress(_ down: Bool) async throws
    /// 完整拍照：半按 → 全按 → 松开。
    func capture() async throws
    func setRecording(_ on: Bool) async throws

    func set(_ kind: CameraSettingKind, value: Int64) async throws
    func step(_ kind: CameraSettingKind, by delta: Int) async throws

    /// 下载相机里所有等待传输的文件。
    func downloadPendingFiles() async throws -> [CapturedFile]

    func disconnect() async
}
