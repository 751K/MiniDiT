import Foundation
import MiniDiTCore
import Observation

/// Card names and identities have their own store, never the camera profile store.
@MainActor @Observable
final class SourceIdentityStore {
    struct Binding: Equatable {
        var descriptor: CardDescriptor
        var profileID: UUID?
        var confirmed = false
        var needsConfirmation = false
        var temporaryName: String?
    }
    private(set) var profiles: [CardIdentityProfile] = []
    private(set) var bindings: [String: Binding] = [:]
    private(set) var errorMessage: String?
    private let url: URL
    private var readable = true

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "\(LegacyMigration.supportFolder)/card-identities.json")
    }
    init(url: URL) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do { profiles = try JSONDecoder().decode([CardIdentityProfile].self, from: Data(contentsOf: url)) }
        catch { readable = false; errorMessage = String(localized: "无法读取存储卡档案：\(error.localizedDescription)") }
    }

    static func describe(_ root: URL) -> CardDescriptor {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let values = try? root.resourceValues(forKeys: [.volumeURLKey, .volumeUUIDStringKey, .volumeNameKey, .volumeTotalCapacityKey])
        let volume = values?.volume?.resolvingSymlinksInPath().standardizedFileURL
        let isVolume = volume?.path == root.path
        let attrs = try? FileManager.default.attributesOfItem(atPath: root.path)
        let inode = (attrs?[.systemFileNumber] as? NSNumber)?.stringValue
        let directoryID: String? = values?.volumeUUIDString.flatMap { uuid in inode.map { uuid + ":" + $0 } }
        return .init(kind: isVolume ? .volume : .directory, volumeUUID: values?.volumeUUIDString,
                     directoryID: isVolume ? nil : directoryID,
                     capacity: isVolume ? values?.volumeTotalCapacity.map { UInt64(max(0, $0)) } : nil,
                     cardType: isVolume ? CardMediaProbe.type(at: root) : nil,
                     label: isVolume ? (values?.volumeName ?? root.lastPathComponent) : root.lastPathComponent, root: root.path)
    }

    func register(root: URL, descriptor supplied: CardDescriptor? = nil) -> Binding {
        let path = Self.path(root)
        if let binding = bindings[path] { return binding }
        let descriptor = supplied ?? Self.describe(root)
        let other = Array(bindings.values.map(\.descriptor))
        var binding = Binding(descriptor: descriptor)
        switch CardIdentityResolver.resolve(descriptor, profiles: profiles, otherOpenDescriptors: other) {
        case .new:
            let name = descriptor.kind == .directory ? descriptor.label : String(format: "存储卡 %02d", profiles.filter { $0.descriptor.kind == .volume }.count + 1)
            let profile = CardIdentityProfile(name: name, descriptor: descriptor)
            if save(profiles + [profile]) { binding.profileID = profile.id }
            else { binding.needsConfirmation = true }
        case .recognized(let id): binding.profileID = id
        case .confirmationRequired: binding.needsConfirmation = true
        }
        // A second mounted volume with the same identifier makes both automatic
        // associations uncertain. Explicit confirmations remain connection scoped.
        if let key = descriptor.matchKey {
            for (otherPath, var existing) in bindings where existing.descriptor.matchKey == key && otherPath != path && !existing.confirmed {
                existing.needsConfirmation = true
                existing.profileID = nil
                bindings[otherPath] = existing
            }
        }
        bindings[path] = binding
        return binding
    }

    func binding(for root: URL) -> Binding? { bindings[Self.path(root)] }
    func name(for root: URL) -> String {
        guard let binding = binding(for: root) else { return root.lastPathComponent }
        if let id = binding.profileID, let profile = profiles.first(where: { $0.id == id }) { return profile.name }
        return binding.temporaryName ?? binding.descriptor.label
    }
    func rename(root: URL, to name: String) {
        let path = Self.path(root)
        guard var binding = bindings[path] else { return }
        if let id = binding.profileID, let index = profiles.firstIndex(where: { $0.id == id }) {
            var next = profiles; next[index].name = name.isEmpty ? binding.descriptor.label : name
            _ = save(next)
        } else {
            binding.temporaryName = name.isEmpty ? nil : name
            bindings[path] = binding
        }
    }
    func confirm(root: URL, existing id: UUID?, name: String) -> Bool {
        let path = Self.path(root)
        guard var binding = bindings[path], !bindings.contains(where: {
            $0.key != path && $0.value.profileID == id && id != nil && !$0.value.needsConfirmation
        }) else { return false }
        if let id, !profiles.contains(where: { $0.id == id && $0.descriptor.kind == binding.descriptor.kind }) { return false }
        var next = profiles
        let profileID: UUID
        if let id, let index = next.firstIndex(where: { $0.id == id }) {
            // A user-confirmed reassociation updates the observed descriptor. Other
            // profiles with the same UUID stay separate and force confirmation later.
            profileID = id; next[index].descriptor = binding.descriptor
            if !name.isEmpty { next[index].name = name }
        } else {
            let profile = CardIdentityProfile(name: name.isEmpty ? binding.descriptor.label : name, descriptor: binding.descriptor)
            profileID = profile.id; next.append(profile)
        }
        guard save(next) else { return false }
        binding.profileID = profileID; binding.confirmed = true; binding.needsConfirmation = false
        bindings[path] = binding
        return true
    }
    func retainOpen(_ roots: [URL]) {
        let paths = Set(roots.map(Self.path))
        bindings = bindings.filter { paths.contains($0.key) }
    }
    private func save(_ next: [CardIdentityProfile]) -> Bool {
        guard readable else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: url, options: .atomic)
            profiles = next; errorMessage = nil; return true
        } catch { errorMessage = String(localized: "存储卡档案未能保存：\(error.localizedDescription)"); return false }
    }
    private static func path(_ root: URL) -> String { root.resolvingSymlinksInPath().standardizedFileURL.path }
}
