import AppKit
import SonyRemoteKit
import SwiftUI

/// 来源页：选一台相机或一张存储卡。
struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var manualHost = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 24) {
                Text("选择来源").font(Theme.Font.title)
                HStack(spacing: 16) {
                    ForEach(tiles) { SourceTile(tile: $0) }
                }
                status.frame(minHeight: 72, alignment: .top)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Text("手动输入 IP 地址").font(Theme.Font.caption).foregroundStyle(.secondary)
                TextField("192.168.1.23", text: $manualHost)
                    .textFieldStyle(.roundedBorder).frame(width: 132)
                    .onSubmit { model.connect(host: manualHost) }
                Button("连接") { model.connect(host: manualHost) }
                    .buttonStyle(.bordered)
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || model.phase != .idle)
            }
            .padding(.init(top: 10, leading: 20, bottom: 14, trailing: 20))
            .frame(maxWidth: .infinity)
            .overlay(alignment: .trailing) {
                // 没连相机也能看以前导入的会话。
                if !model.sessions.isEmpty {
                    Menu("浏览会话") {
                        ForEach(model.sortedSessions.prefix(15)) { s in
                            Button("\(s.name)（\(s.files.count)）") { model.browsingSession = s.id }
                        }
                    }
                    .menuStyle(.button).buttonStyle(.bordered).fixedSize()
                    .padding(.init(top: 10, leading: 0, bottom: 14, trailing: 20))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface)
    }

    // MARK: 卡片

    private var tiles: [SourceTile.Model] {
        var out: [SourceTile.Model] = []
        let busy = model.phase == .searching || model.phase == .connecting
        if model.phase == .connecting, let h = model.connectingHost {
            let name = model.found.first { $0.host == h }?.knownName ?? model.knownCameras.first { $0.host == h }?.displayName ?? "相机"
            return [.init(id: "c:" + h, kind: .camera, name: name, detail: "正在连接…", state: .busy, action: nil)]
        }
        for url in model.cards {
            out.append(.init(id: "card:" + url.path, kind: .card, name: url.lastPathComponent, detail: "读卡器",
                             state: busy ? .quiet : .online, action: { model.openCard(url) }))
        }
        var shown = Set<String>()
        for cam in model.found {
            shown.insert(cam.fingerprint)
            let detail = cam.host + (cam.kind == .direct ? "" : " · 访问身份验证")
            out.append(.init(id: "f:" + cam.fingerprint, kind: .camera, name: cam.knownName ?? "相机", detail: detail,
                             state: .online, action: { model.connect(cam) }))
        }
        // 没识别出型号的直连相机（名字只是 IP）多半是同一台换了 IP，只列最近的一台。
        var unidentifiedShown = false
        for k in model.knownCameras where !shown.contains(k.fingerprint) {
            if k.unidentified { if unidentifiedShown { continue }; unidentifiedShown = true }
            let detail: String = model.phase == .searching ? "正在查找…" : model.searched ? "离线" : "上次连接：\(k.host)"
            out.append(.init(id: "k:" + k.fingerprint, kind: .camera, name: k.displayName, detail: detail,
                             state: model.phase == .searching ? .busy : .quiet,
                             action: model.phase == .idle ? { model.connect(known: k) } : nil))
        }
        if out.isEmpty {
            out.append(.init(id: "placeholder", kind: .camera, name: "相机", detail: model.phase == .searching ? "正在查找…" : "尚未连接过",
                             state: model.phase == .searching ? .busy : .quiet, action: nil))
        }
        return Array(out.prefix(5))
    }

    // MARK: 状态

    @ViewBuilder private var status: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .searching:
                StatusText(title: model.status.isEmpty ? "正在搜索局域网" : model.status, body: "通常需要数秒")
                Button("取消") { model.cancelConnect() }.buttonStyle(.bordered).controlSize(.large)
            case .connecting, .loading:
                StatusText(title: model.status.isEmpty ? "正在连接…" : model.status)
                if model.phase == .connecting {
                    Button("取消") { model.cancelConnect() }.buttonStyle(.bordered).controlSize(.large)
                }
            case .idle, .ready:
                if let notice = model.notice {
                    StatusText(title: notice, icon: .ok)
                    primary("搜索相机") { model.search() }
                } else if model.networkBlocked {
                    StatusText(title: "需要本地网络权限才能搜索相机", body: "请在“隐私与安全性 › 本地网络”中启用 MiniDiT。", icon: .warn)
                    primary("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                    }
                } else if !model.found.isEmpty {
                    StatusText(title: "请选择要连接的相机")
                    Button("重新搜索") { model.search() }.buttonStyle(.bordered).controlSize(.large)
                } else if model.searched, !model.cards.isEmpty {
                    // 插着存储卡时没找到相机不算问题，不出警告。
                    Button("重新搜索相机") { model.search() }.buttonStyle(.bordered).controlSize(.large)
                } else if model.searched {
                    StatusText(title: "未找到相机", body: "请确认相机与 Mac 已连接至同一 Wi-Fi 网络，并已在相机上开启遥控拍摄。", icon: .warn)
                    primary("重新搜索") { model.search() }
                } else {
                    primary("搜索相机") { model.search() }
                }
            }
        }
        .frame(maxWidth: 480)
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
    }
}

private struct StatusText: View {
    enum Icon { case warn, ok }
    let title: String
    var body_: String = ""
    var icon: Icon?

    init(title: String, body: String = "", icon: Icon? = nil) {
        self.title = title
        self.body_ = body
        self.icon = icon
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 6) {
                switch icon {
                case .warn: Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                case .ok: Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                case nil: EmptyView()
                }
                Text(title).font(Theme.Font.headline)
            }
            if !body_.isEmpty { Text(body_).font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .accessibilityElement(children: .combine)
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
    }

    let tile: Model
    @State private var hover = false

    var body: some View {
        Button { tile.action?() } label: {
            VStack(spacing: 2) {
                ZStack(alignment: .bottomTrailing) {
                    // 主题色线条图标；离线的用灰色。
                    Image(systemName: tile.kind == .camera ? "camera" : "sdcard")
                        .font(.system(size: tile.kind == .camera ? 44 : 40, weight: .light))
                        .foregroundStyle(tile.state == .quiet ? Color.secondary : Theme.accent)
                        .frame(width: 96, height: 80)
                    if tile.state == .busy {
                        ProgressView().controlSize(.small)
                            .padding(3).background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                            .offset(x: 6, y: 2)
                    }
                }
                Spacer(minLength: 0)
                Text(tile.name).font(Theme.Font.headline).lineLimit(1)
                Text(tile.detail).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.init(top: 16, leading: 10, bottom: 14, trailing: 10))
            .frame(width: 172, height: 172)
            .foregroundStyle(tile.state == .quiet ? Color.secondary : Color.primary)
            // 白底细边框（和设置向导的卡片一样）；可点的卡片悬停时边框换成主题色。
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
        .accessibilityLabel("\(tile.name)，\(tile.detail)")
    }
}
