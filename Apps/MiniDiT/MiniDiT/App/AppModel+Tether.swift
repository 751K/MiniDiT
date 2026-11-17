import Foundation
import SonyRemoteKit

/// 联机拍摄（索尼，Wi-Fi「电脑遥控」）：连上相机后，主来源换成这次的联机缓存；
/// 每拍一张，照片先下到缓存，再按平常的导入流程进当前项目（命名、备份、Capture One / Lightroom 照旧）。
extension AppModel {
    var isTethering: Bool { tether != nil }

    /// 侧栏里的这个来源是联机缓存（不是真的存储卡）。
    func isTetherSource(_ id: Int) -> Bool {
        id == Self.primarySource && cardRoot.map(isTetherSpool) == true
    }

    func isTetherSpool(_ url: URL) -> Bool {
        url.standardizedFileURL.path.hasPrefix(TetherSpool.base.standardizedFileURL.path + "/")
    }

    /// 浏览页 / 菜单的「联机拍摄」：当前连着的索尼相机（Wi-Fi 或 USB）。
    var canStartTether: Bool { !isTethering && (tetherCandidate != nil || usbTetherCandidate != nil) }

    func startTetherFromCurrent() {
        if let c = tetherCandidate { startTether(c) } else if let u = usbTetherCandidate { startTether(usb: u) }
    }

    /// 当前主来源是 USB 连着的索尼相机。
    var usbTetherCandidate: USBCamera? {
        guard sourceKind == .camera, !isTethering, let u = lastUSBCamera, usbCameras.contains(u) else { return nil }
        let model = deviceInfo?.model ?? u.name
        return USBCameraOpener.isSony(name: model, manufacturer: deviceInfo?.manufacturer) ? u : nil
    }

    /// 可以联机拍摄的相机：当前连着的索尼 Wi-Fi 相机（不含大疆、尼康）。
    var tetherCandidate: FoundCamera? {
        guard sourceKind == .camera, let cam = lastCamera, !isTethering else { return nil }
        let model = deviceInfo?.model ?? knownCameras.first { $0.fingerprint == cam.fingerprint }?.model ?? ""
        if !model.isEmpty, !["ILCE", "ILME", "ILCA", "ZV-", "DSC-"].contains(where: { model.hasPrefix($0) }) { return nil }
        return cam
    }

    func startTether(_ cam: FoundCamera) {
        guard progress == nil else {
            errorMessage = "请等待当前导入完成后再开始联机拍摄。"
            return
        }
        let wasOpen = library != nil || !extraSources.isEmpty
        if wasOpen || phase != .idle { disconnect() }
        connectTask?.cancel()
        lastTetherCamera = cam
        connectTask = Task { await startTetherAsync(cam, settle: wasOpen) }
    }

    /// 按地址开始联机（CLI / MCP 用）：先确认地址上有相机、是直连还是要访问身份验证。
    func startTether(host: String) {
        guard progress == nil else {
            errorMessage = "请等待当前导入完成后再开始联机拍摄。"
            return
        }
        let wasOpen = library != nil || !extraSources.isEmpty
        if wasOpen || phase != .idle { disconnect() }
        connectTask?.cancel()
        lastTetherCamera = FoundCamera(host: host, kind: .direct)
        connectTask = Task {
            phase = .connecting
            connectingHost = host
            status = "正在检查 \(host)…"
            guard let cam = await probe(host: host) else {
                connectingHost = nil
                if Task.isCancelled { endCancelled(); return }
                phase = .idle
                status = ""
                errorMessage = "在 \(host) 上未找到相机。请确认相机已开机、开启“电脑遥控”，且与本机处于同一网络。"
                return
            }
            let name = knownCameras.first { $0.fingerprint == cam.fingerprint }?.name
            let target = FoundCamera(host: cam.host, kind: cam.kind, knownName: name)
            lastTetherCamera = target
            await startTetherAsync(target, settle: wasOpen)
        }
    }

    private func startTetherAsync(_ cam: FoundCamera, settle: Bool) async {
        await beginTether(label: cam.host, knownName: cam.knownName, settle: settle) { step in
            let tunnel = try await self.prepareTunnel(cam)
            return try await SonyCamera.connect(host: cam.host, identity: HostIdentityStore.identity,
                                                tunnel: tunnel, progress: step)
        }
    }

