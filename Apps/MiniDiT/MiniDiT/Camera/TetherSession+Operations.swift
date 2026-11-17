import AppKit
import Foundation
import ImageIO
import MiniDiTCore
import SonyRemoteKit

/// 联机窗口和 CLI / MCP 共用的操作：切换拍照 / 录像、远程取白、改任意属性、本次拍摄的照片列表。
/// 出错时抛 AgentControlError（错误码 + 中文说明），界面直接显示说明，agent 原样返回。
extension TetherSession {
    /// 自定义白平衡失败时，错误信息后面接上操作过程（JSON）；界面只显示分隔符前面的部分。
    static var traceSeparator: String { String(localized: " 过程：") }

    // MARK: 改属性（界面用）

    /// 改一个属性并回读确认；失败时显示在窗口里。
    func setProperty(_ code: UInt16, _ value: Int64) {
        guard !lost else { return }
        Task {
            do { _ = try await setVerified(code, .int(value), timeout: 5) }
            catch { message = AppModel.cameraError(error).message }
        }
    }

    // MARK: 调焦（对焦位置、记忆点、拉焦）

    /// 调焦用的属性组（相机不支持或当前不可用时为 nil）。
    var focusControl: SonyCamera.FocusPositionControl? { SonyCamera.focusPositionControl(properties) }
    /// 镜头现在的位置（相机回报）。
    var focusCurrent: Int64? { focusControl.flatMap { properties[$0.currentCode]?.intValue } }
    /// 界面显示的位置：拖动 / 拉焦时用目标值，否则用相机回报。
    var focusShown: Int64? { focusTarget ?? focusCurrent }
    /// 对焦模式是否手动（MF / DMF）：AF 时相机会自己再对焦，调焦不一定保持。
    var isManualFocus: Bool { [1, 0x8006].contains(properties[SonyProperty.focusMode]?.intValue ?? -1) }

    /// 移到 v。拖动时连续调用：同一时间只发一个，最新的值覆盖还没发的。
    func moveFocus(to v: Int64, cancelPull: Bool = true) {
        guard !lost, let c = focusControl else { return }
        if cancelPull { pullTask?.cancel(); pullTask = nil }
        let v = min(max(v, c.range.lowerBound), c.range.upperBound)
        focusTarget = v
        focusPending = v
        guard !focusSending else { return }
        focusSending = true
        Task {
            defer { focusSending = false }
            while let next = focusPending {
                focusPending = nil
                do { try await sendFocusPosition(next) }
                catch { message = AppModel.cameraError(error).message; focusTarget = nil; return }
            }
            settleFocusTarget()
        }
    }

