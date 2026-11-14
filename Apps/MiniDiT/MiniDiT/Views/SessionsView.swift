import AppKit
import QuickLookThumbnailing
import SonyRemoteKit
import SwiftUI

// MARK: - 侧栏「项目」

/// 侧栏里软件自己管理的项目。使用普通 VStack，避免 Native List 的系统行高和缩进。
struct SessionSection: View {
    @Environment(AppModel.self) private var model
    @State private var showAll = false
    private let limit = 5

    var body: some View {
        let all = model.sortedSessions
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("项目")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button { model.newSessionPrompt = .init(importAfter: false) } label: {
                    Image(systemName: "plus").frame(width: 22, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("新建项目")
                .accessibilityLabel("新建项目")
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
            if all.isEmpty {
                Button { model.newSessionPrompt = .init(importAfter: false) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 13)).frame(width: 18, height: 22)
                        Text("新建项目")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            ForEach(showAll ? all : Array(all.prefix(limit))) { session in
                VStack(spacing: 4) {
                    SessionRow(session: session)
                    if session.hasBothMedia {
                        SessionMediaRows(session: session)
                    }
                }
                .padding(.bottom, 6)
            }
            if all.count > limit {
                Button(showAll ? "收起" : "显示全部 \(all.count) 个") { withAnimation(.snappy(duration: 0.2)) { showAll.toggle() } }
                    .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 16).padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 项目与其内容分类共用一个选中高亮；选择分类时不重复高亮父行。
struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let session: ShootSession
    @State private var hover = false
    @State private var dropTargeted = false

    var body: some View {
        let current = model.currentSessionID == session.id
        let selected = current && (model.browsingSession != session.id || model.browsingSessionMedia == nil)
        HStack(spacing: 8) {
            Text(session.name)
                .fontWeight(current ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            ZStack(alignment: .trailing) {
                Text("\(session.files.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    .opacity(hover ? 0 : 1)
                if hover {
                    Button { model.browseSession(session.id) } label: {
                        Image(systemName: "chevron.right.circle.fill").font(.system(size: 14)).foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("查看已导入此项目的文件")
                }
            }
            .frame(width: 22, alignment: .center)
        }
        .contentShape(Rectangle())
        .padding(.leading, 16).padding(.trailing, 16).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.14) : .clear)
                .padding(.horizontal, 10)
        )
        .onHover { hover = $0 }
        .onTapGesture { model.selectSession(session.id) }
        .onDrop(of: [.miniDiTShotSelection], isTargeted: $dropTargeted) { providers in
            guard let provider = providers.first(where: {
                $0.hasItemConformingToTypeIdentifier(UTType.miniDiTShotSelection.identifier)
            }) else { return false }
            provider.loadDataRepresentation(forTypeIdentifier: UTType.miniDiTShotSelection.identifier) { data, _ in
                guard let data,
                      let text = String(data: data, encoding: .utf8) else { return }
                let ids = Set(text.split(separator: ",").compactMap { UInt32($0) })
                guard !ids.isEmpty else { return }
                Task { @MainActor in model.importDropped(shots: ids, into: session) }
            }
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 2)
                    .padding(.horizontal, 6)
                    .allowsHitTesting(false)
            }
        }
        .help(current ? "导入目标：导入的内容将归入“\(session.name)”" : "点按以选为导入目标")
        .contextMenu {
            if current {
                Text("当前导入目标")
            } else {
                Button("选为导入目标") { model.selectSession(session.id) }
            }
            Button("查看已导入的文件") { model.browseSession(session.id) }
            Picker("项目类型", selection: Binding(get: { session.contentType }, set: { model.setContent($0, of: session.id) })) {
                ForEach(ImportContent.allCases) { Text($0.title).tag($0) }
            }
            .disabled(model.progress != nil && model.currentSessionID == session.id)
            Button("在访达中显示") { SessionBrowser.reveal(session) }
                .disabled(SessionBrowser.folders(of: session).isEmpty)
            Divider()
            Button("从列表中移除") { model.removeSession(session.id) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { model.selectSession(session.id) }
        .accessibilityAction(named: "查看已导入的文件") { model.browseSession(session.id) }
        .accessibilityValue(current ? "导入目标" : "")
    }
}

private struct SessionMediaRows: View {
    let session: ShootSession

    var body: some View {
        VStack(spacing: 4) {
            ForEach(ProjectMedia.allCases) { media in
                SessionMediaRow(session: session, media: media)
            }
        }
        .padding(.bottom, 2)
    }
}

/// 项目内实际同时有照片和视频时，才显示这两个内容分类。
private struct SessionMediaRow: View {
    @Environment(AppModel.self) private var model
    let session: ShootSession
    let media: ProjectMedia
    @State private var hover = false

    private var selected: Bool {
        model.currentSessionID == session.id && model.browsingSession == session.id && model.browsingSessionMedia == media
    }

    var body: some View {
        Button {
            model.browseSession(session.id, media: media)
        } label: {
            HStack(spacing: 8) {
                Text(media.title).font(.system(size: 12))
                Spacer(minLength: 4)
                Text(session.fileCount(media).formatted())
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 22, alignment: .center)
            }
            .padding(.leading, 36).padding(.trailing, 16).padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Theme.accent.opacity(0.12) : hover ? Color.primary.opacity(0.05) : .clear)
                    .frame(height: 24)
                    .padding(.leading, 26)
                    .padding(.trailing, 10)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("查看项目中的\(media.title)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - 浏览项目

/// 右边：一个项目里已经导入到电脑上的照片和视频。相机和存储卡不在时也能看。
struct SessionBrowser: View {
    @Environment(AppModel.self) private var model
    let session: ShootSession
    var media: ProjectMedia? = nil
    /// 没连相机时从来源页进来：左上角有返回按钮。
    var onBack: (() -> Void)?
    @State private var showImportResults = false

    /// 照片和视频分开保存，各取一个文件夹；只看照片或视频时只取那一类。
    static func folders(of s: ShootSession, media: ProjectMedia? = nil) -> [URL] {
        let urls = s.urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        let pick = { (m: ProjectMedia) in media == nil || media == m ? urls.filter { ProjectMedia.forPath($0.path) == m } : [] }
        return AppModel.importFolders(photos: pick(.photos), videos: pick(.videos))
    }

    static func reveal(_ s: ShootSession, media: ProjectMedia? = nil) {
        for f in folders(of: s, media: media) { NSWorkspace.shared.open(f) }
    }

    private var subtitle: String {
        let date = ShootSession.date(session.day).map { $0.formatted(.dateTime.year().month().day().locale(Locale(identifier: "zh_CN"))) } ?? "无日期"
        let type = media.map { $0.title + " · " } ?? ""
        return "起始 \(date) · \(type)\(filteredFiles.count) 个文件"
    }

    private var filteredFiles: [String] {
        guard let media else { return session.files }
        return session.files.filter { ProjectMedia.forPath($0) == media }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                header
                if model.importJournal.repairTask != nil {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(model.importJournal.repairProgress).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("取消补备份") { model.importJournal.repairTask?.cancel() }.buttonStyle(.bordered)
                    }.padding(.horizontal, 16).padding(.bottom, 10)
                }
                Divider()
                if filteredFiles.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.system(size: 32)).foregroundStyle(.secondary)
                        Text(media == nil ? "尚未导入任何文件" : "尚未导入\(media!.title)")
                            .font(Theme.Font.headline)
                        Text(onBack == nil
                             ? "选择拍摄日期和素材后点按“导入”，即可归入此项目。"
                             : "返回来源页连接相机或存储卡，再将素材导入此项目。")
                            .font(Theme.Font.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: model.thumbSize), spacing: 12)], spacing: 16) {
                            ForEach(filteredFiles, id: \.self) { LocalFileCell(url: URL(filePath: $0)) }
                        }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
        }
        // 项目页既可独立显示，也可作为分栏详情；遵守所在窗口的标题栏安全区域。
        .background(Theme.surface)
        .sheet(isPresented: $showImportResults) {
            ProjectImportResults(project: session).environment(model)
        }
    }

    private var header: some View {
        @Bindable var model = model
        return HStack(spacing: 10) {
            if let onBack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.bordered)
                    .help("返回来源或素材浏览")
                    .accessibilityLabel("返回")
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name).font(Theme.Font.headline)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(Theme.Font.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            if model.currentSessionID != session.id {
                Button("选为导入目标") { model.selectSession(session.id) }.buttonStyle(.bordered)
            }
            Button("导入记录与备份") { showImportResults = true }.buttonStyle(.bordered)
            Button("在访达中显示") { Self.reveal(session, media: media) }
            .buttonStyle(.bordered)
            .help("在访达中显示")
            .accessibilityLabel("在访达中显示")
            .disabled(Self.folders(of: session, media: media).isEmpty)
            Slider(value: $model.thumbSize, in: 110...320)
                .frame(width: 76)
                .accessibilityLabel("缩略图大小")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .frame(minHeight: 60)
    }
}

/// 一个已导入的文件：系统生成的缩略图 + 文件名。双击用默认软件打开。
private struct LocalFileCell: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var exportLivePhoto = false
    @State private var image: NSImage?
    @State private var missing = false

    private var isVideo: Bool { ProjectMedia.forPath(url.path) == .videos }

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
            if isVideo { Button("导出实况照片…") { exportLivePhoto = true }.disabled(missing) }
        }
        .sheet(isPresented: $exportLivePhoto) {
            let info = ClipInfo.sidecar(for: url).flatMap(ClipInfo.read)
            let record = model.importJournal.batches.lazy.flatMap(\.files).first { file in
                file.assets.contains { $0.copies.contains { $0.role == .working && $0.path == url.path } }
            }
            LivePhotoExportSheet(source: url, name: url.deletingPathExtension().lastPathComponent, center: 1.5,
                marks: info?.shotMarks ?? [], markFrameRate: ClipInfo.fpsValue(info?.formatFps ?? "") ?? 30,
                capturedAt: record?.capturedAt, isProxy: record?.proxyOnly ?? url.path.contains("/Proxy/"))
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
