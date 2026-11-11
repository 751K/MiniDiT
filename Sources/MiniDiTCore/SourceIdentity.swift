import Foundation

public struct ImportSourceIdentity: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case camera, card, directory }
    public enum Evidence: String, Codable, Sendable { case serial, volume, directory, userConfirmed, connection }
    public var kind: Kind
    public var evidence: Evidence
    public var connectionID: UUID
    public var cameraID: String?
    public var cameraModel: String?
    public var cameraSerial: String?
    public var cardID: UUID?
    public var cardName: String?
    public var volumeUUID: String?
    public var capacity: UInt64?
    public var cardType: CardMediaType?
    public var slot: UInt32?
    public init(kind: Kind, evidence: Evidence, connectionID: UUID) {
        self.kind = kind; self.evidence = evidence; self.connectionID = connectionID
    }

    public static func bodyKey(model: String, serial: String) -> String? {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let raw = serial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !raw.isEmpty,
              !["UNKNOWN", "N/A", "NONE", "NULL", "-"].contains(raw.uppercased()) else { return nil }
        let normalized = String(raw.drop { $0 == "0" }).uppercased()
        return normalized.isEmpty ? nil : model + "#" + normalized
    }
}

public struct CardDescriptor: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case volume, directory }
    public var kind: Kind
    public var volumeUUID: String?
    public var directoryID: String?
    public var capacity: UInt64?
    public var cardType: CardMediaType?
    public var label: String
    public var root: String
    public init(kind: Kind, volumeUUID: String?, directoryID: String? = nil, capacity: UInt64?, cardType: CardMediaType? = nil, label: String, root: String) {
        self.kind = kind; self.volumeUUID = volumeUUID?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if self.volumeUUID?.isEmpty == true || self.volumeUUID?.replacingOccurrences(of: "-", with: "").allSatisfy({ $0 == "0" }) == true { self.volumeUUID = nil }
        self.directoryID = directoryID?.uppercased(); self.capacity = capacity; self.cardType = cardType; self.label = label; self.root = root
    }
    public var matchKey: String? {
        switch kind {
        case .volume: volumeUUID.map { "VOLUME:" + $0 }
        case .directory: directoryID.map { "DIRECTORY:" + $0 }
        }
    }
}

public struct CardIdentityProfile: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var descriptor: CardDescriptor
    public init(id: UUID = UUID(), name: String, descriptor: CardDescriptor) {
        self.id = id; self.name = name; self.descriptor = descriptor
    }
}

public enum CardIdentityMatch: Equatable, Sendable {
    case new
    case recognized(UUID)
    case confirmationRequired
}

public enum CardIdentityResolver {
    /// Names and paths never establish a card identity. Duplicate UUIDs, changed
    /// capacities and missing identifiers must be confirmed by the user.
    public static func resolve(_ descriptor: CardDescriptor, profiles: [CardIdentityProfile],
                               otherOpenDescriptors: [CardDescriptor]) -> CardIdentityMatch {
        guard let key = descriptor.matchKey else { return .confirmationRequired }
        if otherOpenDescriptors.contains(where: { $0.matchKey == key && $0.root != descriptor.root }) {
            return .confirmationRequired
        }
        let matches = profiles.filter { $0.descriptor.matchKey == key }
        guard !matches.isEmpty else { return .new }
        guard matches.count == 1, let match = matches.first,
              match.descriptor.capacity == descriptor.capacity else { return .confirmationRequired }
        return .recognized(match.id)
    }
}
