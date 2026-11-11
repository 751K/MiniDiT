import AppKit
import MiniDiTCore
import SonyRemoteKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 只用于应用内“把所选素材拖到拍摄项目”，不会出现在 Finder。
    static let miniDiTShotSelection = UTType(exportedAs: "com.kong.MiniDiT.shot-selection")
}

/// 只接管已选中格子的普通左键；修饰键点击、右键菜单和未选中处的框选仍由 SwiftUI 处理。
struct FileDragSource: NSViewRepresentable {
    let model: AppModel
    let shotID: UInt32

    func makeNSView(context: Context) -> DragView { DragView(model: model, shotID: shotID) }
    func updateNSView(_ view: DragView, context: Context) {
        view.model = model
        view.shotID = shotID
    }

    final class DragView: NSView, NSDraggingSource {
        var model: AppModel
        var shotID: UInt32
        private var down: NSEvent?
        private var dragged = false
        // 所有拖出共用队列；上一次拖出尚在下载时，下一批也不能抢同一台相机。
        private static let queue = FileExportQueue()

        init(model: AppModel, shotID: UInt32) {
            self.model = model
            self.shotID = shotID
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent,
                  [.leftMouseDown, .leftMouseDragged, .leftMouseUp].contains(event.type),
                  event.modifierFlags.intersection([.command, .shift, .control]).isEmpty,
                  model.grid.contains(shotID), super.hitTest(point) != nil else { return nil }
            return self
        }

        override func mouseDown(with event: NSEvent) {
            down = event
            dragged = false
        }

        override func mouseUp(with event: NSEvent) {
            defer { down = nil }
            guard !dragged else { return }
            if event.clickCount == 2 { model.openPreview(shotID) }
            else { model.grid.click(shotID, .none) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard !dragged, let down,
                  hypot(event.locationInWindow.x - down.locationInWindow.x,
                        event.locationInWindow.y - down.locationInWindow.y) >= 6 else { return }
            dragged = true
            // 只快照选择，不在鼠标按下或拖动期间下载；取消拖动不会留下文件。
            let files = model.selectedFiles()
            guard !files.isEmpty else { return }
            let names = FileExport.filenames(files.map(\.filename))
            var draggingItems: [NSDraggingItem] = []
            let point = convert(down.locationInWindow, from: nil)
            for (index, item) in files.enumerated() {
                let local = ImportHistory.shared.localFile(item, camera: model.camera(of: item.id))
                    ?? ImportHistory.shared.backupFile(item, camera: model.camera(of: item.id))
                let route = model.route(item.id)
                guard local != nil || route != nil else {
                    model.errorMessage = "无法拖出 \(item.filename)：来源已断开，请重新连接后再试。"
                    return
                }
                let file = FileExport(item: model.localItem(item), library: route?.library, localCopy: local)
                let promise = ExportPromise(file: file, filename: names[index], queue: Self.queue) { [weak model] message in
                    model?.log.add(message)
                    model?.errorMessage = message
                }
                let type = UTType(filenameExtension: (item.filename as NSString).pathExtension) ?? .data
                let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promise)
                // NSFilePromiseProvider.delegate 是 weak。跟随 pasteboard 保活，松手后异步下载仍能完成。
                provider.userInfo = promise
                let drag = NSDraggingItem(pasteboardWriter: provider)
                let image = model.thumbnails[model.shots[shotID]?.primary ?? shotID]
                    ?? NSWorkspace.shared.icon(for: type)
                let size = NSSize(width: 96, height: 64)
                drag.setDraggingFrame(NSRect(x: point.x - 48, y: point.y - 32, width: size.width, height: size.height), contents: image)
                draggingItems.append(drag)
            }
            // Finder 只处理上面的文件 promise；项目行用这个自定义类型接收完整导入任务。
            let selection = NSPasteboardItem()
            selection.setString(model.grid.selected.sorted().map(String.init).joined(separator: ","),
                                forType: NSPasteboard.PasteboardType(UTType.miniDiTShotSelection.identifier))
            let selectionDrag = NSDraggingItem(pasteboardWriter: selection)
            let invisible = NSImage(size: NSSize(width: 1, height: 1))
            selectionDrag.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 1, height: 1), contents: invisible)
            draggingItems.append(selectionDrag)
            let session = beginDraggingSession(with: draggingItems, event: down, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            .copy
        }

        func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
            down = nil
        }
    }
}

private final class ExportPromise: NSObject, NSFilePromiseProviderDelegate, Sendable {
    let file: FileExport
    let filename: String
    let queue: FileExportQueue
    let onError: @MainActor @Sendable (String) -> Void

    init(file: FileExport, filename: String, queue: FileExportQueue,
         onError: @escaping @MainActor @Sendable (String) -> Void) {
        self.file = file
        self.filename = filename
        self.queue = queue
        self.onError = onError
    }

    @MainActor func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        filename
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                        completionHandler: @escaping ((any Error)?) -> Void) {
        let completion = PromiseCompletion(completionHandler)
        Task {
            do {
                try await queue.write(file, to: url)
                completion.finish(nil)
            } catch {
                completion.finish(error)
                await onError("拖出 \(filename) 失败：\(error.localizedDescription)")
            }
        }
    }
}

/// AppKit 的旧回调没有 Sendable 标注；这里只转交给一个 Task，并且恰好回调一次。
private struct PromiseCompletion: @unchecked Sendable {
    let finish: ((any Error)?) -> Void
    init(_ finish: @escaping ((any Error)?) -> Void) { self.finish = finish }
}
