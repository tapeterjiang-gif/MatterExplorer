import Foundation

/// Matter 厂商 ID → 厂商名称。
/// 数据来源：CSA 官方分布式合规账本（DCL）公开只读接口
/// `on.dcl.csa-iot.org/dcl/vendorinfo/vendors`，由 `DCLCatalogStore` 统一提供
/// （运行时下载的本地缓存优先，缺失时回落随包快照）。
/// DCL 未登记的取值（未指定厂商 / 测试厂商）由本文件内的 fallback 兜底。
enum MatterVendorCatalog {
    /// 规范内有明确含义、但 DCL 未收录的取值。
    private static let fallbacks: [UInt32: String] = [
        0x0000: "未指定厂商",
        0xFFF1: "测试厂商 1",
        0xFFF2: "测试厂商 2",
        0xFFF3: "测试厂商 3",
        0xFFF4: "测试厂商 4",
        0xFFFF: "未指定厂商",
    ]

    /// 厂商名称；未收录时返回 nil（UI 此时只展示 VID 十六进制值）。
    static func name(for vendorID: UInt32) -> String? {
        if let name = store.value()[String(vendorID)], !name.isEmpty { return name }
        return fallbacks[vendorID]
    }

    /// 丢弃已解码的表，下次查询时重新读取（数据更新后调用）。
    static func reload() {
        store.reset()
    }

    /// 持锁的懒加载持有者（Swift 6 不允许可变的全局状态，故封装为不可变单例）。
    private static let store = Holder()

    private final class Holder: @unchecked Sendable {
        private let lock = NSLock()
        private var table: [String: String]?

        func value() -> [String: String] {
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

        private static func load() -> [String: String] {
            guard let data = DCLCatalogStore.shared.data(for: .vendors),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: data)
            else { return [:] }
            return decoded
        }
    }
}