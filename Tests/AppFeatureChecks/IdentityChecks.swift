import AppKit
import Foundation
import CoreGraphics
import ImageIO
import MiniDiTCore
import SonyRemoteKit
import SwiftUI
@testable import MiniDiT

@main struct IdentityChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        let saved = defaults.persistentDomain(forName: domain)
        defer {
            if let saved { defaults.setPersistentDomain(saved, forName: domain) }
            else { defaults.removePersistentDomain(forName: domain) }
        }
        defaults.removePersistentDomain(forName: domain)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "minidit-identity-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let a = root.appending(path: "one/Card"), b = root.appending(path: "two/Card")
        let c = root.appending(path: "clone/Card")
        for folder in [a,b,c] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        func descriptor(_ path: URL, uuid: String? = "A", size: UInt64 = 128_000_000_000) -> CardDescriptor {
            .init(kind: .volume, volumeUUID: uuid, capacity: size, label: "NO NAME", root: path.resolvingSymlinksInPath().path)
        }
        let store = SourceIdentityStore(url: root.appending(path: "cards.json"))
        let first = store.register(root: a, descriptor: descriptor(a))
        let second = store.register(root: b, descriptor: descriptor(b, uuid: "B"))
        precondition(first.profileID != nil && first.profileID != second.profileID)
        store.rename(root: a, to: "主机卡 01")
        store.rename(root: b, to: "副机卡 01")
        precondition(store.name(for: a) == "主机卡 01" && store.name(for: b) == "副机卡 01")
        store.retainOpen([])
        let moved = store.register(root: c, descriptor: descriptor(c))
        precondition(moved.profileID == first.profileID && store.name(for: c) == "主机卡 01")
        let reloaded = SourceIdentityStore(url: root.appending(path: "cards.json"))
        precondition(reloaded.profiles == store.profiles)
        // Same UUID mounted twice: neither automatic association remains authoritative.
        _ = store.register(root: a, descriptor: descriptor(a))
        precondition(store.binding(for: a)?.needsConfirmation == true)
        precondition(store.binding(for: c)?.needsConfirmation == true)
        precondition(store.binding(for: a)?.profileID == nil && store.binding(for: c)?.profileID == nil)
        precondition(store.confirm(root: a, existing: first.profileID, name: "主机卡 01"))
        precondition(!store.confirm(root: c, existing: first.profileID, name: "不能共用"))
        precondition(store.confirm(root: c, existing: nil, name: "另一张卡"))
        precondition(store.binding(for: a)?.profileID != store.binding(for: c)?.profileID)
        store.retainOpen([])
        precondition(store.register(root: a, descriptor: descriptor(a)).needsConfirmation)
        // A missing identifier can be named and explicitly confirmed, but cannot be
        // automatically recognized at the next connection.
        let unknown = SourceIdentityStore(url: root.appending(path: "unknown.json"))
        _ = unknown.register(root: a, descriptor: descriptor(a, uuid: nil))
        precondition(unknown.profiles.isEmpty && unknown.binding(for: a)?.needsConfirmation == true)
        precondition(unknown.confirm(root: a, existing: nil, name: "临时卡"))
        unknown.retainOpen([])
        precondition(unknown.register(root: a, descriptor: descriptor(a, uuid: nil)).needsConfirmation)
        // Folder identities use the directory, not the host disk's UUID alone.
        let folderStore = SourceIdentityStore(url: root.appending(path: "folders.json"))
        let folderA = folderStore.register(root: a), folderB = folderStore.register(root: b)
        precondition(folderA.descriptor.kind == .directory && folderB.descriptor.kind == .directory)
        precondition(folderA.profileID != folderB.profileID)
        precondition(folderA.descriptor.capacity == nil && folderA.descriptor.cardType == nil)
        // Two cards shot by the same camera retain independent names. Camera clock
        // preferences can still belong to the camera, without owning the card name.
        let model = AppModel(startServices: false, journalURL: root.appending(path: "journal.sqlite"), identityURL: root.appending(path: "model-cards.json"))
        model.sessions = []
        model.sourceKind = .card; model.cardRoot = a; model.library = LocalCardLibrary(root: a)
        model.extraSources = [ExtraSource(id: 1, root: b, library: LocalCardLibrary(root: b))]
        model.prepareSourceIdentities()
        model.cardCameraNames = [0:"α7 V", 1:"α7 V"]
        model.cardCameraKeys = [0:"ILCE-7M5#12345",1:"ILCE-7M5#12345"]
        model.cameraProfiles["ILCE-7M5#12345"] = CameraProfile(nickname: "主机", clockOffset: 2)
        model.rename(0, to: "第一张卡"); model.rename(1, to: "第二张卡")
        precondition(model.sourceName(0) == "第一张卡" && model.sourceName(1) == "第二张卡")
        precondition(model.cameraProfiles["ILCE-7M5#12345"]?.nickname == "主机")
        precondition(model.sourceIdentitySnapshot(0).cardID != model.sourceIdentitySnapshot(1).cardID)
        precondition(model.bodyIdentity(for: 0) == model.bodyIdentity(for: 1))
        precondition(model.sourceIdentitySnapshot(0).cameraID == nil && model.sourceIdentitySnapshot(1).cameraID == nil,
                     "一张卡上观察到的机身不能冒充所有文件的拍摄机身")
        precondition(model.distinctBodies == 1)
        let typedModel = AppModel(startServices: false, journalURL: root.appending(path: "typed.sqlite"), identityURL: root.appending(path: "typed-cards.json"))
        typedModel.sourceKind = .card; typedModel.cardRoot = a
        _ = typedModel.sourceIdentities.register(root: a, descriptor: .init(kind: .volume, volumeUUID: "typed", capacity: 128_000_000_000,
                                                                          cardType: .cfexpressA, label: "Card", root: a.path))
        precondition(typedModel.sourceIdentitySnapshot(0).cardType == .cfexpressA)
        typedModel.sourceKind = .camera; typedModel.cardRoot = nil
        precondition(typedModel.sourceIdentitySnapshot(0).cardType == nil)
        // Changing labels or connection paths never changes a saved import snapshot.
        let identity = model.sourceIdentitySnapshot(0)
        var file = ImportedFileRecord(id: "one", projectID: UUID(), filename: "A.JPG", source: model.sourceName(0))
        file.sourceIdentity = identity
        let batch = ImportBatchRecord(files: [file], backupRequested: false, backupRoot: nil)
        precondition(model.importJournal.begin(batch))
        model.rename(0, to: "后来改名")
        precondition(model.importJournal.batches[0].files[0].sourceIdentity == identity)
        // Captured connection identities survive promotion; removed files cannot
        // inherit the promoted source's identity just because handles/names match.
        let item = CameraContentItem(id: 1, storageID: 0x10001, filename: "A.JPG", format: PTPObjectFormat.jpeg, size: 1,
                                     captureDate: nil, captureDateRaw: "20261109T120000", width: 0, height: 0)
        let other = item.withID(2)
        model.origins = [1:Origin(source:0,local:1,connectionID:model.primaryConnectionID),
                         2:Origin(source:1,local:1,connectionID:model.extraSources[0].connectionID)]
        let beforeA = model.stableKey(item), beforeB = model.stableKey(other)
        let promoted = model.extraSources.removeFirst()
        model.promote(promoted)
        precondition(model.stableKey(item) == beforeA && model.stableKey(other) == beforeB && beforeA != beforeB)
        // Unknown bodies on the same IP do not acquire a permanent identity.
        let cameraModel = AppModel(startServices: false)
        cameraModel.sourceKind = .camera; cameraModel.connectedName = "α7 V"; cameraModel.connectedHost = "192.168.1.2"
        let firstConnection = cameraModel.camera(of: 1)
        cameraModel.primaryConnectionID = UUID()
        let nextConnection = cameraModel.camera(of: 1)
        precondition(firstConnection != nextConnection && cameraModel.bodyIdentity(for: 0) == nil)
        let priorProfiles = cameraModel.cameraProfiles
        cameraModel.rename(0, to: "本次主机")
        precondition(cameraModel.cameraProfiles == priorProfiles && cameraModel.sessionCameraProfiles[0]?.nickname == "本次主机")
        let corruptPath = root.appending(path: "corrupt.json")
        try Data("invalid".utf8).write(to: corruptPath)
        let corrupt = SourceIdentityStore(url: corruptPath)
        _ = corrupt.register(root: a, descriptor: descriptor(a))
        precondition(!corrupt.confirm(root: a, existing: nil, name: "新卡"))
        let originalBytes = try Data(contentsOf: corruptPath)
        precondition(originalBytes == Data("invalid".utf8))
        // One card may contain photos from different bodies. Each actual file
        // supplies its own camera metadata; neither inherits the first photo's body.
        let previousHistory = ImportHistory.shared
        ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = previousHistory }
        let mixed = root.appending(path: "mixed")
        let media = mixed.appending(path: "DCIM/100MSDCF")
        try fm.createDirectory(at: media, withIntermediateDirectories: true)
        for (name, serial) in [("DSC00001.JPG", "000111"), ("DSC00002.JPG", "000222")] {
            let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            let data = NSMutableData()
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)!
            let metadata: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel:"ILCE-7M5"],
                                            kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber:serial]]
            CGImageDestinationAddImage(destination, context.makeImage()!, metadata as CFDictionary)
            precondition(CGImageDestinationFinalize(destination))
            try (data as Data).write(to: media.appending(path: name))
        }
        model.resetContent(); model.extraSources = []
        model.sourceKind = .card; model.cardRoot = mixed; model.library = LocalCardLibrary(root:mixed)
        model.primaryConnectionID = UUID(); model.phase = .idle
        model.sessionRecordURL = root.appending(path: "projects.json")
        model.captureOneMode = .off; model.openAfterImport = .none; model.backupEnabled = false
        model.sendToFCP = false; model.sendToResolve = false; model.deleteAfterImport = false
        model.importContent = .photos; model.onlyNew = false; model.autoRefresh = false; model.mediaFilter = .init()
        model.destination = root.appending(path: "work")
        let project = ShootSession(day:"20261109", name:"混合机身")
        model.sessions = [project]; model.currentSessionID = project.id
        await model.loadAll()
        model.selectAll(in:Set(model.days.map(\.id)))
        precondition(model.selectedFiles().count == 2)
        model.importToCurrentSession()
        for _ in 0..<500 {
            if model.importTask == nil { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        let result = model.importJournal.records(for:project.id).first!
        precondition(result.savedCount == 2)
        precondition(Set(result.files.compactMap { $0.sourceIdentity?.cameraID }) == ["ILCE-7M5#111", "ILCE-7M5#222"])
        precondition(Set(result.files.compactMap { $0.sourceIdentity?.cardID }).count == 1)
        print("PASS: mixed-body photos on one card retain distinct per-file camera serials and one independent card identity")
        print("PASS: separate camera/card/batch IDs; card aliases; reconnect at a different path; clone/UUID conflict confirmation; missing UUID; real local folder separation; camera settings isolated from card names; immutable snapshots; source promotion; unknown-camera connection scope; corrupt store preservation")
        if CommandLine.arguments.contains("--render") {
            try await render(model: model, sourceID: 0, root: mixed, output: URL(filePath:"/tmp/minidit-identity-ui"))
        }
    }
    @MainActor static func render(model: AppModel, sourceID: Int, root: URL, output: URL) async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let host = NSHostingView(rootView: CardIdentityConfirmation(sourceID: sourceID, root: root).environment(model))
        let window = NSWindow(contentRect: NSRect(x:0,y:0,width:550,height:360), styleMask:[.titled],backing:.buffered,defer:false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for:.milliseconds(200)); host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds)!
        host.cacheDisplay(in:host.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appending(path:"confirm-card.png"))
        window.orderOut(nil)
        print("PASS: card identity confirmation layout")
        var card = ImportSourceIdentity(kind: .card, evidence: .volume, connectionID: UUID())
        card.cardName = "存储卡 01"; card.cardType = .sdFamily; card.capacity = 128_000_000_000
        card.cameraModel = "ILCE-7M5"; card.cameraSerial = "EXIF-SERIAL"
        var camera = ImportSourceIdentity(kind: .camera, evidence: .serial, connectionID: UUID())
        camera.cameraModel = "ILCE-7M5"; camera.cameraSerial = "MINIDIT-VIRTUAL-01"; camera.slot = 1
        for (name, identity) in [("card-source", card), ("camera-source", camera)] {
            let detail = NSHostingView(rootView: ImportSourceIdentityDetails(identity: identity).background(Theme.surface))
            let detailWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 280), styleMask: [.titled], backing: .buffered, defer: false)
            detailWindow.appearance = NSAppearance(named: .aqua)
            detailWindow.contentView = detail; detailWindow.setContentSize(detail.fittingSize)
            detailWindow.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); detail.layoutSubtreeIfNeeded()
            let bitmap = detail.bitmapImageRepForCachingDisplay(in: detail.bounds)!
            detail.cacheDisplay(in: detail.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: name + ".png"))
            detailWindow.orderOut(nil)
        }
        print("PASS: card and Wi-Fi source information layouts")
    }
}
