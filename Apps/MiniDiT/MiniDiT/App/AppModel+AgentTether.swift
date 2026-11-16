import AppKit
import Foundation
import ImageIO
import MiniDiTCore
import SonyRemoteKit
import UniformTypeIdentifiers

/// CLI / MCP 的联机拍摄操作（tether.*）。拍摄、调参数都是异步的：返回表示已接受，结果用 tether.status 查询。
extension AppModel {
    func agentTether(_ method: String, _ p: AgentJSON) throws -> AgentJSON {
        switch method {
        case "tether.status":
            return tetherStatusJSON()
        case "tether.start":
            guard tether == nil else { throw AgentControlError("already_tethering", "已经在联机拍摄。") }
            try agentIdle()
            guard phase == .idle || phase == .ready else { throw AgentControlError("busy", "设备正在连接或读取。") }
            guard interrupted == nil else { throw AgentControlError("pending_import", "请先继续或取消待续传任务。") }
            if let host = p["host"].string {
                guard !host.contains(where: { $0.isWhitespace || $0 == "/" || $0 == "@" }), host.utf8.count <= 253 else {
                    throw AgentControlError("invalid_params", "请输入不含凭据的主机名或 IP。")
                }
                if let cam = tetherCandidate, cam.host == host { startTether(cam) } else { startTether(host: host) }
            } else {
                guard let cam = tetherCandidate else {
                    throw AgentControlError("no_camera", "当前没有连接索尼 Wi-Fi 相机；请传入 host。")
                }
                startTether(cam)
            }
            return tetherStatusJSON()
        case "tether.configure":
            if let on = p["liveView"].bool {
                guard let t = tether else { throw AgentControlError("not_tethering", "没有正在联机拍摄的相机。") }
                t.liveViewOn = on
            }
            if let on = p["autoImport"].bool { tetherAutoImport = on }
            return tetherStatusJSON()
        default:
            break
        }
        guard let t = tether else { throw AgentControlError("not_tethering", "没有正在联机拍摄的相机，请先调用 tether.start。") }
        guard !t.lost else { throw AgentControlError("camera_lost", "与相机的连接已断开。") }
        switch method {
        case "tether.shoot":
            guard !t.shooting else { throw AgentControlError("busy", "上一张还在拍摄。") }
            let before = t.shotCount
            t.shoot()
            return .object(["accepted": .bool(true), "shotCountBefore": .integer(before)])
        case "tether.focus":
            t.setFocusLock(p["locked"].bool!)
            return .object(["accepted": .bool(true)])
        case "tether.record":
            let on = p["on"].bool!
            if on != t.status.isRecording { t.toggleRecording() }
            return .object(["accepted": .bool(true), "wasRecording": .bool(t.status.isRecording)])
        case "tether.set":
            let kind = CameraSettingKind(rawValue: p["setting"].string!)!
            let given = [p["value"], p["label"], p["step"]].filter { $0 != .null }
            guard given.count == 1 else { throw AgentControlError("invalid_params", "value、label、step 需要且只能给一个。") }
            guard let s = t.status.settings.first(where: { $0.kind == kind }) else {
                throw AgentControlError("setting_unavailable", "相机没有报告\(kind.title)。")
            }
            guard s.isEditable else { throw AgentControlError("setting_unavailable", "当前拍摄模式下\(kind.title)由相机决定。") }
            if let step = p["step"].int {
                guard step != 0 else { throw AgentControlError("invalid_params", "step 不能为 0。") }
                t.step(kind, by: step)
                return .object(["accepted": .bool(true), "from": .string(s.valueText)])
            }
            let option: SettingOption?
            if let label = p["label"].string {
                let want = label.trimmingCharacters(in: .whitespaces).lowercased()
                option = s.options.first { $0.label.lowercased() == want }
            } else {
                let v = Int64(p["value"].int!)
                option = s.options.first { $0.value == v }
            }
            guard let option else {
                throw AgentControlError("invalid_value", "\(kind.title)没有这个选项。可选：" + s.options.map(\.label).joined(separator: "、"))
            }
            t.set(kind, value: option.value)
            return .object(["accepted": .bool(true), "from": .string(s.valueText), "to": .string(option.label)])
        case "tether.live_view":
            guard t.liveViewOn else { throw AgentControlError("live_view_off", "实时取景已关闭，可用 tether.configure 打开。") }
            if let out = p["outFile"].string {
                // 存原始帧（相机送来的 JPEG，不缩小、不重新编码）。
                guard let data = t.liveFrameData else { throw AgentControlError("no_frame", "还没有取景画面，请稍后重试。") }
                let url = try Self.saveLiveFrame(data, to: out)
                let size = Self.imageSize(data)
                return .object(["path": .string(url.path), "bytes": .integer(data.count), "mimeType": .string("image/jpeg"),
                                "focalFrames": Self.focalFramesJSON(t.focalFrames),
                                "width": .integer(size.width), "height": .integer(size.height),
                                "savedAt": .string(ISO8601DateFormatter().string(from: .now))])
            }
            guard let data = t.liveFrameData,
                  let jpeg = Self.agentJPEG(data, maxWidth: p["maxWidth"].int ?? 1024) else {
                throw AgentControlError("no_frame", "还没有取景画面，请稍后重试。")
            }
            return .object(["mimeType": .string("image/jpeg"), "width": .integer(jpeg.width), "height": .integer(jpeg.height),
                            "data": .string(jpeg.data.base64EncodedString()), "focalFrames": Self.focalFramesJSON(t.focalFrames)])
        default:
            throw AgentControlError("unknown_method", "未知操作：\(method)")
        }
    }

