import Foundation
import Testing
import MiniDiTCore
import SonyRemoteKit

@Suite struct SourceIdentityTests {
    private func card(uuid: String? = "uuid-a", capacity: UInt64? = 128_000_000_000, root: String = "/Volumes/Card", label: String = "NO NAME") -> CardDescriptor {
        .init(kind: .volume, volumeUUID: uuid, capacity: capacity, label: label, root: root)
    }
    @Test func camerasRequireARealSerialAndNormalizePadding() {
        #expect(ImportSourceIdentity.bodyKey(model: "ilce-7m5", serial: "00012345") == "ILCE-7M5#12345")
        #expect(ImportSourceIdentity.bodyKey(model: "ILCE-7M5", serial: "12345") != ImportSourceIdentity.bodyKey(model: "ILCE-7M5", serial: "54321"))
        for serial in ["", "  ", "000000", "UNKNOWN", "N/A", "NONE", "NULL", "-"] {
            #expect(ImportSourceIdentity.bodyKey(model: "ILCE-7M5", serial: serial) == nil)
        }
        #expect(ImportSourceIdentity.bodyKey(model: "", serial: "123") == nil)
    }
    @Test func namesAndMountPathsNeverEstablishCardIdentity() {
        let first = CardIdentityProfile(name: "主机卡 01", descriptor: card())
        #expect(CardIdentityResolver.resolve(card(uuid: "uuid-b"), profiles: [first], otherOpenDescriptors: []) == .new)
        #expect(CardIdentityResolver.resolve(card(root: "/Volumes/Renamed", label: "RENAMED"), profiles: [first], otherOpenDescriptors: []) == .recognized(first.id))
        #expect(CardIdentityResolver.resolve(card(uuid: nil), profiles: [first], otherOpenDescriptors: []) == .confirmationRequired)
    }
    @Test func repeatedIdentifiersAndCapacityChangesNeedConfirmation() {
        let first = CardIdentityProfile(name: "主机卡", descriptor: card())
        #expect(CardIdentityResolver.resolve(card(capacity: 64_000_000_000), profiles: [first], otherOpenDescriptors: []) == .confirmationRequired)
        #expect(CardIdentityResolver.resolve(card(root: "/Volumes/Clone"), profiles: [first], otherOpenDescriptors: [card()]) == .confirmationRequired)
        let second = CardIdentityProfile(name: "副机卡", descriptor: card(root: "/Volumes/Clone"))
        #expect(CardIdentityResolver.resolve(card(), profiles: [first, second], otherOpenDescriptors: []) == .confirmationRequired)
    }
    @Test func directoriesOnOneDiskStaySeparateAndCanBeMoved() {
        let a = CardDescriptor(kind: .directory, volumeUUID: "disk", directoryID: "disk:100", capacity: nil, label: "Card", root: "/tmp/one/Card")
        let b = CardDescriptor(kind: .directory, volumeUUID: "disk", directoryID: "disk:200", capacity: nil, label: "Card", root: "/tmp/two/Card")
        let profile = CardIdentityProfile(name: "测试目录", descriptor: a)
        #expect(CardIdentityResolver.resolve(b, profiles: [profile], otherOpenDescriptors: [a]) == .new)
        var moved = a; moved.root = "/tmp/moved/Card"
        #expect(CardIdentityResolver.resolve(moved, profiles: [profile], otherOpenDescriptors: []) == .recognized(profile.id))
    }
    @Test func provenanceSeparatesCameraCardAndImportBatch() throws {
        var identity = ImportSourceIdentity(kind: .card, evidence: .volume, connectionID: UUID())
        identity.cameraID = "ILCE-7M5#12345"; identity.cameraSerial = "12345"
        identity.cardID = UUID(); identity.cardName = "主机卡 01"; identity.volumeUUID = "VOLUME-A"
        var file = ImportedFileRecord(id: "photo", projectID: UUID(), filename: "DSC00001.JPG", source: "主机卡 01")
        file.sourceIdentity = identity
        let first = ImportBatchRecord(files: [file], backupRequested: false, backupRoot: nil)
        let second = ImportBatchRecord(files: [file], backupRequested: false, backupRoot: nil)
        #expect(first.id != second.id)
        #expect(first.files[0].sourceIdentity?.cardID == second.files[0].sourceIdentity?.cardID)
        #expect(try JSONDecoder().decode(ImportBatchRecord.self, from: JSONEncoder().encode(first)) == first)
    }
    @Test func mediaTypeUsesReportedCardDataWithoutGuessingFromGenericTransport() {
        #expect(CardMediaType.detect(reportedTypes: ["SDXC"], interconnects: ["USB"]) == .sdFamily)
        #expect(CardMediaType.detect(reportedTypes: ["SDHC", "SDXC"], interconnects: []) == .sdFamily)
        #expect(CardMediaType.detect(reportedTypes: [], interconnects: ["Secure Digital"]) == .sdFamily)
        #expect(CardMediaType.detect(reportedTypes: ["microSDXC", "SDXC"], interconnects: []) == .microSD)
        #expect(CardMediaType.detect(reportedTypes: ["CFexpress Type A"], interconnects: ["USB"]) == .cfexpressA)
        #expect(CardMediaType.detect(reportedTypes: ["CFexpress", "CFexpress Type B"], interconnects: ["PCI-Express"]) == .cfexpressB)
        #expect(CardMediaType.detect(reportedTypes: ["CFexpress"], interconnects: []) == .cfexpress)
        for transport in ["USB", "NVMe", "PCI-Express", "Thunderbolt"] {
            #expect(CardMediaType.detect(reportedTypes: [], interconnects: [transport]) == nil)
        }
        for report in ["CFexpress Type A / SD Reader", "SD Card Reader", "128 GB", "MMC", "NO NAME"] {
            #expect(CardMediaType.detect(reportedTypes: [report], interconnects: ["Secure Digital"]) == nil)
        }
        #expect(CardMediaType.detect(reportedTypes: ["CFexpress Type A", "CFexpress Type B"], interconnects: []) == nil)
        #expect(CardMediaType.detect(reportedTypes: ["SDXC", "CFexpress Type B"], interconnects: []) == nil)
    }
    @Test func mediaTypeIsCapturedInImportSnapshot() throws {
        var identity = ImportSourceIdentity(kind: .card, evidence: .volume, connectionID: UUID())
        identity.cardType = .cfexpressB
        let encoded = try JSONEncoder().encode(identity)
        #expect(try JSONDecoder().decode(ImportSourceIdentity.self, from: encoded).cardType == .cfexpressB)
        let descriptor = CardDescriptor(kind: .volume, volumeUUID: "card", capacity: 128_000_000_000,
                                        cardType: .sdFamily, label: "Card", root: "/Volumes/Card")
        #expect(try JSONDecoder().decode(CardDescriptor.self, from: JSONEncoder().encode(descriptor)).cardType == .sdFamily)
    }
    @Test func exactHistoryDoesNotTreatAnUnknownBodyAsTheKnownCamera() {
        let record = ImportRecord(filename: "A.JPG", size: 100, dateRaw: "20261109T120000", camera: nil, path: "/work/A.JPG")
        let index = HistoryIndex([record])
        let item = CameraContentItem(id: 1, storageID: 1, filename: "A.JPG", format: PTPObjectFormat.jpeg,
                                     size: 100, captureDate: nil, captureDateRaw: "20261109T120000", width: 0, height: 0)
        #expect(index.find(item, camera: "ILCE-7M5#123", matchingIdentityExactly: true) == nil)
        #expect(index.find(item, camera: nil, matchingIdentityExactly: true) != nil)
    }
}
