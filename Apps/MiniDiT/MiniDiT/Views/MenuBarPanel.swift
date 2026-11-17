import AppKit
import SwiftUI

/// 菜单栏图标。它一直都在，所以也由它来响应「打开主窗口」的请求（主窗口关了以后没有别的视图能调 openWindow）。
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.progress != nil ? "arrow.down.circle" : "camera.aperture")
            .onChange(of: model.windowRequest) { _, _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            .accessibilityLabel("MiniDiT")
    }
}

/// 点菜单栏图标弹出的小面板：现在开着什么、有多少新照片、插着哪些卡，打开窗口 / 设置 / 退出。
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            if let p = model.progress {
                ProgressView(value: Double(p.bytesDone), total: Double(max(p.bytesTotal, 1)))
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            if model.autoCountdown != nil {
                Button("取消自动导入") { model.cancelAutoImport() }
                    .controlSize(.small)
                    .padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                if model.library != nil {
                    ForEach(model.sources) { s in
                        row(icon: s.isCard ? "sdcard" : "camera", title: s.name,
                            detail: s.offline ? String(localized: "已断开，正在重新连接…") : s.detail) { open() }
                    }
                }
                ForEach(model.unopenedCards, id: \.self) { url in
                    row(icon: "sdcard", title: url.lastPathComponent,
                        detail: model.library == nil ? String(localized: "读卡器 · 点按以打开") : String(localized: "读卡器 · 点按以同时打开")) {
                        dismiss()
                        model.openInsertedCard(url)
                    }
                }
                if model.library == nil, model.unopenedCards.isEmpty {
                    row(icon: "magnifyingglass", title: String(localized: "连接相机或存储卡…"), detail: nil) { open() }
                }
            }
            .padding(6)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                row(icon: "macwindow", title: String(localized: "打开 MiniDiT 窗口"), detail: nil) { open() }
                SettingsLink {
                    rowLabel(icon: "gearshape", title: String(localized: "设置…"), detail: nil)
                }
                .buttonStyle(MenuRowStyle())
                .simultaneousGesture(TapGesture().onEnded { dismiss(); NSApp.activate(ignoringOtherApps: true) })
                row(icon: "power", title: model.progress != nil ? String(localized: "退出（将中断导入）") : String(localized: "退出 MiniDiT"), detail: nil) {
                    NSApp.terminate(nil)
                }
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "camera.aperture").font(.system(size: 20)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                let st = model.menuStatus
                if !st.isEmpty { Text(st).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }

    private var title: String {
        if model.library == nil { return "MiniDiT" }
        return model.isMultiSource ? String(localized: "\(model.sources.count) 个来源") : (model.sources.first?.name ?? "MiniDiT")
    }

    private func open() {
        dismiss()
        model.showMainWindow()
    }

    private func row(icon: String, title: String, detail: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(icon: icon, title: title, detail: detail) }
            .buttonStyle(MenuRowStyle())
    }

    private func rowLabel(icon: String, title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13)).lineLimit(1)
                if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
    }
}

/// 面板里一行：悬停时浅色底，和系统菜单相似。
private struct MenuRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            configuration.label
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hover ? 0.08 : 0)))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}