    func tetherStatusJSON() -> AgentJSON {
        var o: [String: AgentJSON] = [
            "active": .bool(tether != nil),
            "connecting": .bool(tether == nil && phase == .connecting && connectingHost != nil && connectingHost == lastTetherCamera?.host),
            "error": .optional(errorMessage),
            "autoImport": .bool(tetherAutoImport),
            "projectId": .optional(currentSession?.id.uuidString),
            "projectName": .optional(currentSession?.name),
            "importing": .bool(progress != nil),
            "logPath": .string(TetherCommandLog.currentURL().path),
        ]
        guard let t = tether else { return .object(o) }
        let s = t.status
        o["camera"] = .string(t.cameraName)
        o["lost"] = .bool(t.lost)
        o["message"] = .optional(t.message)
        o["mode"] = .string(s.modeText)
        o["battery"] = .optional(s.batteryText)
        o["recording"] = .bool(s.isRecording)
        o["focused"] = .bool(s.isFocused)
        o["focusLocked"] = .bool(t.focusLocked)
        o["shooting"] = .bool(t.shooting)
        o["receiving"] = .bool(t.downloading || s.pendingTransfers > 0)
        o["shotCount"] = .integer(t.shotCount)
        o["liveView"] = .bool(t.liveViewOn)
        o["spoolPath"] = .string(t.spool.folder.path)
        o["changedProperties"] = .array(t.changed.map { c in .object([
            "code": .string(String(format: "0x%04X", c.code)), "name": .optional(SonyPropertyCatalog.name(c.code)),
            "original": Self.valueJSON(c.code, c.original)]) })
        // info：镜头、电量、两个卡槽剩余张数、曝光模式、照片存储位置（相机没报告的项为 null）。
        let pr = t.properties
        func v(_ c: UInt16) -> AgentJSON { pr[c].map { Self.valueJSON(c, $0.current) } ?? .null }
        o["info"] = .object(["lens": v(0xD07B), "focalLength": v(0xD00B), "battery": v(0xD218), "firmware": v(0xD040),
                             "slot1RemainingShots": v(0xD249), "slot2RemainingShots": v(0xD257),
                             "exposureProgram": v(0x500E), "storeDestination": v(0xD222), "priorityKey": v(0xD25A),
                             "movieRecordingState": v(0xD21D),
                             "shootingMode": .optional(pr[0x500E]?.intValue.flatMap(SonyPropertyCatalog.shootingMode)?.mode.rawValue)])
        o["settings"] = .array(s.settings.map { c in .object([
            "setting": .string(c.kind.rawValue), "title": .string(c.kind.title), "label": .string(c.valueText),
            "value": c.currentValue.map { .integer($0) } ?? .null, "editable": .bool(c.isEditable),
            "options": .array(c.options.map { .object(["value": .integer($0.value), "label": .string($0.label)]) }),
        ]) })
        if let u = t.lastShot {
            var shot: [String: AgentJSON] = ["filename": .string(u.lastPathComponent), "path": .string(u.path)]
            if let e = t.lastShotExif {
                shot["exposure"] = .string(e.exposureText)
                shot["gear"] = .string(e.gearText)
            }
            shot["imported"] = .bool(allShots.contains { s in
                s.handles.contains { items[$0]?.filename == u.lastPathComponent } && isImported(shot: s.id)
            })
            o["lastShot"] = .object(shot)
        } else {
            o["lastShot"] = .null
        }
        return .object(o)
    }

