import Foundation
import Security
import SonyRemoteKit

/// 相机的访问身份验证账号存在钥匙串里，按相机的 SSH 指纹保存（家里路由器给相机的 IP 可能会变）。
enum CredentialStore {
    private static let service = "com.kong.MiniDiT.camera-ssh"
    /// 改名前（SonyImport）用的服务名：读不到新的时找旧的，找到就搬到新服务名下。
    private static let legacyService = "com.kong.SonyImport.camera-ssh"

    private static func base(_ account: String, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load(_ account: String) -> SSHCredentials? {
        if let creds = read(account, service: service) { return creds }
        guard let creds = read(account, service: legacyService) else { return nil }
        save(creds, account)
        SecItemDelete(base(account, service: legacyService) as CFDictionary)
        return creds
    }

    private static func read(_ account: String, service: String) -> SSHCredentials? {
        var q = base(account, service: service)
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

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
        SecItemDelete(base(account, service: legacyService) as CFDictionary)
    }
}

/// 连过的相机（地址可能变，用指纹认人）。
struct KnownCamera: Codable, Hashable, Identifiable {
    var fingerprint: String     // SSH 指纹；直连（无验证）的相机用 "direct:<ip>"
    var host: String
    var name: String
    var lastSeen: Date
    /// 型号（ILCE-7M5）和固件版本；旧记录没有。
    var model: String? = nil
    var firmware: String? = nil
    var id: String { fingerprint }

    /// 名字还是 IP（第一次连接时没读到型号）。
    var nameIsAddress: Bool { name == host || name.allSatisfy { $0.isNumber || $0 == "." } }
    /// 没读到型号、名字只是 IP 的直连相机：同一台相机换了 IP 会被记成好几台。
    var unidentified: Bool { nameIsAddress && model == nil }
    /// 界面上显示的名字：不用 IP 当名字。
    var displayName: String { unidentified ? String(localized: "未识别的相机") : name }

    static let key = "knownCameras"

    static func load() -> [KnownCamera] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([KnownCamera].self, from: d)) ?? []
    }

    /// - front: 排到最前（启动时自动连接的就是第一台）。同时连接的第二台相机不抢这个位置。
    static func remember(_ cam: KnownCamera, front: Bool = true) {
        var all = load()
        // 直连相机这次读到了型号：之前同样直连、没读到型号、名字只是 IP 的记录多半是同一台换了 IP，一并清掉。
        if cam.fingerprint.hasPrefix("direct:"), cam.model != nil {
            all.removeAll { $0.fingerprint != cam.fingerprint && $0.fingerprint.hasPrefix("direct:") && $0.unidentified }
        }
        if !front, let i = all.firstIndex(where: { $0.fingerprint == cam.fingerprint }) {
            all[i] = cam
        } else {
            all.removeAll { $0.fingerprint == cam.fingerprint }
            if front { all.insert(cam, at: 0) } else { all.append(cam) }
        }
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