    /// 发完后等相机回报跟上再清掉目标值（最多 1.5 秒），免得滑块先跳回旧位置。
    private func settleFocusTarget() {
        focusGeneration += 1
        let gen = focusGeneration
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            await refresh()
            try? await Task.sleep(for: .milliseconds(1100))
            if gen == focusGeneration, pullTask == nil { focusTarget = nil }
        }
    }

    /// 平滑拉到 v：seconds 秒内分步走（缓入缓出，每秒约 12 步）；0 秒直接跳过去。
    func pullFocus(to v: Int64, seconds: Double) {
        guard !lost, let from = focusShown else { return }
        pullTask?.cancel()
        guard seconds > 0 else { moveFocus(to: v); return }
        let steps = max(2, Int(seconds * 12))
        pullTask = Task { [weak self] in
            let start = Date()
            for i in 1...steps {
                guard !Task.isCancelled, let self else { return }
                let t = Double(i) / Double(steps)
                let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                self.moveFocus(to: from + Int64((Double(v - from) * eased).rounded()), cancelPull: false)
                let due = start.addingTimeInterval(seconds * t)
                let wait = due.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            self?.pullTask = nil
        }
    }

    /// 现在的对焦距离（录像模式用跟焦且相机给了换算表时才有）。
    var focusDistanceText: String? {
        guard let c = focusControl, let t = distanceTable else { return nil }
        // 录像模式按跟焦刻度（拖动时用目标值）；拍照模式调的是绝对位置，刻度不同，
        // 但相机仍报告跟焦的当前位置 0xE089，用它查表（跟着镜头走，拖动时略有滞后）。
        let v = c.setCode == 0xE088 ? focusShown : properties[0xE089]?.intValue
        guard let v, let m = t.meters(at: v) else { return nil }
        return LensDistanceTable.text(m)
    }

    private var lensName: String? {
        if case let .string(s)? = properties[0xD07B]?.current, !s.isEmpty { return s }
        return nil
    }

    private static func distanceTableKey(_ lens: String) -> String { "lensDistanceTable." + lens }

    /// 换算表只在录像模式、0xE086 = 1 时可读：条件满足且还没读过就读一次，读到后按镜头型号存下来。
    /// 拍照模式读不到，用这支镜头上次在录像模式读到的表（没读过就不显示距离）。换镜头、换模式后重读。
    func updateDistanceTable() {
        let lens = lensName
        let usable = properties[0xE086]?.intValue == 1 && focusControl?.setCode == 0xE088
        guard usable else {
            distanceTableState = 0
            let cached = lens.flatMap { UserDefaults.standard.data(forKey: Self.distanceTableKey($0)) }.flatMap(LensDistanceTable.parse)
            if distanceTable != cached { distanceTable = cached }
            return
        }
        guard distanceTableState == 0 else { return }
        distanceTableState = 1
        Task {
            let data = try? await lensInformationRaw(type: 2)
            let table = data.flatMap(LensDistanceTable.parse)
            if let data, table != nil, let lens { UserDefaults.standard.set(data, forKey: Self.distanceTableKey(lens)) }
            distanceTable = table
            distanceTableState = 2
        }
    }

    // MARK: 放大对焦

    /// 放大对焦现在的状态（不可改时为 nil）。
    var magnifier: SonyCamera.FocusMagnifier? { SonyCamera.focusMagnifier(properties) }

    static func ratioText(_ r: Int64) -> String { r % 10 == 0 ? "×\(r / 10)" : String(format: "×%.1f", Double(r) / 10) }

    /// 打开（ratio > 0）或关闭放大。打开时以刚点过的位置为中心，没点过就用相机当前的位置。
    func setMagnifier(_ ratio: Int64) {
        guard !lost else { return }
        let c = touchPoint.map(Self.touchCoordinates)
        sendMagnifier(ratio, c?.x, c?.y)
    }

    /// 放大时点按取景画面：把点到的地方移到中间（画面上的偏移按倍率换算回整幅画面的 640×480 坐标）。
    func panMagnifier(_ p: CGPoint) {
        guard let m = magnifier, m.isOn else { return }
        let zoom = max(Double(m.ratio) / 10, 1)
        let x = Double(m.x) + (p.x - 0.5) * 640 / zoom, y = Double(m.y) + (p.y - 0.5) * 480 / zoom
        sendMagnifier(m.ratio, Int(x.rounded()), Int(y.rounded()))
    }

    private func sendMagnifier(_ ratio: Int64, _ x: Int?, _ y: Int?) {
        Task {
            do { try await sendFocusMagnifier(ratio: ratio, x: x, y: y); await refresh() }
            catch { message = AppModel.cameraError(error).message }
        }
    }

    /// 取景画面是不是 S-Log3：Log 拍摄打开且监看 LUT 关闭（实测 LUT 打开时传到电脑的取景已套 LUT），
    /// 或者图片配置文件的伽马是 S-Log3。
    var liveViewIsLog: Bool {
        let p = properties
        if let log = p[0xE000], log.isEnabled != 0, log.intValue == 0x501 {
            return p[0xD04D]?.intValue == 1
        }
        if let pp = p[0xD23F]?.intValue, pp != 0, p[0xD0E1]?.intValue == 0x303 { return true }
        return false
    }

    func markFocus(_ name: String) { if let v = focusShown { focusMarks[name] = v } }
    func clearFocusMark(_ name: String) { focusMarks[name] = nil }

    /// 某个调焦位置对应的距离（只在录像模式用跟焦刻度时能换算；拍照模式的绝对位置刻度不同）。
    func focusDistanceText(at v: Int64) -> String? {
        guard focusControl?.setCode == 0xE088, let m = distanceTable?.meters(at: v) else { return nil }
        return LensDistanceTable.text(m)
    }

    /// 切回自动对焦：优先 AF-C，其次 AF-S、AF-A。
    func switchToAutoFocus() {
        guard let d = properties[SonyProperty.focusMode] else { return }
        if let v = [Int64(0x8004), 2, 0x8005].first(where: d.allowedValues.contains) { setProperty(SonyProperty.focusMode, v) }
    }

    /// 切到手动对焦（调焦前用）。
    func switchToManualFocus() {
        guard let d = properties[SonyProperty.focusMode], d.allowedValues.contains(1) else { return }
        setProperty(SonyProperty.focusMode, 1)
    }

    // MARK: 点按对焦（远程触摸）

    /// 取景画面上的位置（0…1）换成相机的 640×480 坐标：相机把整幅取景画面映射到这个范围。
    static func touchCoordinates(_ p: CGPoint) -> (x: Int, y: Int) {
        (Int((min(max(p.x, 0), 1) * 639).rounded()), Int((min(max(p.y, 0), 1) * 479).rounded()))
    }

    /// 点按取景画面：相机按机身的触摸功能对焦或开始跟踪。相机报告不可用（0xD284 = 0）时直接说明原因。
    func touchFocus(at p: CGPoint) async throws -> (x: Int, y: Int) {
        guard !lost else { throw AgentControlError("not_connected", String(localized: "相机已断开。")) }
        if properties[0xD284]?.intValue == 0 {
            throw AgentControlError("touch_unavailable", String(localized: "相机现在不接受远程触摸：请检查机身的「触摸操作」是否打开，以及对焦模式和对焦区域。"))
        }
        let c = Self.touchCoordinates(p)
        do { try await remoteTouch(x: c.x, y: c.y) } catch { throw AppModel.cameraError(error) }
        touchPoint = p
        await refresh()
        return c
    }

    /// 取消触摸对焦 / 跟踪。
    func cancelTouchFocus() async throws {
        guard !lost else { throw AgentControlError("not_connected", String(localized: "相机已断开。")) }
        do { try await cancelRemoteTouch() } catch { throw AppModel.cameraError(error) }
        touchPoint = nil
        await refresh()
    }

    /// 界面用：出错时显示在取景上。相机不接受远程触摸（例如 MF）但能放大时，改为在点到的地方放大。
    func touch(_ p: CGPoint) {
        if properties[0xD284]?.intValue == 0, let m = magnifier {
            let c = Self.touchCoordinates(p)
            sendMagnifier(m.isOn ? m.ratio : (m.ratios.first { $0 > 10 } ?? 55), c.x, c.y)
            return
        }
        Task { do { _ = try await touchFocus(at: p) } catch { message = AppModel.cameraError(error).message } }
    }

    /// 现在能否取消触摸：相机报告可取消（0xD285 = 1，在机身上点的也算），或刚在窗口里点过。
    var canCancelTouch: Bool { !lost && (properties[0xD285]?.intValue == 1 || touchPoint != nil) }

    func cancelTouch() {
        guard canCancelTouch else { return }
        Task { do { try await cancelTouchFocus() } catch { message = AppModel.cameraError(error).message } }
    }

    // MARK: 拍照 / 录像 / S&Q

    struct ModeSwitch { let from: Int64; let to: Int64; let priorityChanged: Bool }

    /// 当前是拍照、录像还是 S&Q（相机没报告或不认识时为 nil）。
    var shootingMode: SonyPropertyCatalog.ShootingMode? {
        properties[SonyProperty.exposureProgramMode]?.intValue.flatMap(SonyPropertyCatalog.shootingMode)?.mode
    }

    /// 曝光模式改到另一组。exposure 为 nil 时沿用当前的 P/A/S/M/auto。
    /// 曝光模式「仅显示」时说明由相机拨盘控制：先把 PriorityKey 改成 PC（记为改过，结束联机时改回）。
    func switchMode(to target: SonyPropertyCatalog.ShootingMode, exposure: String? = nil, timeout: TimeInterval = 8) async throws -> ModeSwitch {
        let code = SonyProperty.exposureProgramMode
        let all = try await freshProperties()
        guard let d = all[code], let current = d.intValue else { throw AgentControlError("unknown_property", String(localized: "相机没有报告曝光模式。")) }
        guard let letter = exposure?.lowercased() ?? SonyPropertyCatalog.shootingMode(current)?.exposure else {
            throw AgentControlError("invalid_params", String(localized: "当前曝光模式（\(SonyFormat.exposureProgram(current))）无法对应，请指定 auto、p、a、s 或 m。"))
        }
        guard let value = SonyPropertyCatalog.exposureProgram(target, exposure: letter, allowed: d.allowedValues) else {
            throw AgentControlError("invalid_value", String(localized: "相机不支持\(Self.modeTitle(target))的 \(letter.uppercased()) 模式。"))
        }
        busy = String(localized: "正在切换到\(Self.modeTitle(target))…")
        defer { busy = nil }
        var priorityChanged = false
        if d.getSet == 1, d.isEnabled == 2, value != current {
            guard let pk = all[SonyProperty.priorityMode], pk.isWritable, pk.intValue == 0 else {
                throw AgentControlError("not_writable", String(localized: "曝光模式由相机拨盘控制，且无法把 PriorityKey 改成 PC 优先。"))
            }
            do { _ = try await setVerified(SonyProperty.priorityMode, .int(1), timeout: 5) } catch { throw AppModel.cameraError(error) }
            priorityChanged = true
        }
        let result: SonyPropertyDesc
        do { result = try await setVerified(code, .int(value), timeout: timeout) } catch { throw AppModel.cameraError(error) }
        logLine("联机拍摄：切换到\(Self.modeTitle(target))（\(SonyFormat.exposureProgram(value))）")
        return ModeSwitch(from: current, to: result.intValue ?? value, priorityChanged: priorityChanged)
    }

    static func modeTitle(_ m: SonyPropertyCatalog.ShootingMode) -> String {
        switch m { case .photo: String(localized: "拍照"); case .movie: String(localized: "录像"); case .sq: "S&Q"; case .interval: String(localized: "间隔录像") }
    }

    // MARK: 远程取白

    struct CustomWBResult {
        let slot: Int
        let position: Int64
        let sawCapturing: Bool
        /// 取白结束时的全部属性（色温、G–M、A–B、白平衡模式从这里读）。
        let properties: [UInt16: SonyPropertyDesc]
        let trace: [AgentJSON]
    }

    struct CustomWBProbe { let stateAfterCancel: Int64; let area: SonyPropertyDesc?; let frame: SonyPropertyDesc?; let trace: [AgentJSON] }

    /// 白平衡切到自定义 slot → 取白待机 → 在 position（x << 16 | y，640×480 坐标，默认中央）取白 → 等执行状态离开「取白中」→ 退出待机。
    /// probe 时只进入待机再取消。每一步的状态记在 trace 里；出错或超时会尝试取消待机，错误消息附 trace。
    func customWhiteBalance(slot: Int, position: Int64? = nil, probe: Bool = false,
                            timeout: TimeInterval = 15) async throws -> (result: CustomWBResult?, probe: CustomWBProbe?) {
        busy = probe ? String(localized: "正在检查取白…") : String(localized: "正在取白：请让相机对准灰卡…")
        defer { busy = nil }
        var trace: [AgentJSON] = []
        var last: [String: AgentJSON] = [:]
        let started = Date()
        func snapshot(_ note: String) async throws -> [UInt16: SonyPropertyDesc] {
            let all = try await freshProperties()
            var o: [String: AgentJSON] = [:]
            for c in SonyCamera.customWBStatusCodes + [0x5005, 0xD20F, 0xD210, 0xD21C] {
                guard let d = all[c] else { continue }
                o[String(format: "0x%04X", c)] = AppModel.valueJSON(c, d.current)
            }
            if o != last || note != "poll" {
                last = o
                var e = o
                e["t"] = .number((Date().timeIntervalSince(started) * 10).rounded() / 10)
                e["step"] = .string(note)
                trace.append(.object(e))
            }
            return all
        }
        func state(_ all: [UInt16: SonyPropertyDesc]) -> Int64 { all[0xD270]?.intValue ?? -1 }
        func fail(_ code: String, _ text: String) async -> AgentControlError {
            try? await customWBButton(.cancel)
            _ = try? await snapshot("cancel")
            let data = (try? AgentJSON.array(trace).data()).map { String(decoding: $0, as: UTF8.self) } ?? ""
            return AgentControlError(code, text + TetherSession.traceSeparator + data)
        }

        var all = try await snapshot("start")
        guard all[0xD270] != nil else { throw AgentControlError("unsupported", String(localized: "相机没有报告取白状态（0xD270），不支持远程取白。")) }
        let wb: Int64 = 0x8020 + Int64(slot - 1)
        guard all[0x5005]?.allowedValues.contains(wb) == true else { throw AgentControlError("invalid_value", String(localized: "相机没有自定义 \(slot)。")) }
        do { _ = try await setVerified(0x5005, .int(wb), timeout: 5) } catch { throw AppModel.cameraError(error) }
        let deadline = Date().addingTimeInterval(timeout)
        all = try await snapshot("wb")
        while all[0xD26D]?.intValue != 1 {
            guard Date() < deadline else { throw await fail("custom_wb_unavailable", String(localized: "相机没有允许进入取白待机（检查拍摄模式和菜单状态）。")) }
            try await Task.sleep(for: .milliseconds(200))
            all = try await snapshot("poll")
        }
        do { try await customWBButton(.standby) } catch { throw await fail("camera_error", String(localized: "进入取白待机失败：\(AppModel.cameraError(error).message)")) }
        all = try await snapshot("standby")
        while !(state(all) == 1 && all[0xD26F]?.intValue == 1) {
            guard Date() < deadline else { throw await fail("custom_wb_timeout", String(localized: "相机没有进入取白待机。")) }
            try await Task.sleep(for: .milliseconds(200))
            all = try await snapshot("poll")
        }
        if probe {
            let area = all[0xD26B], frame = all[0xD26C]
            try? await customWBButton(.cancel)
            try await Task.sleep(for: .milliseconds(500))
            all = try await snapshot("cancel")
            return (nil, CustomWBProbe(stateAfterCancel: state(all), area: area, frame: frame, trace: trace))
        }
        // α7 V 上可取白区域 0xD26B、0xD26C 待机时也是 0：默认取画面中央 (320, 240)，实测可用。
        let pos = position ?? Int64(320 << 16 | 240)
        do { try await customWBCapture(.int(pos), type: .uint32) }
        catch { throw await fail("camera_error", String(localized: "取白命令被拒绝：\(AppModel.cameraError(error).message)")) }
        all = try await snapshot("capture")
        var sawCapturing = state(all) == 2
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
            all = try await snapshot("poll")
            if state(all) == 2 { sawCapturing = true; continue }
            if sawCapturing || Date().timeIntervalSince(started) > 3 { break }
        }
        guard state(all) != 2 else { throw await fail("custom_wb_timeout", String(localized: "取白没有在 \(Int(timeout)) 秒内完成。")) }
        if state(all) == 1 { try? await customWBButton(.cancel) }
        try await Task.sleep(for: .milliseconds(500))
        all = try await snapshot("done")
        logLine("联机拍摄：取白存入自定义 \(slot)，\(all[0xD20F].flatMap { SonyPropertyCatalog.label(0xD20F, $0.intValue ?? 0) } ?? "—")")
        return (CustomWBResult(slot: slot, position: pos, sawCapturing: sawCapturing, properties: all, trace: trace), nil)
    }

    /// 现读全部属性（同时更新缓存）。
    func freshProperties() async throws -> [UInt16: SonyPropertyDesc] {
        let all: [SonyPropertyDesc]
        do { all = try await properties() } catch { throw AppModel.cameraError(error) }
        let map = Dictionary(all.map { ($0.code, $0) }, uniquingKeysWith: { _, b in b })
        properties = map
        return map
    }

    // MARK: 本次拍摄

    /// 缓存里的照片按文件名主干分组（DSC06887.ARW + DSC06887.HIF 是一张），新的在前。
    static func groupShots(_ files: [URL]) -> [TetherShot] {
        var groups: [String: [URL]] = [:]
        var order: [String] = []
        for f in files {
            let stem = f.deletingPathExtension().lastPathComponent
            if groups[stem] == nil { order.append(stem) }
            groups[stem, default: []].append(f)
        }
        return order.reversed().map { stem in
            let files = groups[stem]!.sorted { $0.lastPathComponent < $1.lastPathComponent }
            // 显示用 JPG / HIF（解码快、颜色是机内效果），只有 RAW 时用 RAW 内嵌的预览。
            let display = files.first { ["JPG", "JPEG", "HIF", "HEIF"].contains($0.pathExtension.uppercased()) } ?? files[0]
            return TetherShot(id: stem, files: files, display: display)
        }
    }

    /// 缩略图（后台解码，解好后更新界面）。
    func thumbnail(for shot: TetherShot) -> NSImage? {
        if let img = thumbnails[shot.id] { return img }
        guard !thumbnailLoading.contains(shot.id) else { return nil }
        thumbnailLoading.insert(shot.id)
        let url = shot.display, id = shot.id
        Task.detached(priority: .utility) {
            let cg = TetherSession.previewCGImage(url, maxPixel: 240)
            await MainActor.run { [weak self] in
                self?.thumbnailLoading.remove(id)
                if let cg { self?.thumbnails[id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
            }
        }
        return nil
    }

    /// 回看某一张：大图在侧栏显示。
    func review(_ shot: TetherShot) {
        reviewedShotID = shot.id
        reviewImage = nil
        reviewExif = ShotExif(url: shot.display)
        let url = shot.display, id = shot.id
        Task.detached(priority: .userInitiated) {
            let cg = TetherSession.previewCGImage(url, maxPixel: 1600)
            await MainActor.run { [weak self] in
                guard let self, self.reviewedShotID == id else { return }
                self.reviewImage = cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
            }
        }
    }
}

/// 本次联机拍到的一张（可能是 RAW + HIF 两个文件）。
struct TetherShot: Identifiable, Equatable {
    let id: String
    let files: [URL]
    let display: URL
    var formats: String { files.map { $0.pathExtension.uppercased() }.joined(separator: " + ") }
}
