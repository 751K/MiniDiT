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
                VStack(spacing: 4) {
                    Text("选择来源").font(.system(size: 26, weight: .semibold))
                    Text("选一台相机或一张存储卡，接着按日期挑选照片。").foregroundStyle(.secondary)
                }
                HStack(spacing: 16) {
                    ForEach(tiles) { SourceTile(tile: $0) }
                }
                status.frame(minHeight: 72, alignment: .top)
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 8) {
                Text("找不到相机？手动输入 IP").foregroundStyle(.secondary)
                TextField("192.168.1.23", text: $manualHost)
                    .textFieldStyle(.roundedBorder).frame(width: 132)
                    .onSubmit { model.connect(host: manualHost) }
                Button("连接") { model.connect(host: manualHost) }
                    .buttonStyle(.bordered).buttonBorderShape(.capsule)
                    .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty || model.phase != .idle)
            }
            .padding(.init(top: 10, leading: 20, bottom: 14, trailing: 20))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: 卡片

    private var tiles: [SourceTile.Model] {
        var out: [SourceTile.Model] = []
        let busy = model.phase == .searching || model.phase == .connecting
        if model.phase == .connecting, let h = model.connectingHost {
            let name = model.found.first { $0.host == h }?.knownName ?? model.knownCameras.first { $0.host == h }?.name ?? h
            return [.init(id: "c:" + h, kind: .camera, name: name, detail: "正在连接…", state: .busy, action: nil)]
        }
        for url in model.cards {
            out.append(.init(id: "card:" + url.path, kind: .card, name: url.lastPathComponent, detail: "读卡器",
                             state: busy ? .quiet : .online, action: { model.openCard(url) }))
        }
        var shown = Set<String>()
        for cam in model.found {
            shown.insert(cam.fingerprint)
            let detail = cam.host + (cam.kind == .direct ? "" : " · 访问认证")
            out.append(.init(id: "f:" + cam.fingerprint, kind: .camera, name: cam.knownName ?? "相机", detail: detail,
                             state: .online, action: { model.connect(cam) }))
        }
        for k in model.knownCameras where !shown.contains(k.fingerprint) {
            let detail: String = model.phase == .searching ? "正在查找…" : model.searched ? "不在线" : "上次 \(k.host)"
            out.append(.init(id: "k:" + k.fingerprint, kind: .camera, name: k.name, detail: detail,
                             state: model.phase == .searching ? .busy : .quiet,
                             action: model.phase == .idle ? { model.connect(known: k) } : nil))
        }
        if out.isEmpty {
            out.append(.init(id: "placeholder", kind: .camera, name: "相机", detail: model.phase == .searching ? "正在查找…" : "还没有连过",
                             state: model.phase == .searching ? .busy : .quiet, action: nil))
        }
        return Array(out.prefix(5))
    }

    // MARK: 状态

    @ViewBuilder private var status: some View {
        VStack(spacing: 10) {
            switch model.phase {
            case .searching:
                StatusText(title: model.status.isEmpty ? "正在搜索局域网" : model.status, body: "通常需要几秒钟")
                Button("取消") { model.cancelConnect() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
            case .connecting, .loading:
                StatusText(title: model.status.isEmpty ? "正在连接…" : model.status)
                if model.phase == .connecting {
                    Button("取消") { model.cancelConnect() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                }
            case .idle, .ready:
                if let notice = model.notice {
                    StatusText(title: notice, icon: .ok)
                    primary("搜索相机") { model.search() }
                } else if model.networkBlocked {
                    StatusText(title: "需要本地网络权限才能搜索相机", body: "在「隐私与安全性 › 本地网络」中打开 MiniDiT。", icon: .warn)
                    primary("打开系统设置") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
                    }
                } else if !model.found.isEmpty {
                    StatusText(title: "点一台相机开始连接")
                    Button("重新搜索") { model.search() }.buttonStyle(.bordered).buttonBorderShape(.capsule)
                } else if model.searched {
                    StatusText(title: "没有找到相机", body: "请确认相机和 Mac 连同一个 Wi-Fi，并在相机上打开了遥控拍摄。", icon: .warn)
                    primary("重新搜索") { model.search() }
                } else {
                    primary("搜索相机") { model.search() }
                }
            }
        }
        .frame(maxWidth: 480)
    }

    private func primary(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 17, weight: .semibold)).padding(.horizontal, 10).frame(height: 30) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
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
                case .warn: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                case .ok: Image(systemName: "checkmark").foregroundStyle(.green)
                case nil: EmptyView()
                }
                Text(title).fontWeight(.semibold)
            }
            if !body_.isEmpty { Text(body_).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center) }
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
                    Image(systemName: tile.kind == .camera ? "camera.fill" : "sdcard.fill")
                        .font(.system(size: tile.kind == .camera ? 54 : 50))
                        .foregroundStyle(Color(nsColor: .darkGray))
                        .opacity(tile.state == .quiet ? 0.35 : 1)
                        .frame(width: 96, height: 80)
                    if tile.state == .busy {
                        ProgressView().controlSize(.small)
                            .padding(3).background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
                            .offset(x: 6, y: 2)
                    }
                }
                Spacer(minLength: 0)
                Text(tile.name).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(tile.detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.init(top: 16, leading: 10, bottom: 14, trailing: 10))
            .frame(width: 172, height: 172)
            .foregroundStyle(tile.state == .quiet ? Color.secondary : Color.primary)
            .background {
                RoundedRectangle(cornerRadius: 14)
                    .fill(tile.state == .quiet ? Color.clear : Color(nsColor: .controlBackgroundColor))
                    .brightness(hover && tile.action != nil && tile.state != .quiet ? -0.03 : 0)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: tile.state == .quiet ? [5, 4] : []))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(tile.action == nil)
        .onHover { hover = $0 }
        .accessibilityLabel("\(tile.name)，\(tile.detail)")
    }
}
