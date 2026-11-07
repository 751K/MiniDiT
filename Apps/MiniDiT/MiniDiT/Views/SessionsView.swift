import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - 侧栏「会话」

/// 侧栏里软件自己管理的会话：点一个就选为导入目标；点行右边的箭头查看已导入的文件。
/// 放在来源卡片下面、日期列表外面：点会话不会动到日期的选择。
struct SessionSection: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false
    private let limit = 5

    var body: some View {
        let all = model.sortedSessions
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("会话").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { model.newSessionPrompt = .init(importAfter: false) } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建会话")
                .accessibilityLabel("新建会话")
            }
            .padding(.leading, 8).padding(.bottom, 2)
            if all.isEmpty {
                Button { model.newSessionPrompt = .init(importAfter: false) } label: {
                    Label("新建会话", systemImage: "plus").foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(showAll ? all : Array(all.prefix(limit))) { SessionRow(session: $0) }
            if all.count > limit {
                Button(showAll ? "收起" : "显示全部 \(all.count) 个") { withAnimation(.snappy(duration: 0.2)) { showAll.toggle() } }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .padding(.leading, 8).padding(.top, 2)
            }
        }
    }
}

/// 一个会话：点按选为导入目标（浅蓝底、实心文件夹），不占用侧栏的日期选择；右边的箭头查看已导入的文件。
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ShootSession

    var body: some View {
        let current = model.currentSessionID == session.id
        HStack(spacing: 8) {
            Image(systemName: current ? "folder.fill" : "folder")
                .foregroundStyle(current ? Theme.accent : Color.secondary)
                .frame(width: 18)
            Text(session.name).fontWeight(current ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Text("\(session.files.count)").monospacedDigit().foregroundStyle(.secondary)
            Button { model.browsingSession = session.id } label: {
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 20).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("查看已导入此会话的文件")
            .accessibilityLabel("查看\(session.name)")
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(current ? Theme.accent.opacity(0.14) : .clear))
        .contentShape(Rectangle())
        .onTapGesture { model.currentSessionID = session.id }
        .help(current ? "导入目标：导入的内容将归入“\(session.name)”" : "点按以选为导入目标")
        .contextMenu {
            if current {
                Button("取消选为导入目标") { model.currentSessionID = nil }
            } else {
                Button("选为导入目标") { model.currentSessionID = session.id }
            }
            Button("在访达中显示") { SessionBrowser.reveal(session) }
                .disabled(SessionBrowser.folder(of: session) == nil)
            Divider()
            Button("从列表中移除") { model.removeSession(session.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(current ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.currentSessionID = session.id }
        .accessibilityValue(current ? "导入目标" : "")
    }
}

// MARK: - 浏览会话

/// 右边：一个会话里已经导入到电脑上的照片和视频。相机和存储卡不在时也能看。
struct SessionBrowser: View {
    @Environment(AppModel.self) private var model
    let session: ShootSession
    /// 没连相机时从来源页进来：左上角有返回按钮。
    var onBack: (() -> Void)?

    static func folder(of s: ShootSession) -> URL? {
        AppModel.commonFolder(s.urls.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    static func reveal(_ s: ShootSession) {
        if let f = folder(of: s) { NSWorkspace.shared.open(f) }
    }

    private var subtitle: String {
        let date = ShootSession.date(session.day).map { $0.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) } ?? "无日期"
        return "\(date) · \(session.files.count) 个文件"
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let onBack {
                    Button { onBack() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(.bordered)
                        .help("返回")
                        .accessibilityLabel("返回")
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.name).font(Theme.Font.headline)
                    Text(subtitle).font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Spacer(minLength: 8)
                if model.currentSessionID != session.id {
                    Button("选为导入目标") { model.currentSessionID = session.id }.buttonStyle(.bordered)
                }
                Button("在访达中显示") { Self.reveal(session) }
                    .buttonStyle(.bordered)
                    .disabled(Self.folder(of: session) == nil)
                Slider(value: $model.thumbSize, in: 110...320)
                    .frame(width: 76)
                    .accessibilityLabel("缩略图大小")
            }
            .padding(.leading, onBack == nil ? 20 : 12).padding(.trailing, 16)
            .frame(minHeight: 52)

            if session.files.isEmpty {
                VStack(spacing: 8) {
                    Text("尚未导入任何文件").font(Theme.Font.headline)
                    Text("在左侧选择日期并勾选后点按“导入”，内容将归入此会话。")
                        .font(Theme.Font.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbSize), spacing: 12)], spacing: 16) {
                        ForEach(session.files, id: \.self) { LocalFileCell(url: URL(filePath: $0)) }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.surface)
    }
}

/// 一个已导入的文件：系统生成的缩略图 + 文件名。双击用默认软件打开。
private struct LocalFileCell: View {
    let url: URL
    @State private var image: NSImage?
    @State private var missing = false

    private var isVideo: Bool { ["mp4", "mov", "mxf"].contains(url.pathExtension.lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else if missing {
                    VStack(spacing: 4) {
                        Image(systemName: "questionmark.folder").font(.system(size: 20))
                        Text("已移动或删除").font(Theme.Font.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .aspectRatio(3 / 2, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if isVideo {
                    Text("视频").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.5)))
                        .padding(6)
                }
            }
            Text(url.lastPathComponent).font(Theme.Font.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !missing { NSWorkspace.shared.open(url) } }
        .contextMenu {
            Button("打开") { NSWorkspace.shared.open(url) }.disabled(missing)
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.disabled(missing)
        }
        .help(url.path(percentEncoded: false))
        .task(id: url) {
            guard FileManager.default.fileExists(atPath: url.path) else { missing = true; return }
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 320, height: 214), scale: 2,
                                                   representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req).nsImage
        }
    }
}
