import Foundation
import Security
import SonyRemoteKit

/// 相机的访问身份验证账号存在钥匙串里，按相机的 SSH 指纹保存（家里路由器给相机的 IP 可能会变）。
enum CredentialStore {
    private static let service = "com.kong.SonyImport.camera-ssh"

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(_ account: String) -> SSHCredentials? {
        var q = base(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(SSHCredentials.self, from: data)
    }

    static func save(_ creds: SSHCredentials, _ account: String) {
        guard let data = try? JSONEncoder().encode(creds) else { return }
        let attrs: [String: Any] = [kSecValueData as String: data,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(base(account) as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            SecItemAdd(base(account).merging(attrs) { $1 } as CFDictionary, nil)
        }
    }

    static func delete(_ account: String) { SecItemDelete(base(account) as CFDictionary) }
}

/// 连过的相机（地址可能变，用指纹认人）。
struct KnownCamera: Codable, Hashable, Identifiable {
    var fingerprint: String     // SSH 指纹；直连（无验证）的相机用 "direct:<ip>"
    var host: String
    var name: String
    var lastSeen: Date
    var id: String { fingerprint }

    static let key = "knownCameras"

    static func load() -> [KnownCamera] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KnownCamera].self, from: d)) ?? []
    }

    static func remember(_ cam: KnownCamera) {
        var all = load().filter { $0.fingerprint != cam.fingerprint }
        all.insert(cam, at: 0)
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func forget(_ fingerprint: String) {
        let all = load().filter { $0.fingerprint != fingerprint }
        if let d = try? JSONEncoder().encode(all) { UserDefaults.standard.set(d, forKey: key) }
        CredentialStore.delete(fingerprint)
    }
}

enum HostIdentityStore {
    static var identity: PTPIPHostIdentity {
        let key = "ptpipGUID"
        let guid: [UInt8]
        if let saved = UserDefaults.standard.data(forKey: key), saved.count == 16 {
            guid = [UInt8](saved)
        } else {
            guid = withUnsafeBytes(of: UUID().uuid) { Array($0) }
            UserDefaults.standard.set(Data(guid), forKey: key)
        }
        return PTPIPHostIdentity(guid: guid, friendlyName: Host.current().localizedName ?? "Mac")
    }
}
