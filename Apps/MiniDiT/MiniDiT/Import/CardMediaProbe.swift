import DiskArbitration
import Foundation
import IOKit
import MiniDiTCore

/// Reads only the mounted volume's own I/O provider chain. Reader product names
/// can advertise several card formats and cannot establish the inserted type.
enum CardMediaProbe {
    static func type(at root: URL) -> CardMediaType? {
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, root as CFURL) else { return nil }
        var entry = DADiskCopyIOMedia(disk)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var types: [String] = [], protocols: [String] = []
        for _ in 0..<16 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let values = properties?.takeRetainedValue() as? [String: Any] {
                if let card = values["Card Characteristics"] as? [String: Any], let type = card["Card Type"] as? String {
                    types.append(type)
                }
                if let protocolInfo = values["Protocol Characteristics"] as? [String: Any],
                   let interconnect = protocolInfo["Physical Interconnect"] as? String {
                    protocols.append(interconnect)
                }
            }
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
            IOObjectRelease(entry)
            entry = parent
        }
        return CardMediaType.detect(reportedTypes: types, interconnects: protocols)
    }
}