    /// 取景帧写到 outFile：要绝对路径、所在目录已存在、文件不存在（不覆盖）；先写隐藏的临时文件再改名。
    static func saveLiveFrame(_ data: Data, to text: String) throws -> URL {
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw AgentControlError("invalid_params", "outFile 需要绝对路径。") }
        let url = URL(filePath: path)
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw AgentControlError("invalid_path", "目录不存在：" + dir.path)
        }
        guard !fm.fileExists(atPath: url.path) else { throw AgentControlError("file_exists", "文件已存在，未覆盖：" + url.path) }
        let partial = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).partial")
        do {
            try data.write(to: partial)
            try fm.moveItem(at: partial, to: url)  // 目标已存在时失败，不会覆盖
        } catch {
            try? fm.removeItem(at: partial)
            if fm.fileExists(atPath: url.path) { throw AgentControlError("file_exists", "文件已存在，未覆盖：" + url.path) }
            throw AgentControlError("write_failed", "写入失败：\(error.localizedDescription)")
        }
        return url
    }

    static func imageSize(_ data: Data) -> (width: Int, height: Int) {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return (0, 0) }
        return ((p[kCGImagePropertyPixelWidth] as? Int) ?? 0, (p[kCGImagePropertyPixelHeight] as? Int) ?? 0)
    }

    /// 缩到给定宽度以内再编码成 JPEG，免得超过本地接口的单条消息上限。
    static func agentJPEG(_ data: Data, maxWidth: Int) -> (data: Data, width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: maxWidth]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (out as Data, cg.width, cg.height)
    }
}

// MARK: 任意属性、拍完等文件（需要等相机，异步）

extension AppModel {
    /// 拍摄参数快照里的属性（相机没报告的跳过）。
    static let captureSnapshotCodes: [UInt16] = [0x500E, 0xD20D, 0x5007, 0xD21E, 0x5010, 0xD224, 0x5005, 0xD20F, 0x500A, 0x5013,
                                                 0xD0FA, 0xD0FB, 0xD0FC, 0xD0FD, 0xD0FE, 0xD0FF, 0xD100, 0xD101, 0xD102,
                                                 0xD201, 0xD287, 0xD28B, 0xD28D, 0xD28F, 0xD289, 0xD269, 0xD15E, 0xD1A2, 0xD1A3, 0xD1A4]

