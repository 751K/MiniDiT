import AppKit
import SonyRemoteKit
import SwiftUI

/// 来源页：选一台相机或一张存储卡。
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var manualHost = ""
    @State private var showingManualConnection = false
    @State private var showingHelp = false

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        brandHeader.padding(.bottom, 12)
                        HStack {
                            Text("选择来源").font(Theme.Font.headline).foregroundStyle(.secondary)
                            Spacer()
                            searchAction
                        }
                        let available = tiles.filter { $0.state == .online }
                        let recent = tiles.filter { $0.state != .online }
                        if !available.isEmpty {
                            deviceGroup(available, title: String(localized: "可用设备"))
                        }
                        if !recent.isEmpty {
                            deviceGroup(recent, title: available.isEmpty ? nil : String(localized: "最近使用"))
                        }
                        if tiles.isEmpty {
                            VStack(spacing: 12) {
                                Image(systemName: "camera").font(.system(size: 28, weight: .light))
                                    .foregroundStyle(.secondary)
                                Text("连接相机或插入存储卡").font(Theme.Font.headline)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 28)
                        }
                        status
                    }
                    .padding(32)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MiniDiT").font(.system(size: 26, weight: .semibold)).tracking(-0.6)
                .foregroundStyle(.primary)
            Text("导入 · 校验 · 交接").font(Theme.Font.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func deviceGroup(_ devices: [SourceTile.Model], title: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(Theme.Font.caption).foregroundStyle(.secondary) }
            ForEach(devices) { SourceTile(tile: $0) }
        }
    }

    private var canConnectManually: Bool {
        !manualHost.trimmingCharacters(in: .whitespaces).isEmpty && model.phase == .idle
    }

    private func connectManually() {
        guard canConnectManually else { return }
        showingManualConnection = false
        model.connect(host: manualHost.trimmingCharacters(in: .whitespaces))
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Button("连接帮助", systemImage: "questionmark.circle") { showingHelp.toggle() }
                .popover(isPresented: $showingHelp) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("连接相机").font(Theme.Font.headline)
                        Text("将相机与 Mac 连接至同一 Wi-Fi，并在相机上开启遥控拍摄。首次连接需要相机上的访问认证信息。")
                        Text("尼康 Z 系列：在相机“连接到电脑”中选择直接连接，Mac 加入相机的 Wi-Fi 后点“搜索相机”；首次连接时核对配对码并在相机上确认。")
                        Text("富士 X / GFX 相机（试验性）：在相机的播放菜单中打开“无线通信”，Mac 加入相机的 Wi-Fi 后点“连接富士相机”；首次连接时在相机上按 OK 确认。")
                        Text("大疆 Osmo Pocket 3 等相机：点“连接大疆相机”，Mac 会通过蓝牙找到相机并加入它的 Wi-Fi；首次连接需要在相机屏幕上点“允许”。连接期间 Mac 的 Wi-Fi 无法上网。")
                        Text("联机拍摄（索尼）：在相机上开启“电脑遥控”，然后在可用设备的相机上点右键选择“联机拍摄”，或连接后点浏览页顶部的“联机拍摄”。拍摄的照片会自动导入当前项目。")
                        Text("USB 连接：用数据线把相机接到 Mac，相机会出现在可用设备里。把相机的 USB 连接方式设为“MTP”或“PC 遥控”（索尼）；设为“大容量存储”时，存储卡会像读卡器一样出现。索尼相机在“PC 遥控”模式下还可以右键选择“联机拍摄”。")
                        Text("也可以直接插入读卡器，选择存储卡开始导入。")
                            .foregroundStyle(.secondary)
                    }
                    .font(Theme.Font.body).padding(20).frame(width: 340)
                }
            Button("连接大疆相机") { model.connectDJI() }
                .disabled(model.phase != .idle)
                .help("通过蓝牙找到大疆 Osmo 相机，并加入它的 Wi-Fi 导入素材")
            Button("连接富士相机") { model.connectFujifilm() }
                .disabled(model.phase != .idle)
                .help("先在相机上打开“无线通信”，并让 Mac 加入相机的 Wi-Fi")
            Button("通过 IP 连接…") { showingManualConnection.toggle() }
                .popover(isPresented: $showingManualConnection) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("通过 IP 连接相机").font(Theme.Font.headline)
                        TextField("相机的 IP 地址", text: $manualHost, prompt: Text("192.168.1.23"))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { connectManually() }
                        HStack {
                            Spacer()
                            Button("连接") { connectManually() }
                                .buttonStyle(.borderedProminent).disabled(!canConnectManually)
                        }
                    }.padding(20).frame(width: 300)
                }
            Spacer(minLength: 12)
            if !model.sessions.isEmpty {
                Menu("浏览项目") {
                    ForEach(model.sortedSessions.prefix(15)) { s in
                        Button("\(s.name)（\(s.files.count)）") { model.browseSession(s.id) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
            }
        }
        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    // MARK: 卡片

    private var tiles: [SourceTile.Model] {
        var out: [SourceTile.Model] = []
        let busy = model.phase == .searching || model.phase == .connecting
        if model.phase == .connecting, let h = model.connectingHost {
            let name = model.found.first { $0.host == h }?.knownName ?? model.knownCameras.first { $0.host == h }?.displayName
                ?? model.usbCameras.first { $0.name == h }?.name ?? String(localized: "相机")
            return [.init(id: "c:" + h, kind: .camera, name: name, detail: String(localized: "正在连接…"), state: .busy, action: nil)]
        }
        for url in model.cards {
            out.append(.init(id: "card:" + url.path, kind: .card, name: url.lastPathComponent, detail: String(localized: "读卡器"),
                             state: busy ? .quiet : .online, action: { model.openCard(url) }))
        }
        // USB 接着的相机排在 Wi-Fi 前面：插着线就是要用它。
        for cam in model.usbCameras {
            out.append(.init(id: "usb:" + cam.id, kind: .camera, name: cam.name, detail: "USB",
                             state: busy ? .quiet : .online, action: busy ? nil : { model.connectUSB(cam) },
                             tether: busy || !cam.isSony ? nil : { model.startTether(usb: cam) }))
        }
        var shown = Set<String>()
        for cam in model.found {
            shown.insert(cam.fingerprint)
            let detail = cam.kind == .direct ? cam.host : String(localized: "\(cam.host) · 访问身份验证")
            let knownModel = model.knownCameras.first { $0.fingerprint == cam.fingerprint }?.model ?? ""
            let sony = knownModel.isEmpty || ["ILCE", "ILME", "ILCA", "ZV-", "DSC-"].contains { knownModel.hasPrefix($0) }
            out.append(.init(id: "f:" + cam.fingerprint, kind: .camera, name: cam.knownName ?? String(localized: "相机"), detail: detail,
                             state: .online, action: busy ? nil : { model.connect(cam) },
                             tether: busy || !sony ? nil : { model.startTether(cam) }))
        }
        // 没识别出型号的直连相机（名字只是 IP）多半是同一台换了 IP，只列最近的一台。
        var unidentifiedShown = false
        for k in model.knownCameras where !shown.contains(k.fingerprint) {
            if k.unidentified { if unidentifiedShown { continue }; unidentifiedShown = true }
            let detail: String = model.searched ? String(localized: "离线") : String(localized: "上次连接：\(k.host)")
            out.append(.init(id: "k:" + k.fingerprint, kind: .camera, name: k.displayName, detail: detail,
                             state: .quiet,
                             action: model.phase == .idle ? { model.connect(known: k) } : nil))
        }
        return Array(out.prefix(5))
    }

    // MARK: 状态

    @ViewBuilder private var searchAction: some View {
        switch model.phase {
        case .searching, .connecting:
            Button("取消") { model.cancelConnect() }.buttonStyle(.bordered)
        case .loading:
            EmptyView()
        case .idle, .ready:
            if !model.networkBlocked {
                if tiles.contains(where: { $0.state == .online }) {
                    Button("重新搜索") { model.search() }.buttonStyle(.bordered)
                } else {
                    Button(model.searched ? "重新搜索相机" : "搜索相机") { model.search() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch model.phase {
        case .searching, .connecting, .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.status.isEmpty ? (model.phase == .searching ? String(localized: "正在搜索局域网…") : String(localized: "正在连接…")) : model.status)
                    .font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        case .idle, .ready:
            if model.networkBlocked {
                VStack(alignment: .leading, spacing: 12) {
                    Label("需要本地网络权限才能搜索相机", systemImage: "exclamationmark.triangle")
                        .font(Theme.Font.body).foregroundStyle(Theme.warning)
                    Button("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                    }.buttonStyle(.borderedProminent)
                }
            } else if let notice = model.notice {
                Text(notice).font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SourceTile: View {
    enum Kind { case camera, card }
    enum State { case online, quiet, busy }

    struct Model: Identifiable {
        let id: String
        let kind: Kind
        let name: String
        let detail: String
        let state: State
        let action: (() -> Void)?
        /// 右键菜单里的「联机拍摄」（索尼 Wi-Fi 相机）。
        var tether: (() -> Void)? = nil
    }

    let tile: Model
    @State private var hover = false

    private var actionTitle: String {
        if tile.state == .busy { return String(localized: "正在连接") }
        if tile.state == .quiet { return String(localized: "重试连接") }
        return tile.kind == .card ? String(localized: "打开") : String(localized: "连接")
    }

    var body: some View {
        Button { tile.action?() } label: {
            HStack(spacing: 14) {
                Image(systemName: tile.kind == .camera ? "camera" : "sdcard")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary).frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(tile.name).font(Theme.Font.headline).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(tile.detail).font(Theme.Font.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 12)
                if tile.state == .busy {
                    ProgressView().controlSize(.small)
                } else {
                    HStack(spacing: 6) {
                        Text(actionTitle).font(Theme.Font.body)
                        Image(systemName: "chevron.right").font(Theme.Font.caption)
                    }
                    .foregroundStyle(tile.state == .online ? Theme.accent : Color.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surface))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(hover && tile.action != nil ? Theme.accent : Theme.border)
            }
            .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(tile.action == nil)
        .onHover { hover = $0 }
        .contextMenu {
            if let t = tile.tether {
                Button("联机拍摄") { t() }
                Button("导入素材") { tile.action?() }
            }
        }
        .accessibilityLabel("\(tile.name)，\(tile.detail)")
        .accessibilityHint(actionTitle)
    }
}
