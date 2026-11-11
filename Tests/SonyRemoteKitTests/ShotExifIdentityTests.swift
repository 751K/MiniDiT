import Foundation
import ImageIO
import Testing
@testable import SonyRemoteKit

@Suite struct ShotExifIdentityTests {
    @Test func identityMetadataDoesNotRequireExposureFields() throws {
        let properties: [CFString: Any] = [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "ILCE-7M5"],
                                          kCGImagePropertyExifDictionary: [kCGImagePropertyExifBodySerialNumber: "0012345"]]
        let value = try #require(ShotExif(properties: properties))
        #expect(value.camera == "ILCE-7M5" && value.serial == "0012345")
        #expect(value.fNumber == nil && value.exposureTime == nil)
    }
    @Test func emptyMetadataDoesNotInventAnIdentity() {
        #expect(ShotExif(properties: [:]) == nil)
        #expect(ShotExif(properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "  "]]) == nil)
    }
}
