import AppKit
import SonyRemoteKit
import SwiftUI

/// 联机拍摄窗口：左边实时取景和快门，右边曝光参数、最近一张、导入去向。关窗口即结束联机。
struct TetherWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Group {
            if let t = model.tether {
                TetherView(session: t)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture").font(.system(size: 32, weight: .light)).foregroundStyle(.secondary)
                    Text("没有正在联机拍摄的相机").font(Theme.Font.headline)
                    Text("在来源页的相机上点右键，或在浏览已连接的索尼相机时选择“文件 > 联机拍摄”。")
                        .font(Theme.Font.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .onDisappear { model.stopTether() }
        .onChange(of: model.tether == nil) { _, ended in if ended { dismissWindow(id: "tether") } }
    }
}

struct TetherView: View {
    @Environment(AppModel.self) private var model
    @Bindable var session: TetherSession

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                liveView
                controls
            }
            Divider()
            sidebar.frame(width: 300)
        }
        .navigationTitle("联机拍摄 — \(session.cameraName)")
    }

    // MARK: 取景

    private var liveView: some View {
        ZStack {
            Color.black
            if let img = session.liveFrame {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityLabel("实时取景")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: session.lost ? "wifi.slash" : session.liveViewOn ? "camera.viewfinder" : "eye.slash")
                        .font(.system(size: 30, weight: .light))
                    Text(session.lost ? "相机已断开" : session.liveViewOn ? "正在等待取景画面…" : "实时取景已关闭")
                        .font(Theme.Font.caption)
                }
                .foregroundStyle(.white.opacity(0.6))
            }
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 8) {
                if !session.status.modeText.isEmpty { badge(session.status.modeText) }
                if let b = session.status.batteryText { badge("电量 \(b)") }
                if session.status.isRecording { badge("● 录像中", color: .red) }
                if session.focusLocked || session.status.isFocused {
                    badge(session.status.isFocused ? "已合焦" : "对焦中", color: session.status.isFocused ? .green : .yellow)
                }
            }
            .padding(10)
        }
        .overlay(alignment: .bottomLeading) {
            if session.downloading || session.status.pendingTransfers > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在接收照片…")
                }
                .font(Theme.Font.caption).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(10)
            }
        }
    }

    private func badge(_ text: String, color: Color = .white) -> some View {
        Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(.black.opacity(0.55), in: Capsule())
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Toggle(isOn: $session.liveViewOn) { Label("取景", systemImage: "eye") }
                .toggleStyle(.button)
                .help("开关实时取景；关闭后照片接收更快")
            Toggle(isOn: Binding(get: { session.focusLocked }, set: { session.setFocusLock($0) })) {
                Label("锁定对焦", systemImage: "scope")
            }
            .toggleStyle(.button)
            .keyboardShortcut("f", modifiers: [])
            .help("相当于半按快门：对焦并保持（F）")
            Spacer()
            Button { session.shoot() } label: {
                ZStack {
                    // 浅色模式是深色快门，深色模式是浅色快门。
                    Circle().fill(Color.primary.opacity(session.lost ? 0.2 : 0.85)).frame(width: 50, height: 50)
                    Circle().strokeBorder(Color.primary.opacity(0.35), lineWidth: 3).frame(width: 60, height: 60)
                    if session.shooting { ProgressView().controlSize(.small).colorInvert() }
                }
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(session.lost || session.shooting)
            .help("拍摄（空格）")
            .accessibilityLabel("拍摄")
            Spacer()
            Button { session.toggleRecording() } label: {
                Label(session.status.isRecording ? "停止录像" : "开始录像",
                      systemImage: session.status.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .foregroundStyle(session.status.isRecording ? .red : .primary)
            .disabled(session.lost)
            .help("录像保存在相机的存储卡上，不会传到 Mac")
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(height: 84)
        .background(Theme.surface)
    }

    // MARK: 侧栏

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let m = session.message {
                        Text(m).font(Theme.Font.caption).foregroundStyle(Theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    exposure
                    latest
                    destination
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("在 Finder 中显示缓存") { NSWorkspace.shared.activateFileViewerSelecting([session.spool.folder]) }
                    .buttonStyle(.link).font(Theme.Font.caption)
                Spacer()
                if session.lost {
                    Button("重新连接") { if let c = model.lastTetherCamera { model.startTether(c) } }
                        .disabled(model.lastTetherCamera == nil || model.progress != nil)
                }
                Button("结束联机") { model.stopTether() }
            }
            .padding(12)
        }
        .background(Theme.surface)
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Theme.Font.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private var exposure: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("曝光")
            if session.status.settings.isEmpty {
                Text("正在读取相机设置…").font(Theme.Font.caption).foregroundStyle(.secondary)
            }
            ForEach(session.status.settings) { s in
                HStack(spacing: 6) {
                    Text(s.kind.title).frame(width: 64, alignment: .leading).foregroundStyle(.secondary)
                    Button { session.step(s.kind, by: -1) } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.borderless).disabled(!s.isEditable || session.lost)
                        .accessibilityLabel("减小\(s.kind.title)")
                    Menu(s.valueText) {
                        ForEach(s.options) { o in
                            Button { session.set(s.kind, value: o.value) } label: {
                                if o.value == s.currentValue { Label(o.label, systemImage: "checkmark") } else { Text(o.label) }
                            }
                        }
                    }
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(maxWidth: .infinity)
                    .disabled(!s.isEditable || session.lost)
                    Button { session.step(s.kind, by: 1) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(.borderless).disabled(!s.isEditable || session.lost)
                        .accessibilityLabel("增大\(s.kind.title)")
                }
                .font(Theme.Font.body.monospacedDigit())
            }
            if session.status.settings.contains(where: { !$0.isEditable }) {
                Text("灰色的参数在当前拍摄模式下由相机决定。").font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var latest: some View {
        VStack(alignment: .leading, spacing: 8) {
            section("最近拍摄")
            if let img = session.lastShotImage {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture(count: 2) { if let u = session.lastShot { NSWorkspace.shared.open(u) } }
                    .help("双击用默认程序打开")
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.sidebarGroup)
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .overlay { Text("还没有拍摄").font(Theme.Font.caption).foregroundStyle(.secondary) }
            }
            if let u = session.lastShot {
                Text(u.lastPathComponent).font(Theme.Font.caption.weight(.medium)).lineLimit(1).truncationMode(.middle)
            }
            if let e = session.lastShotExif {
                if !e.exposureText.isEmpty { Text(e.exposureText).font(Theme.Font.caption.monospacedDigit()) }
                if !e.gearText.isEmpty { Text(e.gearText).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(2) }
            }
            if session.shotCount > 0 {
                Text("本次联机已接收 \(session.shotCount) 个文件").font(Theme.Font.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var destination: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 8) {
            section("导入")
            Toggle("拍摄后自动导入当前项目", isOn: $model.tetherAutoImport)
            if let s = model.currentSession {
                Text("项目：\(s.name)").font(Theme.Font.caption).lineLimit(2)
            } else {
                Text("还没有选择项目。新照片先保存在联机缓存中，在主窗口选择或新建项目后会自动导入。")
                    .font(Theme.Font.caption).foregroundStyle(Theme.warning).fixedSize(horizontal: false, vertical: true)
            }
            if let p = model.progress {
                ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1))) {
                    Text("正在导入 \(p.total) 个文件").font(Theme.Font.caption)
                }
            }
            Button("显示主窗口") { model.showMainWindow() }.buttonStyle(.link).font(Theme.Font.caption)
        }
    }
}
