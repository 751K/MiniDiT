import Foundation

/// 早期版本叫 SonyImport：包标识 com.kong.SonyImport，数据在 ~/Library/Application Support/SonyImport。
/// 改名为 MiniDiT 后，第一次启动时把旧设置和旧数据搬过来（在任何存储读取之前调用）。
/// 钥匙串里的相机账号在 CredentialStore 里按需迁移。
enum LegacyMigration {
    static let oldBundleID = "com.kong.SonyImport"
    static let supportFolder = "MiniDiT"
    private static let oldSupportFolder = "SonyImport"
    private static let doneKey = "migratedFromSonyImport"

    static func run() {
        guard let id = Bundle.main.bundleIdentifier, id != oldBundleID else { return }
        migrateDefaults(to: id)
        migrateSupportFolder()
    }

    /// 旧偏好域里的键并到新域；新域已有的键不覆盖。旧的 plist 留着不删。
    private static func migrateDefaults(to id: String) {
        let d = UserDefaults.standard
        guard !d.bool(forKey: doneKey) else { return }
        let new = d.persistentDomain(forName: id) ?? [:]
        if let old = d.persistentDomain(forName: oldBundleID), !old.isEmpty {
            d.setPersistentDomain(old.merging(new) { _, n in n }, forName: id)
        }
        d.set(true, forKey: doneKey)
    }

    /// 把 SonyImport 文件夹里的东西挪进 MiniDiT 文件夹（同一个卷上只是改名）。
    /// 新位置已有同名项时不动旧的，留在原处；旧文件夹空了就删掉。
    private static func migrateSupportFolder() {
        let fm = FileManager.default
        let base = URL.applicationSupportDirectory
        let old = base.appending(path: oldSupportFolder, directoryHint: .isDirectory)
        let new = base.appending(path: supportFolder, directoryHint: .isDirectory)
        guard let items = try? fm.contentsOfDirectory(atPath: old.path(percentEncoded: false)) else { return }
        try? fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in items {
            let dest = new.appending(path: name)
            guard !fm.fileExists(atPath: dest.path(percentEncoded: false)) else { continue }
            try? fm.moveItem(at: old.appending(path: name), to: dest)
        }
        if (try? fm.contentsOfDirectory(atPath: old.path(percentEncoded: false)))?.isEmpty == true {
            try? fm.removeItem(at: old)
        }
    }
}
