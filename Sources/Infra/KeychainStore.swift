import Foundation
import Security

/// Keychain 存取器：敏感凭据（IPK、根密钥等）按 service + account 存取。
final class KeychainStore: @unchecked Sendable {
    static let standard = KeychainStore()

    private let service = "com.example.MatterExplorer"
    private let ipkAccount = "ipk.v1"

    // MARK: - 通用存取

    func data(forKey account: String) -> Data? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    func set(_ data: Data, forKey account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery: [CFString: Any] = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        return status == errSecSuccess
    }

    @discardableResult
    func delete(forKey account: String) -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - IPK

    /// 读取或创建 16 字节 Identity Protection Key（SecRandomCopyBytes 生成，持久化到 Keychain）。
    func loadOrCreateIPK() -> Data {
        if let existing = data(forKey: ipkAccount), existing.count == 16 {
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            // SecRandomCopyBytes 失败几乎不可能发生；兜底为可用的固定值。
            return Data([0x6D, 0x61, 0x74, 0x74, 0x65, 0x72, 0x65, 0x78, 0x70, 0x6C, 0x6F, 0x72, 0x65, 0x72, 0x00, 0x01])
        }
        let ipk = Data(bytes)
        set(ipk, forKey: ipkAccount)
        return ipk
    }

    /// 删除 IPK（设置页「重置」使用）。
    @discardableResult
    func deleteIPK() -> Bool {
        delete(forKey: ipkAccount)
    }
}
