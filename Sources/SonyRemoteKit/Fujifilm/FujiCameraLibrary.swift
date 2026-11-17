import Foundation

/// 通过 Wi-Fi「无线通信」浏览、下载富士相机里的照片和视频。按 libfuji 的 `fuji_setup` 流程建立会话（未用真机验证）。
public actor FujiCameraLibrary: CameraLibrary {
    private let client: FujiPTPClient
    private let info: CameraDeviceInfo
    public nonisolated let connectionLost: AsyncStream<Void>
    public private(set) var listingNotes: [String] = []
    private var infoCache: [UInt32: PTPObjectInfo] = [:]
    private var correctSizeOn = false
    private let log: @Sendable (String) -> Void

    init(client: FujiPTPClient, info: CameraDeviceInfo, notes: [String], log: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.info = info
        self.listingNotes = notes
        self.log = log
        connectionLost = client.closed
    }

    public var deviceInfo: CameraDeviceInfo? { info }

    /// 连上相机并完成富士的会话设置。`waitForOK` 时间内等用户在相机上按 OK。
    public static func open(host: String = FujiWiFi.defaultHost, port: UInt16 = FujiWiFi.commandPort,
                            identity: PTPIPHostIdentity, waitForOK: TimeInterval = 120,
                            auxiliaryPorts: (event: UInt16, liveView: UInt16) = (FujiWiFi.eventPort, FujiWiFi.liveViewPort),
                            progress: @escaping @Sendable (String) -> Void = { _ in },
                            log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> FujiCameraLibrary {
        typealias P = FujiWiFi.Prop
        let client = FujiPTPClient(host: host, port: port, identity: identity)
        progress(String(localized: "正在连接富士相机…", bundle: .miniDiT))
        try await client.connect()
        do {
            try await Task.sleep(for: .milliseconds(60))
            try await client.openSession()
            var notes: [String] = []
            var events = try await client.poll()
            var state = events[P.state] ?? 0
            if state == FujiWiFi.State.waiting {
                progress(String(localized: "请在相机上按 OK，允许这台 Mac 连接。", bundle: .miniDiT))
                let deadline = Date().addingTimeInterval(waitForOK)
                while state == FujiWiFi.State.waiting {
                    guard Date() < deadline else { throw FujiWiFi.Failure.notConfirmed }
                    try await Task.sleep(for: .milliseconds(100))
                    events = try await client.poll()
                    state = events[P.state] ?? 0
                }
            }
            func value(_ code: UInt16) async -> Data? {
                guard let r = try? await client.transaction(PTPOperation.getDevicePropValue, [UInt32(code)], requireOK: false),
                      r.code == PTPResponse.ok, !r.data.isEmpty else { return nil }
                return r.data
            }
            let remoteVersion = await value(P.remoteVersion).flatMap(FujiWiFi.integer)
            notes.append(String(format: "富士：状态 %d，RemoteVersion %@", state, remoteVersion.map { String(format: "0x%X", $0) } ?? "无"))
            // 切到对应的模式；新机身可能在屏幕上弹「是 / 否」，多等一会儿。
            let mode: UInt32 = (remoteVersion != nil || state == FujiWiFi.State.remote) ? 5 : state
            progress(String(localized: "正在建立连接，相机上如有提示请选择“是”。", bundle: .miniDiT))
            try await client.setProperty(P.mode, FujiWiFi.encode(mode, width: 2), timeout: 90)
            events = try await client.poll()
            _ = await value(P.storage)
            // 回报客户端版本。
            if state == FujiWiFi.State.autoSave, let v = await value(P.autoSaveVersion) {
                try? await client.setProperty(P.autoSaveVersion, v)
            } else if remoteVersion == nil, let v = await value(P.imageGetVersion) {
                try? await client.setProperty(P.imageGetVersion, v)
            } else if remoteVersion != nil {
                try? await client.setProperty(P.remoteVersion, FujiWiFi.encode(0x2000C, width: 4))
            }
            if state == FujiWiFi.State.remote {
                try await remoteGallery(client, auxiliaryPorts: auxiliaryPorts, value: value)
            }
            events = try await client.poll()
            let model = await client.cameraName
            log("富士相机：\(model)，状态 \(events[P.state] ?? state)")
            return FujiCameraLibrary(client: client, info: CameraDeviceInfo(manufacturer: "FUJIFILM", model: model, version: "", serialNumber: ""),
                                     notes: notes, log: log)
        } catch {
            await client.shutdown()
            throw error
        }
    }

    /// 状态 6（远程访问）要先开一次拍摄会话、连上事件和取景端口，再切到「远程看图」模式。
    private static func remoteGallery(_ client: FujiPTPClient, auxiliaryPorts: (event: UInt16, liveView: UInt16),
                                      value: (UInt16) async -> Data?) async throws {
        typealias P = FujiWiFi.Prop
        _ = try? await client.transaction(FujiWiFi.Op.getPropertyDescriptors, requireOK: false)
        let open = try await client.transaction(FujiWiFi.Op.initiateOpenCapture, [0, 0], requireOK: false)
        let openTID = await client.lastTransactionID
        _ = try await client.poll()
        if open.code == PTPResponse.ok {
            await client.openAuxiliary(port: auxiliaryPorts.event)
            await client.openAuxiliary(port: auxiliaryPorts.liveView)
            _ = try? await client.transaction(FujiWiFi.Op.terminateOpenCapture, [openTID], requireOK: false)
        }
        _ = try await client.poll()
        try? await client.setProperty(P.state, FujiWiFi.encode(FujiWiFi.State.remote, width: 2))
        _ = try await client.poll()
        _ = try await client.poll()
        try await client.setProperty(P.mode, FujiWiFi.encode(11, width: 2), timeout: 30)
        _ = try await client.poll()
        let width = await value(P.remoteGetObjectVersion)?.count == 4 ? 4 : 2
        try? await client.setProperty(P.remoteGetObjectVersion, FujiWiFi.encode(5, width: width))
        _ = try await client.poll()
    }

    // MARK: 列表

    public func folders() async throws -> [CameraFolder] {
        [CameraFolder(id: 0, storageID: FujiWiFi.storageID, name: String(localized: "全部文件", bundle: .miniDiT), isVideo: false, isFlat: true)]
    }

    public func handles(in folder: CameraFolder) async throws -> [UInt32] {
        let events = try await client.poll()
        var count = events[FujiWiFi.Prop.objectCount]
        if count == nil {
            count = FujiWiFi.integer(try await client.getProperty(FujiWiFi.Prop.objectCount))
        }
        let n = count ?? 0
        listingNotes.append("富士：\(n) 个文件")
        guard n > 0 else { return [] }
        // 句柄就是 1…N；编号大的通常是新的。
        return Array((1...n).reversed())
    }

    private func objectInfo(_ handle: UInt32) async throws -> PTPObjectInfo {
        if let i = infoCache[handle] { return i }
        if !correctSizeOn {
            // 不开这个属性时 ObjectInfo 里的大小是假的。
            try? await client.setProperty(FujiWiFi.Prop.correctFileSize, FujiWiFi.encode(1, width: 2))
            correctSizeOn = true
        }
        let r = try await client.transaction(PTPOperation.getObjectInfo, [handle])
        let i = try PTPObjectInfo.parse(r.data)
        infoCache[handle] = i
        return i
    }

    public func item(_ handle: UInt32) async throws -> CameraContentItem {
        CameraContentItem(handle: handle, info: try await objectInfo(handle))
    }

    public func sourcePath(_ handle: UInt32) async -> String? { nil }

    public func thumbnail(_ handle: UInt32) async throws -> Data? {
        // 新机身要先读过 ObjectInfo，否则 GetThumb 会卡住。
        _ = try await objectInfo(handle)
        let r = try await client.transaction(PTPOperation.getThumb, [handle], requireOK: false)
        return r.code == PTPResponse.ok && !r.data.isEmpty ? r.data : nil
    }

    public func preview(_ handle: UInt32) async throws -> Data? { try await thumbnail(handle) }
    public func exif(_ handle: UInt32) async -> ShotExif? { nil }
    public func kinds(in folder: CameraFolder) async -> [UInt32: CameraContentItem.Kind]? { nil }

    public func refresh() async {
        infoCache = [:]
        listingNotes = []
    }

    // MARK: 下载

    public func download(_ item: CameraContentItem, to url: URL, from offset: UInt64,
                         progress: @escaping @Sendable (UInt64, UInt64) -> Void) async throws {
        _ = try? await client.poll()
        let size: UInt64? = item.sizeKnown && item.size > 0 ? item.size : nil
        let (fh, start) = try openForResume(url, offset: offset)
        defer { try? fh.close() }
        var done = start
        while size.map({ done < $0 }) ?? true {
            try Task.checkCancellation()
            guard done < UInt64(UInt32.max) else { throw FujiWiFi.Failure.protocolError(String(localized: "不支持 4 GB 以上的文件", bundle: .miniDiT)) }
            let want = size.map { UInt32(min(UInt64(FujiWiFi.downloadChunk), $0 - done)) } ?? FujiWiFi.downloadChunk
            let r = try await client.transaction(PTPOperation.getPartialObject, [item.id, UInt32(done), want])
            try fh.write(contentsOf: r.data)
            done += UInt64(r.data.count)
            progress(done, max(size ?? done, done))
            if r.data.isEmpty || (size == nil && r.data.count < Int(want)) { break }
        }
        if let size, done < size { throw PTPDecodeError.invalid(String(localized: "文件不完整：\(done)/\(size) 字节", bundle: .miniDiT)) }
        _ = try? await client.poll()
    }

    public func close() async {
        if correctSizeOn {
            try? await client.setProperty(FujiWiFi.Prop.correctFileSize, FujiWiFi.encode(0, width: 2))
        }
        await client.shutdown()
    }
}
