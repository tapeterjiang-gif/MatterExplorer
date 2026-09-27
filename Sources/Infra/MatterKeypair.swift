import Foundation
import Matter
import Security

/// P-256（NIST SECP256R1）密钥对，实现 `MTRKeypair` 供 Matter 框架签名。
/// 私钥以永久 Keychain 项保存，保证 App 重启后能恢复同一 fabric。
final class MatterKeypair: NSObject, MTRKeypair {
    static let applicationTag = "com.example.MatterExplorer.root"

    private let privateKey: SecKey

    private init(privateKey: SecKey) {
        self.privateKey = privateKey
        super.init()
    }

    // MARK: - 创建 / 恢复

    /// 从 Keychain 恢复或新建根密钥对。
    static func loadOrCreateRootKeypair() -> MatterKeypair? {
        if let key = loadPersisted() {
            return MatterKeypair(privateKey: key)
        }
        guard let created = createAndPersist() else { return nil }
        return MatterKeypair(privateKey: created)
    }

    private static func createAndPersist() -> SecKey? {
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
            kSecAttrIsPermanent: true,
            kSecAttrApplicationTag: applicationTag.data(using: .utf8)!,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel: "MatterExplorer Root Keypair",
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { return nil }
        return key
    }

    /// 删除持久化的根密钥对（设置页「重置」使用；删除后下次启动将新建 fabric）。
    @discardableResult
    static func deletePersisted() -> Bool {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: applicationTag.data(using: .utf8)!,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func loadPersisted() -> SecKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassKey,
            kSecAttrApplicationTag: applicationTag.data(using: .utf8)!,
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            // 必须限定私钥项：同一 tag 下公钥项也会被写入，取到公钥将无法签名。
            kSecAttrKeyClass: kSecAttrKeyClassPrivate,
            kSecReturnRef: true,
            kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let key = result else { return nil }
        return unsafeDowncast(key, to: SecKey.self)
    }

    // MARK: - MTRKeypair

    func copyPublicKey() -> SecKey {
        // copy 语义：返回 +1 引用，由框架负责释放。
        return SecKeyCopyPublicKey(privateKey)!
    }

    func signMessageECDSA_DER(_ message: Data) -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            message as CFData,
            &error
        ) else {
            LogStore.shared.error("ECDSA 签名失败", error: error?.takeRetainedValue(), detail: ["key": "MatterKeypair"])
            return Data()
        }
        return signature as Data
    }

    func signMessageECDSA_RAW(_ message: Data) -> Data {
        return Self.derSignatureToRaw(signMessageECDSA_DER(message))
    }

    /// 将 X9.62 DER 签名（SEQUENCE { r, s }）转换为 SEC1 原始 r||s（各 32 字节）。
    private static func derSignatureToRaw(_ der: Data) -> Data {
        let bytes = [UInt8](der)
        guard bytes.count >= 8, bytes[0] == 0x30 else { return Data() }
        var idx = 1
        // SEQUENCE 长度
        idx = skipLength(bytes, at: idx)
        guard bytes[idx] == 0x02 else { return Data() }
        idx += 1
        let rLength = readLength(bytes, at: idx)
        guard rLength > 0, idx + rLength <= bytes.count else { return Data() }
        var r = Array(bytes[idx ..< idx + rLength])
        idx += rLength
        guard bytes[idx] == 0x02 else { return Data() }
        idx += 1
        let sLength = readLength(bytes, at: idx)
        guard sLength > 0, idx + sLength <= bytes.count else { return Data() }
        var s = Array(bytes[idx ..< idx + sLength])
        r = normalizeInteger(r, to: 32)
        s = normalizeInteger(s, to: 32)
        return Data(r + s)
    }

    private static func skipLength(_ bytes: [UInt8], at index: Int) -> Int {
        let first = Int(bytes[index])
        if first & 0x80 == 0 { return index + 1 }
        return index + 1 + (first & 0x7F)
    }

    private static func readLength(_ bytes: [UInt8], at index: Int) -> Int {
        let first = Int(bytes[index])
        if first & 0x80 == 0 { return first }
        let count = first & 0x7F
        var length = 0
        for i in 0 ..< count {
            length = (length << 8) | Int(bytes[index + 1 + i])
        }
        return length
    }

    private static func normalizeInteger(_ intBytes: [UInt8], to length: Int) -> [UInt8] {
        var value = intBytes
        // 去除前导 0x00（DER 正整数补零），保留至少 1 字节。
        while value.count > 1 && value.first == 0 { value.removeFirst() }
        if value.count > length {
            value = Array(value.suffix(length))
        } else if value.count < length {
            value = Array(repeating: 0, count: length - value.count) + value
        }
        return value
    }
}
