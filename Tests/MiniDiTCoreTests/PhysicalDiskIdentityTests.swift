import Foundation
import Testing
@testable import MiniDiTCore

struct PhysicalDiskIdentityTests {
    private func data(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    private func map() throws -> PhysicalDiskMap {
        PhysicalDiskMap(physicalDisks: try data([
            "WholeDisks": ["disk0", "disk6"],
            "AllDisksAndPartitions": [
                ["DeviceIdentifier": "disk0", "Partitions": [["DeviceIdentifier": "disk0s2"], ["DeviceIdentifier": "disk0s3"]]],
                ["DeviceIdentifier": "disk6", "Partitions": [["DeviceIdentifier": "disk6s2"]]]
            ]
        ]))
    }
    private func apfs(_ device: String, stores: [String]) throws -> Data {
        try data(["DeviceIdentifier": device, "FilesystemType": "apfs", "ParentWholeDisk": "disk99",
                  "APFSPhysicalStores": stores.map { ["APFSPhysicalStore": $0] }])
    }
    @Test func apfsVolumesSnapshotsAndSeparateContainersOnSameDisk() throws {
        let map = try map()
        let system = map.identity(volumeInfo: try apfs("disk3s1s1", stores: ["disk0s2"]))
        let data = map.identity(volumeInfo: try apfs("disk3s5", stores: ["disk0s2"]))
        let otherContainer = map.identity(volumeInfo: try apfs("disk4s1", stores: ["disk0s3"]))
        let usb = map.identity(volumeInfo: try apfs("disk7s1", stores: ["disk6s2"]))
        #expect(system.devices == ["disk0"] && system.complete)
        #expect(system.relationship(to: data) == .shared)
        #expect(system.relationship(to: otherContainer) == .shared)
        #expect(system.relationship(to: usb) == .separate)
    }
    @Test func multipleStoresDetectAnySharedDiskAndIncompleteTopologyIsUnknown() throws {
        let map = try map()
        let fusion = map.identity(volumeInfo: try apfs("disk8s1", stores: ["disk0s2", "disk6s2"]))
        let usb = map.identity(volumeInfo: try apfs("disk7s1", stores: ["disk6s2"]))
        #expect(fusion.devices == ["disk0", "disk6"] && fusion.complete)
        #expect(fusion.relationship(to: usb) == .shared)
        let incomplete = map.identity(volumeInfo: try apfs("disk9s1", stores: ["disk0s2", "disk20s2"]))
        #expect(!incomplete.complete)
        #expect(incomplete.relationship(to: usb) == .unknown)
        #expect(incomplete.relationship(to: fusion) == .shared)
        let empty = map.identity(volumeInfo: try apfs("disk9s1", stores: []))
        #expect(empty.relationship(to: usb) == .unknown)
    }
    @Test func ordinaryPartitionsResolveButImagesSharesRaidAndMalformedDataDoNot() throws {
        let map = try map()
        let exfat = map.identity(volumeInfo: try data(["DeviceIdentifier": "disk6s2", "FilesystemType": "exfat"]))
        let whole = map.identity(volumeInfo: try data(["DeviceIdentifier": "disk6", "WholeDisk": true]))
        #expect(exfat.complete && exfat.relationship(to: whole) == .shared)
        for info: [String: Any] in [
            ["DeviceIdentifier": "disk10s1", "ParentWholeDisk": "disk10"],
            ["FilesystemType": "smbfs"],
            ["DeviceIdentifier": "disk6s2", "RAIDMaster": true],
            ["DeviceIdentifier": "disk6s2", "FilesystemType": "apfs"],
            ["APFSPhysicalStores": [["UnexpectedField": "disk6s2"]]]
        ] {
            #expect(!map.identity(volumeInfo: try data(info)).complete)
        }
        #expect(!map.identity(volumeInfo: Data("invalid".utf8)).complete)
        #expect(!PhysicalDiskMap(physicalDisks: Data()).identity(volumeInfo: try data(["DeviceIdentifier": "disk6s2"])).complete)
    }
}
