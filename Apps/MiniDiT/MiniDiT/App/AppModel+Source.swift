import AppKit
import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {

    // MARK: 搜索

    func search() {
        guard phase == .idle else { return }
        phase = .searching
        errorMessage = nil
        notice = nil
        log.add("搜索相机：\(CameraFinder.networkSummary())")
        let known = knownCameras
        connectTask = Task {
            let result = await CameraFinder.search(known: known) { s in
                Task { @MainActor in self.status = s }
            }
            found = result
            searched = true
            networkBlocked = result.isEmpty ? await CameraFinder.localNetworkBlocked() : false
            if networkBlocked { log.add("搜索：看起来没有本地网络权限") }
            log.add("搜索结果：\(result.map { "\($0.host)\($0.knownName.map { "（\($0)）" } ?? "")" })")
            if phase == .searching { phase = .idle }
            status = ""
        }
    }

    /// 启动时连上次的相机：先试上次的地址，不行再搜一遍子网找认识的相机。
    func autoConnectLast() async {
        guard let last = knownCameras.first else { return }
        phase = .searching
        status = String(localized: "正在查找上次使用的相机“\(last.name)”…")
        log.add("自动连接：先试 \(last.host)")
        if let cam = await probe(host: last.host), cam.fingerprint == last.fingerprint {
            await connect(FoundCamera(host: cam.host, kind: cam.kind, knownName: last.name))
            return
        }
        if Task.isCancelled { endCancelled(); return }
        status = String(localized: "无法连接上次的地址，正在搜索…")
        let result = await CameraFinder.search(known: knownCameras) { s in Task { @MainActor in self.status = s } }
        found = result
        searched = true
        if Task.isCancelled { endCancelled(); return }
        if let cam = result.first(where: { $0.knownName != nil }) {
            await connect(cam)
        } else {
            log.add("自动连接：没找到连过的相机")
            phase = .idle
            status = ""
        }
    }

    /// 检查某个地址上有没有相机（先 PTP/IP 直连，再 SSH）。
    func probe(host: String) async -> FoundCamera? {
        if await CameraDiscovery.probe(host: host, port: PTPIPClient.defaultPort, timeout: 1.5) {
            return FoundCamera(host: host, kind: .direct)
        }
        if let (key, _) = try? await CameraSSHTunnel.probe(host: host, timeout: 4) {
            return FoundCamera(host: host, kind: .ssh(fingerprint: key.sha256Base64))
        }
        return nil
    }

    func connect(host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        connectTask = Task {
            phase = .connecting
            status = String(localized: "正在检查 \(h)…")
            if let cam = await probe(host: h) {
                let name = knownCameras.first { $0.fingerprint == cam.fingerprint }?.name
                await connect(FoundCamera(host: cam.host, kind: cam.kind, knownName: name))
                return
            }
            if Task.isCancelled { endCancelled(); return }
            phase = .idle
            errorMessage = String(localized: "在 \(h) 上未找到相机（端口 22 和 15740 均无法连接）。请确认相机已开机并开启“遥控拍摄”，且与本机处于同一网络。")
        }
    }

    /// 当前连着的相机的指纹（读卡器为 nil）。
    var currentFingerprint: String? { sourceKind == .camera ? lastCamera?.fingerprint : nil }


    func switchTo(known k: KnownCamera) {
        guard progress == nil, switchingTo == nil else { return }
        switchingTo = k.fingerprint
        Task {
            defer { switchingTo = nil }
            guard let cam = await probe(host: k.host), cam.fingerprint == k.fingerprint else {
                errorMessage = String(localized: "“\(k.name)”离线（上次地址为 \(k.host)），未切换。若相机地址已变更，可通过“文件 › 切换来源…”重新搜索。")
                return
            }
            let target = FoundCamera(host: cam.host, kind: cam.kind, knownName: k.name)
            disconnect()
            connectTask = Task { await self.connect(target) }
        }
    }

    func switchTo(card url: URL) {
        guard progress == nil else { return }
        disconnect()
        openCard(url)
    }

    /// 连过的相机：只认指纹相同的设备（同一个地址上可能换成了别的机器）。
    func connect(known k: KnownCamera) {
        connectTask = Task {
            phase = .connecting
            connectingHost = k.host
            status = String(localized: "正在查找“\(k.name)”…")
            if let cam = await probe(host: k.host), cam.fingerprint == k.fingerprint {
                await connect(FoundCamera(host: cam.host, kind: cam.kind, knownName: k.name))
                return
            }
            connectingHost = nil
            if Task.isCancelled { endCancelled(); return }
            phase = .idle
            status = ""
            errorMessage = String(localized: "“\(k.name)”未连接。请打开相机或重新搜索。")
        }
    }

    func connect(_ cam: FoundCamera) {
        connectTask = Task { await connect(cam) }
    }

    private func connect(_ cam: FoundCamera) async {
        // 已经被取消（比如用户取消了自动连接、转去打开存储卡）：不能再动界面状态。
        guard !Task.isCancelled else { return }
        phase = .connecting
        connectingHost = cam.host
        defer { connectingHost = nil }
        errorMessage = nil
        notice = nil
        log.add("连接 \(cam.host)")
        do {
            let (lib, remote) = try await openLibrary(cam)
            if Task.isCancelled { await lib.close(); throw CancellationError() }
            primaryConnectionID = UUID()
            sessionCameraProfiles[Self.primarySource] = nil
            usesRemoteTransfer = remote
            sourceKind = .camera
            deviceInfo = await lib.deviceInfo
            cameraID = deviceInfo?.cameraID
            let modelName = deviceInfo.map(\.displayName) ?? ""
            // 用户起过的名字优先；名字还是 IP（以前没读到型号）就换成机型名。
            let known = knownCameras.first { $0.fingerprint == cam.fingerprint }
            let keepName = cam.knownName.flatMap { n in (known?.nameIsAddress ?? false) || n == cam.host ? nil : n }
            let name = keepName ?? (modelName.isEmpty ? (cam.knownName ?? cam.host) : modelName)
            attach(lib, name: name, host: cam.host)
            lastCamera = FoundCamera(host: cam.host, kind: cam.kind, knownName: name)
            KnownCamera.remember(KnownCamera(fingerprint: cam.fingerprint, host: cam.host, name: name, lastSeen: Date(),
                                             model: deviceInfo?.model ?? known?.model, firmware: deviceInfo?.version ?? known?.firmware))
            knownCameras = KnownCamera.load()
            if let deviceInfo { log.add("相机：\(deviceInfo.model) 固件 \(deviceInfo.version)，机身 ID \(cameraID ?? "无")") }
            if let ops = deviceInfo?.operations, !ops.isEmpty {
                log.add("相机支持的操作：" + ops.sorted().map { String(format: "%04X", $0) }.joined(separator: " "))
            }
            await loadAll()
            refreshCaptureOne()
        } catch is CancellationError {
            log.add("已取消连接")
            endCancelled()
            return
        } catch {
            log.add("连接失败：\(error.localizedDescription) ｜ \(String(reflecting: error))")
            errorMessage = String(localized: "连接失败：\(error.localizedDescription)")
            phase = .idle
        }
        status = ""
    }

    func attach(_ lib: any CameraLibrary, name: String, host: String?) {
        library = lib
        connectedHost = host
        connectedName = name
        let lost = lib.connectionLost
        watchTask = Task { [weak self] in
            for await _ in lost {
                self?.handleLost()
                return
            }
        }
    }

    /// 打开相机的存储卡接口。返回是否用的远程传输（不改主来源的状态，同时连接第二台相机时也用它）。
    private func openLibrary(_ cam: FoundCamera, interactive: Bool = true) async throws -> (any CameraLibrary, remote: Bool) {
        let step: @Sendable (String) -> Void = { s in Task { @MainActor in self.status = s; self.log.add(s) } }
        if let nikon = try await openOtherBrandIfNeeded(cam, step: step) { return (nikon, false) }
        do {
            let tunnel = try await prepareTunnel(cam, interactive: interactive)
            let lib = try await SonyRemoteTransferLibrary.open(host: cam.host, identity: HostIdentityStore.identity,
                                                               tunnel: tunnel, progress: step)
            log.add("使用远程传输（相机界面不锁，可读两个卡槽）")
            return (lib, true)
        } catch let e where e is SonyRemoteTransferError || e is PTPError {
            log.add("远程传输不可用（\(e.localizedDescription)），改用内容传输模式")
            try? await Task.sleep(for: .milliseconds(800))
            let tunnel = try await prepareTunnel(cam, interactive: interactive)
            return (try await SonyContentsTransfer.openLibrary(host: cam.host, identity: HostIdentityStore.identity,
                                                               tunnel: tunnel, progress: step), false)
        }
    }

    /// 直连的相机先握一次手看 GUID 和名字：尼康走尼康的配对和标准 PTP，佳能（EOS）走标准 PTP，其他的照旧走索尼流程。
    /// 已经知道是索尼的机型（上次读到的型号）不再多握这一次。
    private func openOtherBrandIfNeeded(_ cam: FoundCamera, step: @escaping @Sendable (String) -> Void) async throws -> (any CameraLibrary)? {
        guard case .direct = cam.kind else { return nil }
        let model = knownCameras.first { $0.fingerprint == cam.fingerprint }?.model ?? ""
        if ["ILCE", "ILME", "ILCA", "ZV-", "DSC-"].contains(where: { model.hasPrefix($0) }) { return nil }
        let probe: (nikon: Bool, name: String)
        do {
            probe = try await NikonWiFi.probe(host: cam.host, identity: HostIdentityStore.identity)
        } catch {
            // 握手被拒：尼康是「配对了别的电脑」，佳能是「这台 Mac 还没配对」。看 mDNS 里有没有佳能分辨。
            let refused: Bool
            if case PTPIPTransportError.initFailed = error { refused = true }
            else { refused = (error as? NikonWiFi.Failure) == .pairedToAnotherComputer }
            // 佳能在配对状态下可能等用户在机身上确认后才回握手，探测会超时：这时直接走佳能的连接，多等一会儿。
            if await CanonBonjour.isAdvertising() {
                if refused {
                    log.add("佳能相机：\(cam.host) 拒绝了握手（尚未配对）")
                    throw CanonWiFi.Failure.notPaired
                }
                log.add("佳能相机：\(cam.host) 探测未完成（\(error.localizedDescription)），按佳能连接")
                step(String(localized: "请在相机上确认与这台 Mac 的连接…"))
                return try await CanonWiFi.openLibrary(host: cam.host, identity: HostIdentityStore.identity, progress: step)
            }
            if error is NikonWiFi.Failure { throw error }
            return nil
        }
        if !probe.nikon, CanonWiFi.looksLikeCanon(name: probe.name) {
            log.add("佳能相机：\(cam.host)（\(probe.name)）")
            try await Task.sleep(for: .milliseconds(500))
            return try await CanonWiFi.openLibrary(host: cam.host, identity: HostIdentityStore.identity, progress: step)
        }
        guard probe.nikon else { return nil }
        log.add("尼康相机：\(cam.host)")
        try await Task.sleep(for: .milliseconds(500))
        let needsPairing = await NikonBonjour.needsPairing()
        log.add("尼康相机：mDNS 配对状态 \(needsPairing.map { $0 ? "未配对" : "已配对" } ?? "未知")")
        return try await NikonWiFi.openLibrary(host: cam.host, identity: HostIdentityStore.identity, needsPairing: needsPairing,
            showCode: { code in
                Task { @MainActor in
                    self.status = String(localized: "配对码 \(code)：请确认与相机屏幕上显示的一致，然后在相机上确认配对。")
                    self.log.add("尼康相机：配对码 \(code)")
                }
            }, progress: step)
    }

    func prepareTunnel(_ cam: FoundCamera, interactive: Bool = true) async throws -> CameraSSHTunnel? {
        guard case .ssh(let fingerprint) = cam.kind else { return nil }
        var creds = CredentialStore.load(fingerprint)
        if creds == nil {
            guard interactive else { throw CancellationError() }
            creds = await askCredentials(host: cam.host, message: nil, prefillUser: nil)
        }
        while true {
            guard var current = creds else { throw CancellationError() }
            try Task.checkCancellation()
            status = String(localized: "正在建立加密连接…")
            do {
                let trusted = current.trustedFingerprint
                let tunnel = try await CameraSSHTunnel.open(host: cam.host, credentials: current) { key in
                    if let trusted, trusted == key.sha256Base64 { return true }
                    guard interactive else { return false }
                    return await self.confirmFingerprint(host: cam.host, key: key)
                }
                current.trustedFingerprint = tunnel.hostKey.sha256Base64
                CredentialStore.save(current, tunnel.hostKey.sha256Base64)
                log.add("加密连接成功：\(tunnel.hostKey.keyType) \(tunnel.hostKey.sha256Base64)；\(tunnel.negotiated?.description ?? "")")
                return tunnel
            } catch SSHTunnelError.authenticationFailed(let detail) {
                guard interactive else { throw CancellationError() }
                log.add("访问身份验证失败：用户名「\(current.username)」，密码 \(current.password.count) 个字符；\(detail)")
                creds = await askCredentials(host: cam.host, message: String(localized: "用户名或密码不正确，请对照相机上的“访问身份验证信息”重新输入。"),
                                             prefillUser: current.username)
            } catch SSHTunnelError.hostKeyRejected {
                throw CancellationError()
            }
        }
    }

    private func askCredentials(host: String, message: String?, prefillUser: String?) async -> SSHCredentials? {
        await withCheckedContinuation { cont in
            credentialContinuation = cont
            credentialRequest = CredentialRequest(host: host, message: message, prefillUser: prefillUser)
        }
    }

    func submitCredentials(_ creds: SSHCredentials?) {
        credentialRequest = nil
        credentialContinuation?.resume(returning: creds)
        credentialContinuation = nil
    }

    private func confirmFingerprint(host: String, key: SSHHostKeyInfo) async -> Bool {
        await withCheckedContinuation { cont in
            fingerprintContinuation = cont
            fingerprintRequest = FingerprintRequest(host: host, key: key)
        }
    }

    func answerFingerprint(_ ok: Bool) {
        fingerprintRequest = nil
        fingerprintContinuation?.resume(returning: ok)
        fingerprintContinuation = nil
    }

    func cancelConnect() {
        connectTask?.cancel()
        if credentialRequest != nil { submitCredentials(nil) }
        if fingerprintRequest != nil { answerFingerprint(false) }
        connectingHost = nil
        endCancelled()
    }

    /// 取消以后收尾：只撤销搜索 / 连接中的状态。用户可能已经打开了别的来源，那时不能再把界面改回首页。
    func endCancelled() {
        if phase == .searching || phase == .connecting {
            phase = .idle
            status = ""
        }
    }

    func disconnect() {
        endTetherCamera()
        importTask?.cancel()
        connectTask?.cancel()
        watchTask?.cancel()
        reconnectTask?.cancel()
        offline = false
        lastCamera = nil
        lastUSBCamera = nil
        interrupted = nil
        let lib = library
        library = nil
        let extras = extraSources
        extraSources = []
        for t in extraTasks.values { t.cancel() }
        extraTasks = [:]
        Task {
            await lib?.close()
            for e in extras { await e.library?.close() }
        }
        resetContent()
        sourceIdentities.retainOpen([])
        sessionCameraProfiles = [:]
        phase = .idle
        log.add("已断开")
    }

    func forget(_ cam: KnownCamera) {
        KnownCamera.forget(cam.fingerprint)
        knownCameras = KnownCamera.load()
    }

    private func handleLost() {
        guard library != nil else { return }
        // 相机掉线：保留内容和选择，后台自动重连。
        // 不能拿 items 是否为空来区分：空卡、或者列表还没读到时掉线，一样要重连。
        if sourceKind == .camera, lastCamera != nil {
            log.add("和相机的连接断开了，开始自动重连")
            lostDuringImport = progress != nil
            importTask?.cancel()
            library = nil
            offline = true
            startReconnect()
            return
        }
        let wasCard = sourceKind == .card
        // 主来源没了（卡被拔了，或 USB、大疆、富士相机断开），但还有别的来源开着：让下一个顶上来，不回到首页。
        if let i = extraSources.firstIndex(where: { $0.library != nil }) {
            let next = extraSources[i]
            log.add((wasCard ? "存储卡被移除了" : "和相机的连接断开了") + "，改用同时打开的 \(next.isCard ? next.root?.lastPathComponent ?? "" : next.name)")
            importTask?.cancel()
            lastUSBCamera = nil
            extraSources.remove(at: i)
            let keep = selectedKeys(), keepDays = shownDays
            promote(next)
            Task { await loadAll(restoring: keep, days: keepDays) }
            return
        }
        log.add(wasCard ? "存储卡被移除了" : "和相机的连接断开了")
        importTask?.cancel()
        library = nil
        // 没有能顶上来的来源：把还挂着的（正在连、掉线待重连的）一起收掉，和手动断开一样，
        // 免得下次打开来源时被带进来变成多来源。
        let leftovers = extraSources
        extraSources = []
        for t in extraTasks.values { t.cancel() }
        extraTasks = [:]
        Task { for e in leftovers { await e.library?.close() } }
        lastUSBCamera = nil
        sessionCameraProfiles = [:]
        resetContent()
        phase = .idle
        errorMessage = wasCard ? String(localized: "存储卡已被移除。") : String(localized: "与相机的连接已断开（相机可能已关机、离开 Wi-Fi 网络，或已被其他设备连接）。")
    }

    // MARK: 自动重连

    private func startReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            var attempt = 0
            while !Task.isCancelled, offline {
                attempt += 1
                if await reconnectOnce() { return }
                try? await Task.sleep(for: .seconds(attempt < 5 ? 3 : 8))
            }
        }
    }

    /// 「重新连接」按钮：马上再试一次。
    func reconnectNow() {
        guard offline else { return }
        startReconnect()
    }

    private func reconnectOnce() async -> Bool {
        guard let cam = lastCamera else { return false }
        status = String(localized: "正在重新连接 \(cam.host)…")
        guard await probe(host: cam.host)?.fingerprint == cam.fingerprint else { return false }
        do {
            let (lib, remote) = try await openLibrary(cam, interactive: false)
            guard offline else { await lib.close(); return true }
            usesRemoteTransfer = remote
            let keep = selectedKeys()
            let keepDays = shownDays
            deviceInfo = await lib.deviceInfo
            let previousBody = cameraID
            cameraID = deviceInfo?.cameraID
            if cameraID == nil || cameraID != previousBody { primaryConnectionID = UUID(); sessionCameraProfiles[Self.primarySource] = nil }
            attach(lib, name: connectedName ?? cam.host, host: cam.host)
            offline = false
            log.add("已重新连上相机")
            await loadAll(restoring: keep, days: keepDays)
            status = ""
            return true
        } catch {
            log.add("重连失败：\(error.localizedDescription)")
            return false
        }
    }

    /// 选择的「身份」：来源 + 卡槽 + 文件名 + 拍摄时间。重新列目录后句柄会变，用它把选择找回来。
    /// 来源用卷路径或机身 ID 标识（来源 id 在关掉、顶替后会变）。
    func stableKey(_ i: CameraContentItem) -> String { "CONNECTION:\((origins[i.id]?.connectionID ?? connectionID(for: source(of: i.id))).uuidString)|\(i.storageID >> 16)|\(i.filename)|\(i.captureDateRaw)" }

    func sourceIdentity(_ id: Int) -> String {
        // Browsing selection belongs to an open connection; physical identity is
        // stored separately and never inferred from a network address or mount path.
        "CONNECTION:" + connectionID(for: id).uuidString
    }

    func selectedKeys() -> Set<String> {
        Set(grid.selected.compactMap { shots[$0] }.flatMap(\.handles).compactMap { items[$0].map(stableKey) })
    }

    func resetContent() {
        libraryGeneration += 1
        refreshTask?.cancel(); refreshTask = nil; isRefreshingSources = false; refreshMessage = nil
        refreshRequest = UUID()
        metadataTask?.cancel(); metadataTask = nil; metadataRead = []; metadataLoading = false
        closePreview()
        items = [:]; allShots = []; shots = [:]; shotOfFile = [:]; slots = []; days = []
        listedHandles = [:]
        origins = [:]; cardCameraNames = [:]; cardCameraKeys = [:]; fileCameraKeys = [:]; sourceFilter = nil
        grid = GridSelection(); shownDays = []
        sourceIdentities.retainOpen([])
        confirmingCard = nil
        thumbnails = [:]; clipInfos = [:]; proxySizes = [:]; thumbOrder = []; pendingThumbs = []; fileCopies = [:]
        copiesGeneration += 1   // 让还没算完的后台检查作废
        importFilesCache = [:]; importedCache = [:]
        connectedName = nil; connectedHost = nil; cameraID = nil; deviceInfo = nil; cardRoot = nil
        previewShot = nil; previewImage = nil
        progress = nil; lastResult = nil; interrupted = nil; offline = false
    }

    // MARK: 存储卡

    func refreshCards() {
        let vols = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsRemovableKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        cards = vols.filter { $0.path != "/" && LocalCardLibrary.looksLikeCard($0) }
    }

    func volumesChanged(unmounted: URL?) {
        refreshCards()
        volumeVersion += 1
        if let unmounted, let cardRoot, unmounted.standardizedFileURL == cardRoot.standardizedFileURL,
           let lib = library as? LocalCardLibrary {
            lib.markLost()
        } else if let unmounted {
            extraCardLost(unmounted)
        }
    }

    func openCard(_ url: URL) {
        guard phase == .idle else { return }
        connectTask?.cancel()
        errorMessage = nil
        notice = nil
        lastCamera = nil
        let lib = LocalCardLibrary(root: url)
        primaryConnectionID = UUID()
        sourceKind = .card
        usesRemoteTransfer = false
        cameraID = nil
        deviceInfo = nil
        cardRoot = url
        attach(lib, name: url.lastPathComponent, host: nil)
        log.add("打开存储卡 \(url.path)")
        connectTask = Task { await loadAll() }
    }

    /// 同时打开的卡顶上来当主来源。
    func promote(_ e: ExtraSource) {
        guard let lib = e.library else { return }
        primaryConnectionID = e.connectionID
        phase = .loading
        sessionCameraProfiles[Self.primarySource] = sessionCameraProfiles.removeValue(forKey: e.id)
        watchTask?.cancel()
        reconnectTask?.cancel()
        extraTasks.removeValue(forKey: e.id)?.cancel()
        offline = false
        if sourceFilter == e.id { sourceFilter = nil }
        if let root = e.root {
            sourceKind = .card
            usesRemoteTransfer = false
            cameraID = nil
            deviceInfo = nil
            lastCamera = nil
            cardRoot = root
            cardCameraNames[Self.primarySource] = cardCameraNames.removeValue(forKey: e.id)
            cardCameraKeys[Self.primarySource] = cardCameraKeys.removeValue(forKey: e.id)
            attach(lib, name: root.lastPathComponent, host: nil)
            log.add("改用存储卡 \(root.path) 作为主来源")
        } else {
            sourceKind = .camera
            usesRemoteTransfer = e.usesRemoteTransfer
            cameraID = e.cameraID
            deviceInfo = e.deviceInfo
            lastCamera = e.camera
            cardRoot = nil
            attach(lib, name: e.name, host: e.camera?.host)
            log.add("改用相机 \(e.name) 作为主来源")
        }
    }

    // MARK: 同时连接另一台相机

    /// 输入地址，和当前来源同时连接这台相机。
    func addCamera(host: String) {
        let h = host.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, progress == nil else { return }
        Task {
            status = String(localized: "正在检查 \(h)…")
            guard let cam = await probe(host: h) else {
                status = ""
                errorMessage = String(localized: "在 \(h) 上未找到相机（端口 22 和 15740 均无法连接）。请确认相机已开机并开启“遥控拍摄”，且与本机处于同一网络。")
                return
            }
            let name = knownCameras.first { $0.fingerprint == cam.fingerprint }?.name
            await addCamera(FoundCamera(host: cam.host, kind: cam.kind, knownName: name))
        }
    }

    /// 连过的相机：确认它在线（指纹一致）再同时连接。
    func addCamera(known k: KnownCamera) {
        guard progress == nil, switchingTo == nil else { return }
        switchingTo = k.fingerprint
        Task {
            defer { switchingTo = nil }
            guard let cam = await probe(host: k.host), cam.fingerprint == k.fingerprint else {
                errorMessage = String(localized: "“\(k.name)”离线（上次地址为 \(k.host)），未能同时连接。")
                return
            }
            await addCamera(FoundCamera(host: cam.host, kind: cam.kind, knownName: k.name))
        }
    }

    private func addCamera(_ cam: FoundCamera) async {
        // 什么都没开着：就是普通的连接。
        guard library != nil || offline else { await connect(cam); return }
        guard !openFingerprints.contains(cam.fingerprint), !openHosts.contains(cam.host) else { return }
        let id = nextSourceID
        nextSourceID += 1
        extraSources.append(ExtraSource(id: id, camera: cam, name: cam.knownName ?? cam.host, connecting: true))
        log.add("同时连接相机 \(cam.host)（来源 \(id)）")
        do {
            let (lib, remote) = try await openLibrary(cam)
            guard let i = extraIndex(id) else { await lib.close(); return }
            let info = await lib.deviceInfo
            let known = knownCameras.first { $0.fingerprint == cam.fingerprint }
            let keepName = cam.knownName.flatMap { n in (known?.nameIsAddress ?? false) || n == cam.host ? nil : n }
            let modelName = info.map(\.displayName) ?? ""
            let name = keepName ?? (modelName.isEmpty ? (cam.knownName ?? cam.host) : modelName)
            extraSources[i].library = lib
            extraSources[i].deviceInfo = info
            if info?.cameraID == nil || info?.cameraID != extraSources[i].cameraID {
                extraSources[i].connectionID = UUID(); sessionCameraProfiles[id] = nil
            }
            extraSources[i].cameraID = info?.cameraID
            extraSources[i].name = name
            extraSources[i].usesRemoteTransfer = remote
            extraSources[i].connecting = false
            extraSources[i].camera = FoundCamera(host: cam.host, kind: cam.kind, knownName: name)
            KnownCamera.remember(KnownCamera(fingerprint: cam.fingerprint, host: cam.host, name: name, lastSeen: Date(),
                                             model: info?.model ?? known?.model, firmware: info?.version ?? known?.firmware),
                                 front: false)
            knownCameras = KnownCamera.load()
            if let info { log.add("同时连接的相机：\(info.model) 固件 \(info.version)，机身 ID \(info.cameraID ?? "无")") }
            watchExtra(id, lib)
            status = ""
            let keep = selectedKeys(), keepDays = shownDays
            await loadAll(restoring: keep, days: keepDays)
        } catch {
            extraSources.removeAll { $0.id == id }
            status = ""
            if !(error is CancellationError) {
                log.add("同时连接失败：\(error.localizedDescription)")
                errorMessage = String(localized: "未能同时连接“\(cam.knownName ?? cam.host)”：\(error.localizedDescription)")
            }
        }
    }

    private func watchExtra(_ id: Int, _ lib: any CameraLibrary) {
        let lost = lib.connectionLost
        extraTasks[id] = Task { [weak self] in
            for await _ in lost {
                self?.extraCameraLost(id)
                return
            }
        }
    }

    /// 同时连接的相机掉线：保留它的照片和选择，后台自动重连；导入中就停下（可以继续导入）。
    private func extraCameraLost(_ id: Int) {
        guard let i = extraIndex(id), extraSources[i].library != nil else { return }
        log.add("和同时连接的相机「\(extraSources[i].name)」的连接断开了，开始自动重连")
        extraSources[i].library = nil
        extraSources[i].offline = true
        if progress != nil { lostDuringImport = true; importTask?.cancel() }
        guard let cam = extraSources[i].camera else { return }
        extraTasks[id] = Task {
            var attempt = 0
            while !Task.isCancelled, extra(id)?.offline == true {
                attempt += 1
                if await probe(host: cam.host)?.fingerprint == cam.fingerprint,
                   let (lib, remote) = try? await openLibrary(cam, interactive: false) {
                    guard let j = extraIndex(id), extraSources[j].offline else { await lib.close(); return }
                    extraSources[j].library = lib
                    extraSources[j].offline = false
                    extraSources[j].usesRemoteTransfer = remote
                    extraSources[j].deviceInfo = await lib.deviceInfo ?? extraSources[j].deviceInfo
                    log.add("已重新连上同时连接的相机「\(extraSources[j].name)」")
                    watchExtra(id, lib)
                    let keep = selectedKeys(), keepDays = shownDays
                    await loadAll(restoring: keep, days: keepDays)
                    return
                }
                try? await Task.sleep(for: .seconds(attempt < 5 ? 3 : 8))
            }
        }
    }

    func ejectCard() {
        guard let root = cardRoot else { return }
        disconnect()
        // 联机缓存不是真的存储卡，断开就好。
        if isTetherSpool(root) { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: root)
            notice = String(localized: "已推出 \(root.lastPathComponent)，可安全取出存储卡")
        } catch {
            errorMessage = String(localized: "推出存储卡失败：\(error.localizedDescription)")
        }
    }
}
