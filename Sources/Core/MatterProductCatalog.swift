import Foundation

/// CSA DCL 产品表：(VID, PID) → 商业产品名 + 设备类型 ID。
///
/// 数据来自 DCL 公开只读接口 `/dcl/model/models`，由 `DCLCatalogStore` 统一提供
/// （运行时下载的本地缓存优先，缺失时回落随包快照）。仅覆盖已通过认证并登记 DCL 的型号：
/// 测试 VID（0xFFF1–0xFFF4）、未认证设备与自研型号都查不到，调用方需自行处理 nil。
///
/// 注意：PID 只在厂商内部唯一，必须与 VID 一起查（实测 721 个 PID 值对应多个厂商）。
enum MatterProductCatalog {
    struct Entry: Sendable {
        let name: String
        /// 规范里的设备类型 ID；DCL 未登记时为 nil。
        let deviceTypeID: UInt32?
    }

    /// 按 (vendorID, productID) 查询；未收录时返回 nil。
    static func entry(vendorID: UInt32, productID: UInt32) -> Entry? {
        store.value()[Key(vendorID: vendorID, productID: productID)]
    }

    /// 丢弃已解码的表，下次查询时重新读取（数据更新后调用）。
    static func reload() {
        store.reset()
    }

    private struct Key: Hashable {
        let vendorID: UInt32
        let productID: UInt32
    }

    /// JSON 每行格式：[vendorID, productID, 产品名, 设备类型ID]
    private struct Row: Decodable {
        let vendorID: UInt32
        let productID: UInt32
        let name: String
        let deviceTypeID: UInt32

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            vendorID = try container.decode(UInt32.self)
            productID = try container.decode(UInt32.self)
            name = try container.decode(String.self)
            deviceTypeID = try container.decode(UInt32.self)
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
            guard let data = DCLCatalogStore.shared.data(for: .products),
                  let rows = try? JSONDecoder().decode([Row].self, from: data)
            else { return [:] }
            // 逐个写入而非 Dictionary(uniqueKeysWithValues:)：后者遇到重复键会直接 trap，
            // 损坏的缓存文件会让 App 崩溃而不是回落随包数据。重复键时以后者为准（同写入侧）。
            var table: [Key: Entry] = [:]
            table.reserveCapacity(rows.count)
            for row in rows {
                table[Key(vendorID: row.vendorID, productID: row.productID)] = Entry(
                    name: row.name,
                    deviceTypeID: row.deviceTypeID == 0 ? nil : row.deviceTypeID
                )
            }
            return table
        }
    }
}