    func agentTetherAsync(_ method: String, _ p: AgentJSON) async throws -> AgentJSON {
        guard let t = tether else { throw AgentControlError("not_tethering", "没有正在联机拍摄的相机，请先调用 tether.start。") }
        if method == "tether.stop" {
            // 先按要求还原改过的设置，再断开（断开时 PriorityKey 总会交还相机）。
            var restored: [AgentJSON] = []
            if p["restoreSettings"].bool == true {
                for r in await t.restoreChanged() {
                    restored.append(.object([
                        "code": .string(String(format: "0x%04X", r.code)), "name": .optional(SonyPropertyCatalog.name(r.code)),
                        "value": Self.valueJSON(r.code, r.value), "ok": .bool(r.error == nil), "error": .optional(r.error)]))
                }
            }
            guard tether === t else { throw AgentControlError("not_tethering", "联机拍摄已经结束。") }
            stopTether()
            var o = tetherStatusJSON().object!
            o["restored"] = .array(restored)
            return .object(o)
        }
        guard !t.lost else { throw AgentControlError("camera_lost", "与相机的连接已断开。") }
        switch method {
        case "tether.properties":
            let all = try await mapped { try await t.properties() }
            let q = p["query"].string?.lowercased() ?? ""
            let writableOnly = p["writableOnly"].bool == true
            let list = all.filter { d in
                (!writableOnly || d.isWritable)
                    && (q.isEmpty || String(format: "0x%04x", d.code).contains(q) || (SonyPropertyCatalog.name(d.code)?.lowercased().contains(q) ?? false))
            }
            return .object(["count": .integer(list.count), "properties": .array(list.map { Self.propertyJSON($0, options: true) })])
        case "tether.get":
            let names = p["names"].array!.compactMap(\.string)
            guard !names.isEmpty else { throw AgentControlError("invalid_params", "names 不能为空。") }
            let codes = try names.map(Self.resolveProperty)
            let all = Dictionary(try await mapped { try await t.properties() }.map { ($0.code, $0) }, uniquingKeysWith: { _, b in b })
            return .object(["values": .array(try zip(names, codes).map { name, code in
                guard let d = all[code] else { throw AgentControlError("unknown_property", "相机没有报告 \(name)。") }
                return Self.propertyJSON(d, options: false)
            })])
        case "tether.set_properties":
            let items = p["assignments"].array!.compactMap(\.string)
            guard !items.isEmpty else { throw AgentControlError("invalid_params", "assignments 不能为空。") }
            // 先全部解析，名字或写法有错就一项都不动。
            let all = Dictionary(try await mapped { try await t.properties() }.map { ($0.code, $0) }, uniquingKeysWith: { _, b in b })
            var plan: [(name: String, code: UInt16, value: PTPValue, text: String)] = []
            for item in items {
                guard let eq = item.firstIndex(of: "=") else { throw AgentControlError("invalid_params", "要写成 NAME=VALUE：\(item)") }
                let name = String(item[..<eq]).trimmingCharacters(in: .whitespaces)
                let text = String(item[item.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                let code = try Self.resolveProperty(name)
                guard let d = all[code] else { throw AgentControlError("unknown_property", "相机没有报告 \(name)。") }
                if d.dataType == .string {
                    plan.append((name, code, .string(text), text))
                } else if let v = SonyPropertyCatalog.parse(code, text, allowed: d.allowedValues) {
                    plan.append((name, code, .int(v), text))
                } else {
                    let opts = d.allowedValues.prefix(60).map { SonyPropertyCatalog.label(code, $0) ?? "\($0)" }
                    throw AgentControlError("invalid_value", "\(name) 无法识别取值「\(text)」。" + (opts.isEmpty ? "" : "可选：" + opts.joined(separator: "、")))
                }
            }
            let timeout = TimeInterval(p["timeoutSeconds"].int ?? 5)
            var done: [AgentJSON] = []
            for step in plan {
                do {
                    let d = try await t.setVerified(step.code, step.value, timeout: timeout)
                    var o = Self.propertyJSON(d, options: false).object!
                    o["requested"] = .string(step.text)
                    done.append(.object(o))
                    log.add("Agent 设置 \(SonyPropertyCatalog.name(step.code) ?? step.name) = \(step.text)")
                } catch let e as SonyPropertyError {
                    let applied = done.compactMap { $0["name"].string }
                    throw AgentControlError(e.code, (e.errorDescription ?? "") + (applied.isEmpty ? "" : " 已生效：" + applied.joined(separator: "、")))
                } catch {
                    throw Self.cameraError(error)
                }
            }
            return .object(["results": .array(done)])
        case "tether.capture":
            guard !t.shooting else { throw AgentControlError("camera_busy", "上一张还在拍摄。") }
            var outDir: URL?
            if let text = p["outDir"].string {
                let path = (text as NSString).expandingTildeInPath
                guard path.hasPrefix("/") else { throw AgentControlError("invalid_params", "outDir 需要绝对路径。") }
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                    throw AgentControlError("invalid_path", "目录不存在：" + path)
                }
                outDir = URL(filePath: path)
            }
            let snapshot = t.properties
            var settings: [String: AgentJSON] = [:]
            for c in Self.captureSnapshotCodes {
                guard let d = snapshot[c], let name = SonyPropertyCatalog.name(c) else { continue }
                settings[name] = Self.valueJSON(c, d.current)
            }
            let files: [URL]
            do {
                files = try await t.captureWaiting(timeout: TimeInterval(p["timeoutSeconds"].int ?? 60))
            } catch let e as TetherSession.CaptureTimeout {
                throw AgentControlError("capture_timeout", "等待相机传回文件超时；已收到：" + (e.received.isEmpty ? "无" : e.received.map(\.lastPathComponent).joined(separator: "、")))
            } catch {
                throw Self.cameraError(error)
            }
            var copies: [AgentJSON] = []
            if let outDir {
                let fm = FileManager.default
                let targets = files.map { outDir.appending(path: $0.lastPathComponent) }
                if let clash = targets.first(where: { fm.fileExists(atPath: $0.path) }) {
                    throw AgentControlError("file_exists", "目标目录里已有同名文件，未复制（照片仍在联机缓存和存储卡上）：" + clash.path)
                }
                for (src, dst) in zip(files, targets) {
                    do { try fm.copyItem(at: src, to: dst) } catch {
                        throw AgentControlError("write_failed", "复制失败（照片仍在联机缓存和存储卡上）：\(error.localizedDescription)")
                    }
                    copies.append(.string(dst.path))
                }
            }
            return .object([
                "files": .array(files.map { u in .object(["path": .string(u.path), "filename": .string(u.lastPathComponent),
                    "bytes": .integer((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)]) }),
                "copies": .array(copies), "settings": .object(settings),
                "autoImport": .bool(tetherAutoImport && currentSession != nil),
            ])
        case "tether.mode":
            return try await agentTetherMode(t, p)
        case "tether.custom_wb":
            return try await agentCustomWB(t, p)
        case "tether.lens_info":
            let data: Data
            do { data = try await t.lensInformationRaw(type: UInt32(p["type"].int ?? 2)) } catch { throw AppModel.cameraError(error) }
            return .object(["bytes": .integer(data.count), "hex": .string(data.map { String(format: "%02x", $0) }.joined())])
        case "tether.magnifier":
            var all = try await t.freshProperties()
            if let r = p["ratio"].int {
                do { try await t.sendFocusMagnifier(ratio: Int64(r), x: p["x"].int, y: p["y"].int) } catch { throw AppModel.cameraError(error) }
                try await Task.sleep(for: .milliseconds(500))
                all = try await t.freshProperties()
            }
            guard let m = SonyCamera.focusMagnifier(all) else {
                throw AgentControlError("magnifier_unavailable", "相机现在不能放大对焦（0xD254 不可写；通常要先切到 MF）。")
            }
            return .object(["ratio": .integer(m.ratio), "x": .integer(m.x), "y": .integer(m.y), "ratios": .array(m.ratios.map { .integer($0) })])
        case "tether.focus_position":
            var all = try await t.freshProperties()
            guard let c = SonyCamera.focusPositionControl(all) else {
                throw AgentControlError("focus_unavailable", "相机现在不能远程调焦（跟焦 0xE088 和绝对位置 0xE042 都不可写）。")
            }
            if let v = p["position"].int {
                guard c.range.contains(Int64(v)) else {
                    throw AgentControlError("invalid_value", "position 要在 \(c.range.lowerBound)–\(c.range.upperBound) 之间。")
                }
                let seconds = Double(p["seconds"].int ?? 0)
                if seconds > 0 { t.pullFocus(to: Int64(v), seconds: seconds) } else {
                    do { try await t.sendFocusPosition(Int64(v)) } catch { throw AppModel.cameraError(error) }
                    try await Task.sleep(for: .milliseconds(600))
                    all = try await t.freshProperties()
                }
            }
            return .object(["setCode": .string(String(format: "0x%04X", c.setCode)), "currentCode": .string(String(format: "0x%04X", c.currentCode)),
                            "min": .integer(c.range.lowerBound), "max": .integer(c.range.upperBound),
                            "current": all[c.currentCode]?.intValue.map { .integer($0) } ?? .null,
                            "manualFocus": .bool([1, 0x8006].contains(all[SonyProperty.focusMode]?.intValue ?? -1)),
                            "pulling": .bool(t.pullTask != nil)])
        case "tether.touch":
            if p["cancel"].bool == true {
                try await t.cancelTouchFocus()
                return .object(["cancelled": .bool(true)])
            }
            guard let x = p["x"].int, let y = p["y"].int else { throw AgentControlError("invalid_params", "需要 x 和 y（640×480 坐标），或 cancel=true。") }
            let c = try await t.touchFocus(at: CGPoint(x: Double(x) / 639, y: Double(y) / 479))
            let all = try await t.freshProperties()
            return .object(["x": .integer(c.x), "y": .integer(c.y),
                            "function": AppModel.valueJSON(0xD283, all[0xD283]?.current ?? .int(0)),
                            "focusFound": all[SonyProperty.focusFound].map { AppModel.valueJSON(SonyProperty.focusFound, $0.current) } ?? .null])
        case "tether.files":
            let lib = try await mapped { try await t.contentLibrary() }
            let all = try await mapped { try await Self.cardFiles(lib, slot: p["slot"].int.map(UInt32.init)) }
            let latest = p["latest"].int ?? 20
            return .object(["total": .integer(all.count), "files": .array(all.prefix(latest).map(Self.cardFileJSON))])
        case "tether.download":
            let outDir = try Self.outDirectory(p["outDir"].string!)
            let names = p["names"].array!.compactMap(\.string)
            guard !names.isEmpty else { throw AgentControlError("invalid_params", "names 不能为空。") }
            let lib = try await mapped { try await t.contentLibrary() }
            let all = try await mapped { try await Self.cardFiles(lib, slot: nil) }
            let want = UInt32(p["slot"].int ?? 1)
            var picked: [CardFile] = []
            for n in names {
                let hits = all.filter { $0.item.filename.caseInsensitiveCompare(n) == .orderedSame }
                guard let f = hits.first(where: { $0.slot == want }) ?? hits.first else {
                    throw AgentControlError("not_found", "存储卡上没有 \(n)。")
                }
                picked.append(f)
            }
            return .object(["files": .array(try await Self.download(picked, from: lib, to: outDir))])
        case "tether.record_clip":
            let seconds = p["seconds"].int!
            let outDir = try p["outDir"].string.map(Self.outDirectory)
            let lib = try await mapped { try await t.contentLibrary() }
            let before = Set(try await mapped { try await Self.cardFiles(lib, slot: nil) }.filter { $0.item.kind == .video }.map(\.key))
            do {
                try await t.setRecordingWaiting(true)
                try await Task.sleep(for: .seconds(seconds))
                try await t.setRecordingWaiting(false, timeout: 15)
            } catch is TetherSession.RecordingTimeout {
                try? await t.setRecordingWaiting(false, timeout: 15)
                throw AgentControlError("record_failed", "相机没有进入或退出录像状态（检查是否插卡、录像设置是否可用）。")
            } catch {
                try? await t.setRecordingWaiting(false, timeout: 15)
                throw Self.cameraError(error)
            }
            // 停止后片段要过一会儿才出现在卡的列表里。
            let deadline = Date().addingTimeInterval(TimeInterval(p["timeoutSeconds"].int ?? 120))
            var clips: [CardFile] = []
            while Date() < deadline {
                try await Task.sleep(for: .seconds(1))
                guard let fresh = try? await Self.cardFiles(try await t.contentLibrary(), slot: nil) else { continue }
                clips = fresh.filter { $0.item.kind == .video && !before.contains($0.key) }
                if !clips.isEmpty { break }
            }
            guard !clips.isEmpty else { throw AgentControlError("record_timeout", "录像已停止，但存储卡上没有出现新的片段。") }
            var downloaded: [AgentJSON] = []
            if let outDir {
                // 两个卡槽同时记录时文件名相同：只下载卡槽 1 的那份。
                var seen = Set<String>()
                let unique = clips.sorted { $0.slot < $1.slot }.filter { seen.insert($0.item.filename.uppercased()).inserted }
                downloaded = try await Self.download(unique, from: try await t.contentLibrary(), to: outDir)
            }
            return .object(["clips": .array(clips.map(Self.cardFileJSON)), "files": .array(downloaded)])
        default:
            throw AgentControlError("unknown_method", "未知操作：\(method)")
        }
    }

    /// tether.mode：见 TetherSession.switchMode。
    func agentTetherMode(_ t: TetherSession, _ p: AgentJSON) async throws -> AgentJSON {
        let target = SonyPropertyCatalog.ShootingMode(rawValue: p["mode"].string!)!
        let r = try await t.switchMode(to: target, exposure: p["exposure"].string, timeout: TimeInterval(p["timeoutSeconds"].int ?? 8))
        let code = SonyProperty.exposureProgramMode
        return .object([
            "mode": .string(target.rawValue),
            "exposure": .optional(SonyPropertyCatalog.shootingMode(r.to)?.exposure),
            "from": Self.valueJSON(code, .int(r.from)), "to": Self.valueJSON(code, .int(r.to)),
            "priorityKeyChanged": .bool(r.priorityChanged),
        ])
    }

    /// tether.custom_wb：见 TetherSession.customWhiteBalance。
    func agentCustomWB(_ t: TetherSession, _ p: AgentJSON) async throws -> AgentJSON {
        let slot = p["slot"].int!
        let out = try await t.customWhiteBalance(slot: slot, position: p["position"].int.map(Int64.init),
                                                 probe: p["probe"].bool == true, timeout: TimeInterval(p["timeoutSeconds"].int ?? 15))
        if let probe = out.probe {
            let areaInfo: AgentJSON = .object([
                "area": probe.area.map { Self.valueJSON($0.code, $0.current) } ?? .null,
                "areaType": .string(probe.area.map { String(format: "0x%04X", $0.dataType.rawValue) } ?? ""),
                "frame": probe.frame.map { Self.valueJSON($0.code, $0.current) } ?? .null,
                "frameType": .string(probe.frame.map { String(format: "0x%04X", $0.dataType.rawValue) } ?? ""),
            ])
            return .object(["probe": .bool(true), "slot": .integer(slot), "areaInfo": areaInfo,
                            "stateAfterCancel": .integer(probe.stateAfterCancel), "trace": .array(probe.trace)])
        }
        let r = out.result!
        func v(_ c: UInt16) -> AgentJSON { r.properties[c].map { Self.valueJSON(c, $0.current) } ?? .null }
        return .object([
            "slot": .integer(slot), "position": .integer(r.position), "sawCapturing": .bool(r.sawCapturing),
            "colorTemperature": v(0xD20F), "tintGM": v(0xD210), "tintAB": v(0xD21C), "whiteBalance": v(0x5005),
            "trace": .array(r.trace),
        ])
    }

    struct CardFile {
        let item: CameraContentItem
        let slot: UInt32
        let path: String?
        var key: String { "\(slot)|\(path ?? item.filename)|\(item.captureDateRaw)" }
    }

    /// 存储卡上的文件，新的在前。
    static func cardFiles(_ lib: SonyRemoteTransferLibrary, slot: UInt32?) async throws -> [CardFile] {
        var out: [CardFile] = []
        for f in try await lib.folders() where slot == nil || f.id == slot {
            for h in try await lib.handles(in: f) {
                out.append(CardFile(item: try await lib.item(h), slot: f.id, path: await lib.sourcePath(h)))
            }
        }
        return out.enumerated().sorted { a, b in
            let x = a.element.item.captureDate ?? .distantPast, y = b.element.item.captureDate ?? .distantPast
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
    }

    static func cardFileJSON(_ f: CardFile) -> AgentJSON {
        .object(["id": .integer(f.item.id), "filename": .string(f.item.filename), "path": .optional(f.path),
                 "bytes": .integer(f.item.size), "slot": .integer(f.slot), "kind": .string(String(describing: f.item.kind)),
                 "capturedAt": .optional(f.item.captureDate.map { ISO8601DateFormatter().string(from: $0) }),
                 "captureDateRaw": .string(f.item.captureDateRaw)])
    }

    static func outDirectory(_ text: String) throws -> URL {
        let path = (text as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { throw AgentControlError("invalid_params", "outDir 需要绝对路径。") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw AgentControlError("invalid_path", "目录不存在：" + path)
        }
        return URL(filePath: path)
    }

    /// 下载到目录：先检查全部目标（含视频的 XML）都不存在；每个文件先写成隐藏的 .partial，完整后再改名。
    static func download(_ files: [CardFile], from lib: SonyRemoteTransferLibrary, to dir: URL) async throws -> [AgentJSON] {
        let fm = FileManager.default
        func xmlName(_ f: CardFile) -> String { (f.item.filename as NSString).deletingPathExtension + "M01.XML" }
        var targets = files.map { dir.appending(path: $0.item.filename) }
        targets += files.filter { $0.item.kind == .video }.map { dir.appending(path: xmlName($0)) }
        if let clash = targets.first(where: { fm.fileExists(atPath: $0.path) }) {
            throw AgentControlError("file_exists", "目标目录里已有同名文件，未下载：" + clash.path)
        }
        var out: [AgentJSON] = []
        for f in files {
            let dst = dir.appending(path: f.item.filename)
            let partial = dir.appending(path: ".\(f.item.filename).partial")
            try? fm.removeItem(at: partial)
            do {
                try await lib.download(f.item, to: partial, from: 0) { _, _ in }
                try fm.moveItem(at: partial, to: dst)
            } catch {
                try? fm.removeItem(at: partial)
                throw cameraError(error)
            }
            var o: [String: AgentJSON] = ["path": .string(dst.path), "filename": .string(f.item.filename),
                                          "bytes": .integer((try? dst.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)]
            if f.item.kind == .video, let xml = await lib.clipXML(f.item.id) {
                let x = dir.appending(path: xmlName(f))
                // 实际时长：开始和停止录像各有约零点几秒的延迟，片段会比要求的短一点。
                if let d = ClipInfo.parse(xml)?.duration { o["durationSeconds"] = .number(d) }
                do { try xml.write(to: x, options: .withoutOverwriting); o["xml"] = .string(x.path) }
                catch { throw AgentControlError("write_failed", "XML 写入失败：\(error.localizedDescription)") }
            }
            out.append(.object(o))
        }
        return out
    }

    /// 名字或编号 → 属性码；找不到时报 unknown_property。
    static func resolveProperty(_ name: String) throws -> UInt16 {
        guard let c = SonyPropertyCatalog.code(for: name) else {
            throw AgentControlError("unknown_property", "不认识的属性名：\(name)。可用 tether.properties 查看名称。")
        }
        return c
    }

    private func mapped<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch { throw Self.cameraError(error) }
    }

    /// 相机层的错误 → agent 错误码：相机忙、存储卡满、连接断开、属性不可写、取值不合法分开。
    /// 取景附带的对焦框（坐标 0…1，相对整幅取景画面）。
    static func focalFramesJSON(_ info: FocalFrameInfo?) -> AgentJSON {
        guard let info else { return .null }
        func r(_ v: Double) -> AgentJSON { .number((v * 10000).rounded() / 10000) }
        return .object(["version": .integer(info.version), "frames": .array(info.frames.map { f in
            .object(["kind": .string(f.kind.rawValue), "type": .integer(f.type), "state": .integer(f.state),
                     "cx": r(f.cx), "cy": r(f.cy), "w": r(f.w), "h": r(f.h)])
        })])
    }

    static func cameraError(_ error: Error) -> AgentControlError {
        switch error {
        case let e as AgentControlError: return e
        case let e as SonyPropertyError: return AgentControlError(e.code, e.errorDescription ?? "")
        case let e as PTPError:
            switch e.code {
            case PTPResponse.deviceBusy: return AgentControlError("camera_busy", "相机忙，请稍后重试。")
            case 0x200C: return AgentControlError("card_full", "存储卡已满。")
            case 0x2013: return AgentControlError("card_unavailable", "存储卡不可用。")
            default: return AgentControlError("camera_error", e.localizedDescription)
            }
        case is PTPIPTransportError: return AgentControlError("camera_lost", "与相机的连接断开：\(error.localizedDescription)")
        default: return AgentControlError("operation_failed", error.localizedDescription)
        }
    }

    static func valueJSON(_ code: UInt16, _ v: PTPValue) -> AgentJSON {
        switch v {
        case .int(let n):
            var o: [String: AgentJSON] = ["raw": .integer(n)]
            if let l = SonyPropertyCatalog.label(code, n) { o["label"] = .string(l) }
            return .object(o)
        case .string(let s): return .object(["raw": .string(s), "label": .string(s)])
        case .array(let a): return .object(["raw": .array(a.map { .integer($0) })])
        case .none: return .null
        }
    }

    static func propertyJSON(_ d: SonyPropertyDesc, options: Bool) -> AgentJSON {
        var o: [String: AgentJSON] = [
            "code": .string(String(format: "0x%04X", d.code)),
            "name": .optional(SonyPropertyCatalog.name(d.code)),
            "writable": .bool(d.isWritable),
            "state": .string(d.getSet != 1 ? "readOnly" : d.isEnabled == 1 ? "writable" : d.isEnabled == 2 ? "displayOnly" : "disabled"),
            "value": valueJSON(d.code, d.current),
        ]
        if options {
            o["dataType"] = .string(String(format: "0x%04X", d.dataType.rawValue))
            switch d.form {
            case .enumeration(let list): o["options"] = .array(list.map { valueJSON(d.code, .int($0)) })
            case let .range(lo, hi, step): o["range"] = .object(["min": .integer(lo), "max": .integer(hi), "step": .integer(step)])
            case .none: break
            }
        }
        return .object(o)
    }
}
