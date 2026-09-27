import CryptoKit
import Foundation

/// `Data` 与十六进制字符串的互转。
///
/// 与 `MatterHex` 分工不同：`MatterHex` 用于整数数值展示（统一大写、带 `0x` 前缀），
/// 此处用于字节串（Thread dataset、根公钥、摘要）——按 Matter / Thread 生态惯例输出小写。
extension Data {
    /// 小写十六进制文本。
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 摘要的十六进制文本（PAA 指纹、OTA 镜像 ID 等处共用）。
    var sha256Hex: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }

    /// 从十六进制字符串构造数据（要求偶数位、合法 hex）。
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}