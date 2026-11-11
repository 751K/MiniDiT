import AppKit
import SwiftUI
import Foundation
import MiniDiTCore
import SonyRemoteKit
@testable import MiniDiT

@MainActor final class DeliverySpy {
    var project = ResolveBridge.Project(id: "original-project", name: "原项目")
    var fcpCalls: [URL] = [], resolveCalls: [Data] = []
    var acceptsFCP = false, partialResolve = true, confirms = true, confirmationCalls = 0
    var premiereProject = PremiereBridge.Project(id: "premiere-original", name: "PR 原项目", path: "/PR.prproj")
    var premiereCalls: [Data] = [], partialPremiere = true, premiereConfirmations = 0
    var beforePremiere: (() -> Void)?
    var beforeSend: (() -> Void)?
    func services(directory: URL) -> VideoDeliveryServices {
        .init(identifyResolve: { self.project }, sendResolve: { payload, project in
            self.beforeSend?()
            self.resolveCalls.append(payload)
            try await Task.sleep(for: .milliseconds(40))
            let json = try JSONSerialization.jsonObject(with: payload) as! [String: Any]
            let events = json["events"] as! [[String: Any]]
            let paths = events.flatMap { ($0["clips"] as! [[String: Any]]).map { $0["path"] as! String } }
            let received = self.partialResolve ? Array(paths.prefix(1)) : paths
            return .init(project: project.name, projectID: project.id, imported: self.partialResolve ? 1 : paths.count - 1,
                proxies: 1, skipped: self.partialResolve ? 0 : 1, colored: 1, unmanaged: 0, timecodes: 1,
                timecodeWarnings: [], metadataWarnings: [], failedPaths: paths.filter { !received.contains($0) }, receivedPaths: received)
        }, openFCP: { url in
            self.fcpCalls.append(url)
            try await Task.sleep(for: .milliseconds(40))
            if !self.acceptsFCP { throw VideoDelivery.Failure("Final Cut Pro 未能打开交接文件。") }
        }, confirmResolve: { _ in self.confirmationCalls += 1; return self.confirms }, identifyPremiere: { self.premiereProject }, sendPremiere: { payload, project in
            self.beforePremiere?(); self.premiereCalls.append(payload)
            try await Task.sleep(for: .milliseconds(40))
            let handoff = try JSONDecoder().decode(PremiereHandoff.self, from: payload)
            let paths = handoff.groups.flatMap(\.clips).map(\.path)
            let received = self.partialPremiere ? Array(paths.prefix(1)) : paths
            return .init(project: project.name, projectID: project.id, imported: self.partialPremiere ? 1 : paths.count - 1, skipped: self.partialPremiere ? 0 : 1, proxies: 1, receivedPaths: received, failedPaths: paths.filter { !received.contains($0) }, warnings: [])
        }, confirmPremiere: { _ in self.premiereConfirmations += 1; return self.confirms }, fcpDirectory: directory)
    }
}

