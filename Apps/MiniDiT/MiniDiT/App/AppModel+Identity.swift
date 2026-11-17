import Foundation
import MiniDiTCore
import SonyRemoteKit

extension AppModel {
    func cardRoot(for id: Int) -> URL? {
        id == Self.primarySource ? (sourceKind == .card ? cardRoot : nil) : extra(id)?.root
    }
    func connectionID(for id: Int) -> UUID {
        id == Self.primarySource ? primaryConnectionID : extra(id)?.connectionID ?? primaryConnectionID
    }
    func prepareSourceIdentities() {
        let roots = openSources.compactMap { $0.library as? LocalCardLibrary }.map(\.root)
        sourceIdentities.retainOpen(roots)
        for root in roots { _ = sourceIdentities.register(root: root) }
    }
    func bodyIdentity(for id: Int) -> String? {
        let raw = id == Self.primarySource ? cameraID : extra(id)?.cameraID
        if isWiFiCamera(id), let raw {
            let pieces = raw.split(separator: "#", maxSplits: 1).map(String.init)
            if pieces.count == 2 { return ImportSourceIdentity.bodyKey(model: pieces[0], serial: pieces[1]) }
        }
        return cardCameraKeys[id]
    }
    func sourceIdentitySnapshot(_ id: Int, slot: UInt32? = nil) -> ImportSourceIdentity {
        let body = bodyIdentity(for: id)
        let cameraInfo = id == Self.primarySource ? deviceInfo : extra(id)?.deviceInfo
        let isCard = cardRoot(for: id) != nil
        let root = cardRoot(for: id)
        let binding = root.flatMap { sourceIdentities.binding(for: $0) }
        var snapshot = ImportSourceIdentity(kind: isCard ? (binding?.descriptor.kind == .directory ? .directory : .card) : .camera,
                                            evidence: .connection, connectionID: connectionID(for: id))
        // A card can contain media from several bodies. Its first photo is only
        // a browsing hint; per-file camera metadata is captured during import.
        snapshot.cameraID = isCard ? nil : body
        snapshot.cameraModel = isCard ? nil : cameraInfo?.model
        snapshot.cameraSerial = isCard || body == nil ? nil : cameraInfo?.serialNumber
        if let root, let binding {
            snapshot.cardID = binding.needsConfirmation ? nil : binding.profileID
            snapshot.cardName = sourceIdentities.name(for: root)
            snapshot.volumeUUID = binding.descriptor.volumeUUID
            snapshot.capacity = binding.descriptor.capacity
            snapshot.cardType = binding.descriptor.cardType
            if !binding.needsConfirmation, binding.profileID != nil {
                snapshot.evidence = binding.confirmed ? .userConfirmed : binding.descriptor.kind == .directory ? .directory : .volume
            }
        } else {
            snapshot.slot = slot
            snapshot.evidence = body == nil ? .connection : .serial
        }
        return snapshot
    }
    func identityDetail(_ id: Int) -> String {
        let identity = sourceIdentitySnapshot(id)
        if let root = cardRoot(for: id), let binding = sourceIdentities.binding(for: root) {
            var parts = [binding.descriptor.kind == .directory ? "本地目录" : "读卡器"]
            if let size = binding.descriptor.capacity { parts.append(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)) }
            if let model = cardCameraNames[id] { parts.append(model) }
            if binding.needsConfirmation { parts.append("身份待确认") }
            return parts.joined(separator: " · ")
        }
        let host = id == Self.primarySource ? connectedHost : extra(id)?.camera?.host
        let serial = identity.cameraSerial.map { String($0.suffix(4)) } ?? "序列号未知"
        let link = id == Self.primarySource && lastUSBCamera != nil ? "USB" : "Wi-Fi"
        return [link, host, serial].compactMap { $0 }.joined(separator: " · ")
    }
    func importDeviceName(_ id: Int) -> String {
        if cardRoot(for: id) != nil { return sourceName(id) }
        let identity = sourceIdentitySnapshot(id)
        let name = sourceName(id)
        return identity.cameraSerial.map { name + "（" + $0.suffix(4) + "）" } ?? name + "（序列号未知）"
    }
    func cardNeedsConfirmation(_ id: Int) -> Bool {
        cardRoot(for: id).flatMap { sourceIdentities.binding(for: $0)?.needsConfirmation } ?? false
    }
}