    /// 连上相机（Wi-Fi 或 USB，由 connect 决定）并开始联机：主来源换成联机缓存，新照片自动导入。
    func beginTether(label: String, knownName: String?, settle: Bool,
                     connect: (@escaping @Sendable (String) -> Void) async throws -> SonyCamera) async {
        phase = .connecting
        connectingHost = label
        defer { connectingHost = nil }
        errorMessage = nil
        notice = nil
        log.add("联机拍摄：连接 \(label)")
        let step: @Sendable (String) -> Void = { s in Task { @MainActor in self.status = s; self.log.add(s) } }
        var camera: SonyCamera?
        do {
            // 刚断开导入用的连接：相机要过一会儿才放开会话。
            if settle { try await Task.sleep(for: .milliseconds(1500)) }
            let c = try await connect(step)
            camera = c
            try Task.checkCancellation()
            let cameraName = await c.displayName
            let name = knownName ?? cameraName
            let spool = try TetherSpool.create(camera: name)
            let session = TetherSession(camera: c, name: name, spool: spool) { [weak self] s in self?.log.add(s) }
            primaryConnectionID = UUID()
            sessionCameraProfiles[Self.primarySource] = nil
            usesRemoteTransfer = false
            sourceKind = .card
            cameraID = nil
            deviceInfo = nil
            lastCamera = nil
            cardRoot = spool.root
            tetherAttempted = []
            tetherNeedsReload = false
            attach(LocalCardLibrary(root: spool.root), name: "联机拍摄 · \(name)", host: nil)
            tether = session
            session.onFiles = { [weak self] _ in self?.tetherNeedsReload = true }
            session.start()
            startTetherImports()
            tetherWindowRequest += 1
            log.add("联机拍摄：已连接 \(name)，缓存 \(spool.root.path)")
            await loadAll()
        } catch is CancellationError {
            await camera?.disconnect()
            log.add("已取消联机拍摄")
            endCancelled()
            return
        } catch {
            await camera?.disconnect()
            log.add("联机拍摄连接失败：\(error.localizedDescription) ｜ \(String(reflecting: error))")
            errorMessage = "无法开始联机拍摄（\(error.localizedDescription)）。请确认相机已开启“电脑遥控”（USB 连接时把 USB 连接方式设为“PC 遥控”），且没有被其他设备连接。"
            phase = .idle
        }
        status = ""
    }

    /// 结束联机：断开相机；缓存里的照片仍作为来源留在浏览页，可以继续挑选、导入。
    func stopTether() {
        guard tether != nil else { return }
        endTetherCamera()
        if let name = connectedName { connectedName = name.replacingOccurrences(of: "联机拍摄 · ", with: "联机缓存 · ") }
    }

    /// 只停相机这一头（disconnect() 里也调用）。
    func endTetherCamera() {
        tetherTask?.cancel()
        tetherTask = nil
        guard let t = tether else { return }
        tether = nil
        log.add("联机拍摄：结束，本次 \(t.shotCount) 张")
        Task { await t.stop() }
    }

    /// 新照片到了：等没有导入、没有刷新时重新读缓存，然后自动导入还没导过的。
    private func startTetherImports() {
        tetherTask?.cancel()
        tetherTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, self.tether != nil else { return }
                self.tetherTick()
            }
        }
    }

    func tetherTick() {
        guard progress == nil, phase == .ready, !isRefreshingSources, importJournal.repairTask == nil else { return }
        if tetherNeedsReload {
            refreshSources(automatically: true)
            // 预览打开、正在框选等情况下刷新会推迟：下一轮再试。
            if isRefreshingSources { tetherNeedsReload = false }
            return
        }
        importTetherShots()
    }

    /// 把还没导入、也没自动导入过的照片导进当前项目。没选项目时先留在缓存里，选好项目再导。
    func importTetherShots() {
        guard tetherAutoImport, currentSession != nil, progress == nil, phase == .ready,
              newSessionPrompt == nil, !backupMissingPrompt, spaceProblem == nil, lightroomPrompt == nil else { return }
        let fresh = allShots.filter { s in
            !isImported(shot: s.id) && s.handles.contains { items[$0].map { !tetherAttempted.contains($0.filename) } ?? false }
        }
        guard !fresh.isEmpty else { return }
        for s in fresh { for h in s.handles { if let f = items[h]?.filename { tetherAttempted.insert(f) } } }
        log.add("联机拍摄：自动导入 \(fresh.count) 张到「\(currentSession?.name ?? "")」")
        grid.replace(with: Set(fresh.map(\.id)))
        beginImport()
    }
}