@main struct VideoDeliveryChecks {
    @MainActor static func main() async throws {
        let app = NSApplication.shared
        precondition(Bundle.main.bundleIdentifier == nil)
        let defaults = UserDefaults.standard, domain = ProcessInfo.processInfo.processName
        let previous = defaults.persistentDomain(forName: domain)
        defer { if let previous { defaults.setPersistentDomain(previous, forName: domain) } else { defaults.removePersistentDomain(forName: domain) } }
        defaults.removePersistentDomain(forName: domain)
        let fm = FileManager.default, root = fm.temporaryDirectory.appending(path: "minidit-delivery-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let oldHistory = ImportHistory.shared; ImportHistory.shared = ImportHistory(directory: root.appending(path: "history"))
        defer { ImportHistory.shared = oldHistory }
        let card = root.appending(path: "card"), work = root.appending(path: "work")
        for path in ["PRIVATE/M4ROOT/CLIP", "PRIVATE/M4ROOT/SUB"] { try fm.createDirectory(at: card.appending(path: path), withIntermediateDirectories: true) }
        let xml = #"<NonRealTimeMeta><LtcChangeTable tcFps="25"><LtcChange frameCount="0" value="00000001"/></LtcChangeTable><Duration value="250"/><VideoFrame formatFps="25p" pixel="1920" numOfVerticalLine="1080"/></NonRealTimeMeta>"#
        for name in ["C0001", "C0002"] {
            try Data(repeating: 0x42, count: 4096).write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/" + name + ".MP4"))
            try Data(xml.utf8).write(to: card.appending(path: "PRIVATE/M4ROOT/CLIP/" + name + "M01.XML"))
            try Data(repeating: 0x43, count: 1024).write(to: card.appending(path: "PRIVATE/M4ROOT/SUB/" + name + "S03.MP4"))
        }
        let journalURL = root.appending(path: "journal.sqlite")
        let model = AppModel(startServices: false, journalURL: journalURL)
        model.sessionRecordURL = root.appending(path: "projects.json"); model.sessions = []
        model.captureOneMode = .off; model.openAfterImport = .none; model.deleteAfterImport = false
        model.sendToFCP = true; model.sendToResolve = true; model.sendToPremiere = true; model.fcpLogProcessing = true; model.resolveColorSpace = true
        model.autoRefresh = false; model.onlyNew = false; model.importContent = .videos; model.mediaFilter = .init()
        model.photoFolderLayout = .session; model.videoFolderLayout = .session; model.splitVideoByRoll = false
        model.destination = work; model.videoDestination = work; model.importProxies = true
        model.backupEnabled = false; model.sourceKind = .card; model.cardRoot = card; model.connectedName = "隔离检查卡"
        model.library = LocalCardLibrary(root: card)
        let spy = DeliverySpy(); model.videoDeliveryServices = spy.services(directory: root.appending(path: "fcp"))
        await model.loadAll()
        let project = model.createSession(day: "20261110", event: "发送检查")
        model.selectAll(in: Set(model.days.map(\.id))); precondition(model.selectedFiles().count == 2)
        model.beginImport(); precondition(model.importTask != nil)
        // These changes apply to the next import, not this task or any retry.
        model.sendToFCP = false; model.sendToResolve = false; model.sendToPremiere = false; model.fcpLogProcessing = false; model.resolveColorSpace = false
        try await wait { model.importTask == nil && model.videoDeliveryTask == nil }
        var batch = model.importJournal.records(for: project.id).first!
        precondition(batch.savedCount == 2 && batch.files.flatMap(\.assets).count == 6)
        let fcp = batch.videoDeliveries!.first { $0.software == .finalCutPro }!
        let resolve = batch.videoDeliveries!.first { $0.software == .resolve }!
        precondition(fcp.state == .failed && resolve.state == .failed)
        precondition(resolve.resolveProjectID == spy.project.id && resolve.failedPaths.count == 1)
        precondition(spy.fcpCalls.count == 1 && spy.resolveCalls.count == 1 && spy.confirmationCalls == 0)
        let premiere = batch.videoDeliveries!.first { $0.software == .premiere }!
        precondition(premiere.state == .failed && premiere.premiereProjectID == "premiere-original" && premiere.failedPaths.count == 1)
        precondition(spy.premiereCalls.count == 1 && spy.premiereConfirmations == 0)
        let premierePayload = try JSONDecoder().decode(PremiereHandoff.self, from: premiere.payload)
        precondition(premierePayload.groups[0].binPath[0] == project.name && premierePayload.groups[0].binPath.count == 2)
        precondition(premierePayload.groups.flatMap(\.clips).allSatisfy { $0.proxy != nil })
        let frozenXML = fcp.payload, frozenResolve = resolve.payload, document = spy.fcpCalls[0]
        let json = try JSONSerialization.jsonObject(with: frozenResolve) as! [String: Any]
        precondition(json["color"] as? Bool == true)
        let xmlString = String(decoding: frozenXML, as: UTF8.self)
        precondition(xmlString.contains(" uid=\"") && xmlString.contains("proxy-media") && xmlString.contains("tcStart="))
        let originalFiles = batch.files, originalReports = batch.reports
        if CommandLine.arguments.contains("--render") { try await render(model, project: project, app: app, name: "failed") }
        // No original card remains. Changing local XML must not rewrite the frozen handoff request.
        try fm.removeItem(at: card); model.library = nil; model.phase = .idle
        for file in batch.files.flatMap(\.assets) where file.kind == .metadata { try Data("<NonRealTimeMeta/>".utf8).write(to: URL(filePath: file.copies[0].path)) }
        model.importJournal = ImportJournalStore(url: journalURL)
        precondition(model.videoDeliveries(in: batch.id).first { $0.id == resolve.id }?.payload == frozenResolve)
        // Binding must be saved before any external operation.
        spy.beforeSend = { precondition(model.videoDeliveries(in: batch.id).first { $0.id == resolve.id }?.resolveProjectID == "original-project") }
        spy.project = .init(id: "other-project", name: "另一项目")
        model.retryVideoDelivery(batchID: batch.id, id: resolve.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.resolveCalls.count == 1 && model.videoDeliveries(in: batch.id).first { $0.id == resolve.id }!.message.contains("原项目"))
        spy.project = .init(id: "original-project", name: "原项目"); spy.partialResolve = false
        // Completion of an old batch must not replace the new batch's summary.
        model.deliveryID = UUID(); model.deliveryMessages = ["新批次": "等待接收"]; model.deliveryFailures = []
        model.retryVideoDelivery(batchID: batch.id, id: resolve.id)
        model.retryVideoDelivery(batchID: batch.id, id: resolve.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.resolveCalls.count == 2 && spy.resolveCalls.allSatisfy { $0 == frozenResolve })
        precondition(model.videoDeliveries(in: batch.id).first { $0.id == resolve.id }?.state == .completed)
        precondition(model.deliveryMessages == ["新批次": "等待接收"] && model.deliveryFailures.isEmpty)
        spy.acceptsFCP = true
        model.retryVideoDelivery(batchID: batch.id, id: fcp.id); model.retryVideoDelivery(batchID: batch.id, id: fcp.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.fcpCalls == [document, document])
        let writtenXML = try Data(contentsOf: document); precondition(writtenXML == frozenXML)
        precondition(model.videoDeliveries(in: batch.id).first { $0.id == fcp.id }?.state == .awaitingConfirmation)
        model.retryVideoDelivery(batchID: batch.id, id: fcp.id)
        precondition(model.videoDeliveryTask == nil && spy.fcpCalls.count == 2)
        spy.premiereProject = .init(id: "wrong-pr", name: "其他 PR 项目", path: "/other.prproj")
        model.retryVideoDelivery(batchID: batch.id, id: premiere.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.premiereCalls.count == 1)
        spy.premiereProject = .init(id: "premiere-original", name: "PR 原项目", path: "/PR.prproj")
        spy.partialPremiere = false
        spy.beforePremiere = { precondition(model.videoDeliveries(in: batch.id).first { $0.id == premiere.id }?.premiereProjectID == "premiere-original") }
        model.retryVideoDelivery(batchID: batch.id, id: premiere.id); model.retryVideoDelivery(batchID: batch.id, id: premiere.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.premiereCalls == [premiere.payload, premiere.payload])
        precondition(model.videoDeliveries(in: batch.id).first { $0.id == premiere.id }?.state == .completed)
        precondition(model.deliveryMessages == ["新批次": "等待接收"])
        batch = model.importJournal.records(for: project.id).first!
        precondition(batch.files == originalFiles && batch.reports == originalReports && batch.savedCount == 2)
        if CommandLine.arguments.contains("--render") { try await render(model, project: project, app: app, name: "sent") }
        print("PASS: actual isolated card import persists both frozen software requests; failed sends retain original/proxy/XML; retry after card removal and restart reuses bytes/document, binds original Resolve project, rejects switches and duplicate clicks, and isolates old-batch receipts")
        // Missing proxy must stop a retry before any external launch/send.
        let proxy = resolve.files.first { $0.path.contains("/Proxy/") }!
        try fm.removeItem(at: URL(filePath: proxy.path))
        precondition(model.importJournal.update(batch.id) { item in
            var records = item.videoDeliveries!; let i = records.firstIndex { $0.id == resolve.id }!
            records[i].state = .failed; item.videoDeliveries = records
        })
        model.retryVideoDelivery(batchID: batch.id, id: resolve.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.resolveCalls.count == 2)
        precondition(model.videoDeliveries(in: batch.id).first { $0.id == resolve.id }!.message.contains("文件无法访问"))
        // Recovery never silently relaunches FCP or guesses whether it accepted a document.
        precondition(model.importJournal.update(batch.id) { item in
            var records = item.videoDeliveries!
            for i in records.indices { records[i].state = .sending }; item.videoDeliveries = records
        })
        model.importJournal = ImportJournalStore(url: journalURL)
        let recovered = model.videoDeliveries(in: batch.id)
        precondition(recovered.first { $0.software == .finalCutPro }?.state == .uncertain)
        precondition(recovered.first { $0.software == .finalCutPro }?.canRetry == false)
        precondition(recovered.first { $0.software == .resolve }?.state == .interrupted)
        precondition(model.videoDeliveryTask == nil)
        precondition(recovered.first { $0.software == .premiere }?.state == .interrupted && recovered.first { $0.software == .premiere }?.canRetry == true)
        // A failure before target identification requires explicit selection confirmation on retry.
        var unbound = resolve; unbound.id = UUID(); unbound.resolveProjectID = nil; unbound.resolveProjectName = nil
        unbound.state = .failed; unbound.files = []
        var newBatch = ImportBatchRecord(files: [], backupRequested: false, backupRoot: nil, state: .completed)
        newBatch.videoDeliveries = [unbound]; precondition(model.importJournal.begin(newBatch))
        spy.confirms = false
        model.retryVideoDelivery(batchID: newBatch.id, id: unbound.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.confirmationCalls == 1 && spy.resolveCalls.count == 2)
        precondition(model.videoDeliveries(in: newBatch.id).first?.resolveProjectID == nil)
        spy.confirms = true; spy.beforeSend = nil
        model.retryVideoDelivery(batchID: newBatch.id, id: unbound.id)
        try await wait { model.videoDeliveryTask == nil }
        precondition(spy.confirmationCalls == 2 && spy.resolveCalls.count == 3)
        precondition(model.videoDeliveries(in: newBatch.id).first?.state == .completed)
        // A changed handoff document is preserved, never silently overwritten.
        try Data("user edited".utf8).write(to: document)
        do { _ = try FCPXMLWriter.prepare(id: fcp.id, payload: frozenXML, directory: document.deletingLastPathComponent()); fatalError("modified XML overwritten") }
        catch { let edited = try Data(contentsOf: document); precondition(edited == Data("user edited".utf8)) }
        print("PASS: missing files block external calls; interrupted FCP stays uncertain without automatic resend; Resolve resumes from original target; unbound retry honors explicit confirmation; edited handoff XML is preserved")
        let script = root.appending(path: "resolve.py"); try ResolveBridge.script.write(to: script, atomically: true, encoding: .utf8)
        let python = Process(); python.executableURL = URL(filePath: "/usr/bin/python3")
        python.arguments = [URL(filePath: #filePath).deletingLastPathComponent().appending(path: "ResolveDeliveryChecks.py").path, script.path, root.path]
        try python.run(); python.waitUntilExit(); precondition(python.terminationStatus == 0)
    }
    @MainActor static func wait(_ done: () -> Bool) async throws {
        for _ in 0..<1500 { if done() { return }; try await Task.sleep(for: .milliseconds(20)) }
        fatalError("Delivery timed out")
    }
    @MainActor static func render(_ model: AppModel, project: ShootSession, app: NSApplication, name: String) async throws {
        let output = URL(filePath: "/tmp/minidit-delivery-ui")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for dark in [false, true] {
            let host = NSHostingView(rootView: ProjectImportResults(project: project).environment(model).preferredColorScheme(dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 1000, height: 720), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.contentView = host; window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(400)); host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appending(path: name + (dark ? "-dark" : "") + ".png"))
            window.orderOut(nil)
        }
    }
}
