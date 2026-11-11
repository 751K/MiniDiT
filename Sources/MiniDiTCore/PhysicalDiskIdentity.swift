import Foundation

/// Runtime-only OS disk identifiers. Never persist BSD names: they may change on remount.
public struct PhysicalDiskIdentity: Sendable, Equatable {
    public var devices: Set<String>
    public var complete: Bool
    public init(devices: Set<String> = [], complete: Bool = false) {
        self.devices = devices; self.complete = complete && !devices.isEmpty
    }
    public enum Relationship: Sendable, Equatable { case shared, separate, unknown }
    public func relationship(to other: Self) -> Relationship {
        if !devices.isDisjoint(with: other.devices) { return .shared }
        return complete && other.complete ? .separate : .unknown
    }
}

/// Resolves only devices explicitly reported by diskutil's physical-disk list.
/// APFS containers, snapshots, disk images, RAID virtual disks and shares must not
/// become independent hardware merely because their volume identifiers differ.
public struct PhysicalDiskMap: Sendable {
    private var parent: [String: String] = [:]
    public init(physicalDisks: Data) {
        guard let list = (try? PropertyListSerialization.propertyList(from: physicalDisks, format: nil)) as? [String: Any],
              let whole = list["WholeDisks"] as? [String],
              let disks = list["AllDisksAndPartitions"] as? [[String: Any]] else { return }
        for disk in disks {
            guard let id = disk["DeviceIdentifier"] as? String, whole.contains(id) else { continue }
            add(disk, on: id)
        }
    }
    private mutating func add(_ entry: [String: Any], on whole: String) {
        if let id = entry["DeviceIdentifier"] as? String { parent[id] = whole }
        for partition in entry["Partitions"] as? [[String: Any]] ?? [] { add(partition, on: whole) }
    }
    public func identity(volumeInfo: Data) -> PhysicalDiskIdentity {
        guard let info = (try? PropertyListSerialization.propertyList(from: volumeInfo, format: nil)) as? [String: Any],
              info["RAIDMaster"] as? Bool != true else { return .init() }
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]], !stores.isEmpty {
            let identifiers = stores.compactMap { $0["APFSPhysicalStore"] as? String }
            let devices = identifiers.compactMap { parent[$0] }
            return .init(devices: Set(devices), complete: identifiers.count == stores.count && devices.count == stores.count)
        }
        // Missing APFS topology must never fall back to its synthesized whole disk.
        if (info["FilesystemType"] as? String)?.lowercased() == "apfs" || info["APFSContainerReference"] != nil { return .init() }
        guard let id = info["DeviceIdentifier"] as? String, let device = parent[id] else { return .init() }
        return .init(devices: [device], complete: true)
    }
}
