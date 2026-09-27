import Foundation

/// CSA DCL 认证表：(VID, PID, 软件版本) → 认证类型与认证值。
///
/// 数据来自 DCL 公开只读接口 `/dcl/compliance/certified-models`，由 `DCLCatalogStore`
/// 统一提供（本地缓存优先，缺失时回落随包快照）。
///
/// 目前仅缓存备用，尚未接入界面；故采用懒加载，未查询时不解码这 5000 余条记录。
enum MatterCertifiedModelCatalog {
    struct Entry: Sendable {
        /// 认证类型（如 `certification_type_test` / `certification_type_certified`）。
        let certificationType: String
        /// 认证值（规范里的 `CertificationType` 枚举值）。
        let value: UInt32
    }

    /// 按 (vendorID, productID, softwareVersion) 查询；未收录时返回 nil。
    static func entry(vendorID: UInt32, productID: UInt32, softwareVersion: UInt32) -> Entry? {
        store.value()[Key(vendorID: vendorID, productID: productID, softwareVersion: softwareVersion)]
    }

    /// 丢弃已解码的表，下次查询时重新读取（数据更新后调用）。
    static func reload() {
        store.reset()
    }

    private struct Key: Hashable {
        let vendorID: UInt32
        let productID: UInt32
        let softwareVersion: UInt32
    }

    /// JSON 每行格式：[vendorID, productID, 软件版本, 认证类型, 认证值]
    private struct Row: Decodable {
        let vendorID: UInt32
        let productID: UInt32
        let softwareVersion: UInt32
        let certificationType: String
        let value: UInt32

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            vendorID = try container.decode(UInt32.self)
            productID = try container.decode(UInt32.self)
            softwareVersion = try container.decode(UInt32.self)
            certificationType = try container.decode(String.self)
            value = try container.decode(UInt32.self)
        }
    }

    /// 持锁的懒加载持有者（Swift 6 不允许可变的全局状态，故封装为不可变单例）。
    private static let store = Holder()

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [Key: Entry]?

        func value() -> [Key: Entry] {
            lock.lock(); defer { lock.unlock() }
            if let table { return table }
            let loaded = Self.load()
            table = loaded
            return loaded
        }

        func reset() {
            lock.lock(); defer { lock.unlock() }
            table = nil
        }

        private static func load() -> [Key: Entry] {
            guard let data = DCLCatalogStore.shared.data(for: .certifiedModels),
                  let rows = try? JSONDecoder().decode([Row].self, from: data)
            else { return [:] }
            // 逐个写入而非 Dictionary(uniqueKeysWithValues:)：后者遇到重复键会直接 trap，
            // 损坏的缓存文件会让 App 崩溃而不是回落随包数据。重复键时以后者为准（同写入侧）。
            var table: [Key: Entry] = [:]
            table.reserveCapacity(rows.count)
            for row in rows {
                table[Key(vendorID: row.vendorID, productID: row.productID, softwareVersion: row.softwareVersion)] =
                    Entry(certificationType: row.certificationType, value: row.value)
            }
            return table
        }
    }
}