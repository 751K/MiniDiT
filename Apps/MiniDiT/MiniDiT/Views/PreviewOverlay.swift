import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI

// 大图预览。

struct PreviewOverlay: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        let id = model.previewShot ?? 0
        let shot = model.shots[id]
        let item = shot.flatMap { model.item($0.primary) }
        let selected = model.grid.contains(id)
        let order = model.grid.order
        let index = order.firstIndex(of: id) ?? 0
        let atEnd = index >= order.count - 1
        ZStack(alignment: .bottom) {
            Color.black
            Group {
                if shot?.isVideo == true {
                    if let url = model.previewVideoURL {
                        VideoPreviewSurface(url: url, info: shot.flatMap { model.clipInfos[$0.primary] })
                    } else {
                        VStack(spacing: 14) {
                            if let progress = model.previewVideoProgress {
                                ProgressView(value: progress).frame(width: 240).tint(.white)
                                Text("正在缓存\(model.previewIsProxy ? "代理" : "原片")预览… \(Int(progress * 100))%")
                                Text("关闭预览即可取消，不计入导入记录").font(Theme.Font.caption).foregroundStyle(.white.opacity(0.6))
                            } else if let message = model.previewVideoMessage {
                                Image(systemName: "video").font(.system(size: 36))
                                Text(message).multilineTextAlignment(.center).frame(maxWidth: 420)
                                Button("缓存原片预览（\(FloatingBar.bytes(item?.sizeEstimate ?? 0))）") {
                                    model.retryVideoPreview(allowOriginal: true)
                                }
                                .glassButton().disabled(model.progress != nil)
                            } else { ProgressView("正在读取视频信息…").tint(.white) }
                        }
                    }
                } else if let img = model.previewImage {
                    Image(nsImage: img).resizable().scaledToFit()
                        // 大图还没到：先放大缩略图，模糊处理，免得看着像糊了。
                        .blur(radius: model.previewLoaded ? 0 : 10, opaque: true)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(alignment: .topTrailing) {
                            if selected {
                                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                                    .frame(width: 22, height: 22).background(Circle().fill(Color.accentColor)).padding(8)
                            }
                        }
                        .overlay {
                            if selected { RoundedRectangle(cornerRadius: 9).strokeBorder(Color.accentColor, lineWidth: 2).padding(-4) }
                        }
                        .animation(.easeOut(duration: 0.2), value: model.previewLoaded)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .padding(.init(top: 40, leading: 28, bottom: 84, trailing: 28))
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            bar(shot: shot, item: item, id: id, selected: selected, index: index, count: order.count, atEnd: atEnd)
                .padding(.horizontal, 24).padding(.bottom, 14)
        }
        .foregroundStyle(.white)
        .ignoresSafeArea()
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(keys: [.leftArrow, .rightArrow]) { press in
            let direction = press.key == .leftArrow ? -1 : 1
            if shot?.isVideo == true, model.previewVideoURL != nil {
                model.videoPlayback.step(direction, rate: shot.flatMap { model.clipInfos[$0.primary] }.flatMap { ClipInfo.fpsValue($0.formatFps) } ?? 25)
            } else { model.previewStep(direction) }
            return .handled
        }
        .onKeyPress(.upArrow) { model.previewStep(-1); return .handled }
        .onKeyPress(.downArrow) { model.previewStep(1); return .handled }
        .onKeyPress(.space) {
            if shot?.isVideo == true { model.videoPlayback.toggle() } else { model.closePreview() }
            return .handled
        }
        .onKeyPress(.escape) { model.closePreview(); return .handled }
        .onKeyPress(characters: CharacterSet(charactersIn: "pP")) { _ in model.togglePreviewSelection(); return .handled }
        .accessibilityAddTraits(.isModal)
    }

    /// 底部一条：文件名和参数、翻页、选中、关闭。
    private func bar(shot: Shot?, item: CameraContentItem?, id: UInt32, selected: Bool, index: Int, count: Int, atEnd: Bool) -> some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item?.baseName ?? "").font(Theme.Font.headline)
                    if let x = model.previewExif {
                        Text(x.exposureText).font(Theme.Font.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.85))
                    }
                }
                HStack(spacing: 4) {
                    Text(metaText(shot: shot, item: item))
                    if model.isImported(shot: id) {
                        let copies = model.copyCount(shot: id)
                        Text("·")
                        if copies > 0 {
                            HStack(spacing: 0) {
                                ForEach(0..<min(copies, 2), id: \.self) { _ in
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(copies == 1 ? Theme.warning : Theme.accent)
                                }
                            }
                        }
                        Text(copies >= 2 ? "已备份" : copies == 1 ? "已导入" : "不可访问")
                    }
                    if let gear = model.previewExif?.gearText, !gear.isEmpty {
                        Text("· " + gear).truncationMode(.tail)
                    }
                    if let shot, let r = model.rating(of: shot), r != 0 {
                        Text("· " + (r < 0 ? "标为删除" : String(repeating: "★", count: min(r, 5))))
                    }
                    if shot?.isVideo == true, let c = shot.flatMap({ model.clipInfos[$0.primary] }) {
                        if !c.shotMarks.isEmpty {
                            Text("· Shot Mark " + c.shotMarks.map { m in Self.markTime(m.frame, c) }.joined(separator: "、"))
                        }
                        Text("· " + Self.clipText(c)).truncationMode(.tail)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.72))
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 0) {
                arrow("chevron.left", "上一张（←）", disabled: index == 0) { model.previewStep(-1) }
                Text("\(index + 1) / \(count)")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.white.opacity(0.72))
                    .frame(minWidth: 68)
                arrow("chevron.right", "下一张（→）", disabled: atEnd) { model.previewStep(1) }
            }
            .padding(.trailing, 8)

            Button { model.togglePreviewSelection() } label: {
                HStack(spacing: 8) {
                    Text(selected ? "已选中" : "选中").font(Theme.Font.headline)
                    Text("P").font(.system(size: 11, weight: .medium))
                        .frame(minWidth: 18, minHeight: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.2)))
                }
                .padding(.leading, 16).padding(.trailing, 10).frame(height: 36)
                .background(Capsule().fill(selected ? Color.accentColor : Color.white.opacity(0.16)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("按 P 切换")
            .accessibilityAddTraits(selected ? .isSelected : [])

            Button { model.closePreview() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(.white.opacity(0.16)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
            .accessibilityLabel("关闭预览")
        }
        .padding(.init(top: 6, leading: 20, bottom: 6, trailing: 6))
        .frame(maxWidth: 760)
        .glassCapsule()
        .environment(\.colorScheme, .dark)
    }

    private func metaText(shot: Shot?, item: CameraContentItem?) -> String {
        [model.isMultiSource ? model.sourceLabel(model.source(of: model.previewShot ?? 0)) : "",
         shot.map(model.badge(of:)) ?? "", ThumbCell.time(item)].filter { !$0.isEmpty }.joined(separator: " · ")
            + (model.previewLoaded ? "" : " · 正在加载大图…")
    }

    /// 标记在片段里的位置「0:03」。
    static func markTime(_ frame: Int, _ c: ClipInfo) -> String {
        guard let f = ClipInfo.fpsValue(c.formatFps), f > 0 else { return "第 \(frame) 帧" }
        let s = Int(Double(frame) / f)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 「4K 59.94p · H.265 4:2:2 10bit · S-Log3 / S-Gamut3.Cine · TC 06:05:09;21 · FE 50mm F1.4 GM」
    static func clipText(_ c: ClipInfo) -> String {
        let color = [c.gammaText, c.primariesText].filter { !$0.isEmpty }.joined(separator: " / ")
        return [[c.resolutionText, c.fpsText].filter { !$0.isEmpty }.joined(separator: " "),
                c.codecText, color, c.timecode.isEmpty ? "" : "TC " + c.timecode, c.lens]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func arrow(_ icon: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                .frame(width: 32, height: 36).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled).opacity(disabled ? 0.35 : 1)
        .help(label)
        .accessibilityLabel(label)
    }
}
