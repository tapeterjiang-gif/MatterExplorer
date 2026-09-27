import Foundation
import Matter

// MARK: - 特征读数与快照（跨线程安全）

/// 单个特征的展示读数。
struct TraitReading: Identifiable, Sendable, Hashable {
    let trait: DeviceTrait
    let endpointID: UInt16
    /// 展示文本（无有效读数时为「—」）。
    let text: String
    /// 原始属性值文本（调试用）。
    let rawText: String
    /// 是否存在有效读数；列表摘要据此过滤。
    let isAvailable: Bool

    var id: String { "\(trait.rawValue)-\(endpointID)" }

    /// 该特征是否附带可交互入口。
    var canControl: Bool { trait.controlCapability != nil }
}

/// 单个端点的特征与原始取值快照。
struct EndpointTraitSnapshot: Identifiable, Sendable {
    let endpointID: UInt16
    let traits: [DeviceTrait]
    /// 原始属性值（集群 + 属性 → 值）。
    let values: [ControlAttributeKey: MatterScalar]
    /// 读取失败说明（信息性，不影响其余特征）。
    let notices: [String]
    /// 该端点的 `Descriptor.DeviceTypeList`（0x1D / 属性 0）设备类型 ID。
    /// 用于核对端点划分是否合理（同一逻辑设备被拆开，还是各自独立的子设备）；读取失败时为空。
    let deviceTypeIDs: [UInt32]

    var id: UInt16 { endpointID }

    /// 设备类型展示文本（规范名称 + 十六进制 ID）；未读到时为 nil。
    var deviceTypeText: String? {
        guard !deviceTypeIDs.isEmpty else { return nil }
        return deviceTypeIDs
            .map { id in
                let identifier = MatterHex.hex(id)
                guard let name = MTRDeviceType(forID: NSNumber(value: id))?.name else { return identifier }
                return "\(name)（\(identifier)）"
            }
            .joined(separator: " + ")
    }

    /// 派生读数（按特征顺序）。
    var readings: [TraitReading] {
        traits.map { DeviceTraitCatalog.reading($0, values: values, endpointID: endpointID) }
    }
}

/// 整台设备的特征快照。
struct DeviceTraitSnapshot: Sendable {
    let nodeID: UInt64
    let endpoints: [EndpointTraitSnapshot]
    let notices: [String]
    let updatedAt: Date
    /// 列表行摘要（已排序并截断）。
    let summaryReadings: [TraitReading]
}

// MARK: - 内存缓存

/// 设备特征快照的内存缓存（仅列表摘要用）。
/// 读数易变，**不写入 UserDefaults / DeviceRegistry**；超过 `lifetime` 视为过期，由调用方重新读取。
final class DeviceTraitCache: @unchecked Sendable {
    static let shared = DeviceTraitCache()

    /// 快照有效期。
    static let lifetime: TimeInterval = 60

    private let lock = NSLock()
    private var entries: [UInt64: DeviceTraitSnapshot] = [:]

    func snapshot(nodeID: UInt64) -> DeviceTraitSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return entries[nodeID]
    }

    /// 是否已有未过期的快照。
    func isFresh(nodeID: UInt64, now: Date = Date()) -> Bool {
        guard let snapshot = snapshot(nodeID: nodeID) else { return false }
        return now.timeIntervalSince(snapshot.updatedAt) < Self.lifetime
    }

    func store(_ snapshot: DeviceTraitSnapshot) {
        lock.lock()
        entries[snapshot.nodeID] = snapshot
        lock.unlock()
    }

    func remove(nodeID: UInt64) {
        lock.lock()
        entries.removeValue(forKey: nodeID)
        lock.unlock()
    }
}