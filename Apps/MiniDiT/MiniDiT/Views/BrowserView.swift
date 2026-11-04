import AppKit
import SonyRemoteKit
import SwiftUI

struct BrowserView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.selectedDays) {
                ForEach(model.days) { day in
                    HStack {
                        Text(day.title)
                        Spacer()
                        Text(day.importedCount == day.handles.count ? "已导入" : "\(day.handles.count - day.importedCount) 新")
                            .font(.caption).foregroundStyle(day.importedCount == day.handles.count ? Color.secondary : Color.accentColor)
                        Text("\(day.handles.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 32, alignment: .trailing)
                    }
                    .tag(day.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.connectedName ?? "").bold()
                    Text((model.connectedHost ?? "") + (model.usesRemoteTransfer ? " · 远程传输" : " · 内容传输模式"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            }
        } detail: {
            VStack(spacing: 0) {
                GridView()
                ImportBar()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.disconnect() } label: { Label("断开", systemImage: "xmark.circle") }
                    .disabled(model.progress != nil)
            }
            ToolbarItemGroup {
                if model.slots.count > 1 {
                    Picker("卡槽", selection: $model.slotFilter) {
                        Text("全部卡槽").tag(UInt32?.none)
                        ForEach(model.slots, id: \.self) { Text("卡 \($0)").tag(UInt32?.some($0)) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("照片", isOn: $model.showPhotos)
                Toggle("RAW", isOn: $model.showRaw)
                Toggle("视频", isOn: $model.showVideo)
                Toggle("只看未导入", isOn: $model.onlyNew)
            }
        }
        .navigationTitle(model.connectedName ?? "MiniDiT")
    }
}

struct GridView: View {
    @Environment(AppModel.self) private var model
    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8)]

    var body: some View {
        if model.visibleDays.isEmpty {
            ContentUnavailableView("在左边选择日期", systemImage: "calendar",
                                   description: Text(model.days.isEmpty ? "没有符合筛选条件的文件。" : "可以按住 ⌘ 或 ⇧ 选择多天。"))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.visibleDays) { day in
                        Section {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(day.handles, id: \.self) { h in ThumbCell(handle: h) }
                            }
                        } header: {
                            HStack {
                                Text(day.title).font(.headline)
                                Text("\(day.handles.count) 个文件").foregroundStyle(.secondary)
                                Spacer()
                                Button("选未导入的") { model.selectNew(in: [day.id]) }
                                Button("全选") { model.selectAll(in: [day.id]) }
                                Button("取消选择") { model.deselect(in: [day.id]) }
                            }
                            .buttonStyle(.borderless)
                            .padding(.vertical, 6)
                            .background(.bar)
                        }
                    }
                }
                .padding(12)
            }
        }
    }
}

struct ThumbCell: View {
    @Environment(AppModel.self) private var model
    let handle: UInt32

    var body: some View {
        let item = model.item(handle)
        let selected = model.selection.contains(handle)
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(.quaternary)
                    .aspectRatio(3 / 2, contentMode: .fit)
                    .overlay {
                        if let img = model.thumbnails[handle] {
                            Image(nsImage: img).resizable().scaledToFill()
                        } else {
                            Image(systemName: item?.kind == .video ? "video" : "photo").foregroundStyle(.tertiary)
                        }
                    }
                    .clipped()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.white.opacity(0.8))
                    .shadow(radius: 2)
                    .padding(6)
            }
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 3))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack(spacing: 4) {
                Text(item?.filename ?? "").font(.caption).lineLimit(1)
                if model.isImported(handle) {
                    Image(systemName: "checkmark.seal.fill").font(.caption2).foregroundStyle(.green).help("已导入过")
                }
                Spacer()
                Text(Self.badge(item)).font(.caption2.bold()).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggle(handle) }
        .onAppear { model.requestThumbnail(handle) }
        .onDisappear { model.cancelThumbnail(handle) }
    }

    static func badge(_ item: CameraContentItem?) -> String {
        switch item?.kind {
        case .raw: "RAW"
        case .jpeg: "JPG"
        case .heif: "HEIF"
        case .video: "视频"
        default: ""
        }
    }
}

struct ImportBar: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let p = model.progress {
                HStack {
                    ProgressView(value: p.fraction)
                    Text("\(p.done + p.skipped + p.failed.count)/\(p.total)").monospacedDigit()
                    Button("取消") { model.cancelImport() }
                }
                Text("正在下载 \(p.current) · \(Self.bytes(p.bytesDone)) / \(Self.bytes(p.bytesTotal))")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.selection.isEmpty ? "点缩略图选择要导入的文件" : "已选 \(model.selection.count) 个 · \(Self.bytes(model.selectionBytes))")
                        Text(targetText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    if let s = model.lastSummary {
                        Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        if s.contains("Capture One 导入失败") { Button("重新交给 C1") { model.retryCaptureOne() } }
                    }
                    Button("设置…") { openSettings() }
                    Button {
                        model.beginImport()
                    } label: {
                        Label(model.captureOneMode == .off ? "下载" : model.captureOneMode == .newSession ? "导入到新会话…" : "导入到 Capture One",
                              systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.selection.isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(12)
        .background(.bar)
        .onAppear { model.refreshCaptureOne() }
    }

    private var targetText: String {
        if model.captureOneMode == .newSession {
            return "新建会话放在 \(model.sessionsFolder.path(percentEncoded: false))，照片直接存进会话的 Capture 文件夹"
        }
        var s = "存到 \(model.destination.path(percentEncoded: false))/年/年-月-日"
        switch model.captureOneMode {
        case .off, .newSession: break
        case .c1Settings, .inPlace:
            if let d = model.captureOneDocument { s += " → C1 \(d.kind)「\(d.name)」" } else { s += " → Capture One（导入时自动打开）" }
        }
        return s
    }

    static func bytes(_ n: UInt64) -> String { ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file) }
}
