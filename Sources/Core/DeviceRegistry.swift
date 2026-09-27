import Foundation

// MARK: - 设备网络类型

/// 设备承载网络（由已配网记录或 General Diagnostics 接口类型推断）。
enum DeviceNetworkKind: String, Codable, Sendable, CaseIterable {
    case wifi
    case thread
    case ethernet
    case unknown

    var label: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .thread: "Thread"
        case .ethernet: "以太网"
        case .unknown: "未知"
        }
    }

    /// 展示图标：Wi-Fi 与 Thread 用不同图标区分。
    var systemImage: String {
        switch self {
        case .wifi: "wifi"
        case .thread: "point.3.connected.trianglepath.dotted"
        case .ethernet: "cable.connector"
        case .unknown: "questionmark.circle"
        }
    }

    static func from(interfaceType: UInt8) -> DeviceNetworkKind {
        switch interfaceType {
        case 1: .wifi
        case 2: .ethernet
        case 4: .thread
        default: .unknown
        }
    }
}

// MARK: - 设备记录

/// 已配网设备记录（本地注册表条目，Codable 持久化）。
struct DeviceRecord: Codable, Identifiable, Sendable, Hashable {
    let nodeID: UInt64
    var name: String?
    var vendorID: UInt32?
    var productID: UInt32?
    var networkKind: DeviceNetworkKind
    var commissionedAt: Date
    var endpointCount: UInt16?

    var id: UInt64 { nodeID }

    /// 展示名称（列表主标题 / 详情页标题）：优先用户命名，其次 DCL 产品名与厂商名，最后回落到节点 ID。
    var displayName: String {
        if let name, !name.isEmpty { return name }
        if let productName { return productName }
        if let vendorName { return vendorName }
        return "节点 \(nodeID)"
    }

    /// VID / PID 摘要。
    var vendorProductText: String {
        switch (vendorID, productID) {
        case let (vid?, pid?): "VID \(MatterHex.hex(vid)) · PID \(MatterHex.hex(pid))"
        case let (vid?, nil): "VID \(MatterHex.hex(vid))"
        case let (nil, pid?): "PID \(MatterHex.hex(pid))"
        default: "VID / PID 未知"
        }
    }

    /// CSA DCL 厂商表查得的厂商名（未收录时为 nil）。
    var vendorName: String? { vendorID.flatMap(MatterVendorCatalog.name(for:)) }

    /// CSA DCL 产品表按 (VID, PID) 查得的商业产品名（未认证 / 自研型号不在表内）。
    var productName: String? {
        guard let vendorID, let productID else { return nil }
        return MatterProductCatalog.entry(vendorID: vendorID, productID: productID)?.name
    }

    /// DCL 收录的「厂商 · 产品」补充文本；已出现在展示名称中的部分不再重复，两者都查不到时返回 nil。
    var catalogIdentityText: String? {
        let title = displayName
        let parts = [vendorName, productName].compactMap { $0 }.filter { !title.contains($0) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - 设备注册表

/// 已配网设备注册表：UserDefaults JSON 持久化，全项目唯一的设备记录来源。
/// 线程安全：全部读写经 NSLock；对外只暴露 Sendable 值类型。
final class DeviceRegistry: @unchecked Sendable {
    static let shared = DeviceRegistry()

    private let lock = NSLock()
    private let defaults: UserDefaults
    private var _records: [DeviceRecord]?
    /// 记录文件版本高于本版本时为 true：只读、不回写，避免旧版本把新版本数据覆盖成空。
    private var isReadOnlyStore = false

    private static let storageKey = "com.example.MatterExplorer.deviceRecords"
    /// M3 遗留的裸 nodeID 列表（首次加载时迁移）。
    private static let legacyNodesKey = "com.example.MatterExplorer.commissionedNodes"
    /// 记录 schema 版本（缺失按 1 处理）。写入时一并落盘，为后续字段演进留出迁移点。
    private static let schemaVersionKey = "com.example.MatterExplorer.deviceRecordsSchemaVersion"
    private static let currentSchemaVersion = 1

    /// 注册表变更通知：配网登记 / 重命名 / 移除等写入后发出，界面订阅后即时刷新列表。
    static let didChangeNotification = Notification.Name("com.example.MatterExplorer.deviceRegistryDidChange")

    /// 发出变更通知。须在释放锁之后调用，避免订阅方在回调内读取注册表造成自锁。
    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - 读取

    /// 全部设备（按配网时间正序，先配网的在前）。
    func allDevices() -> [DeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().sorted { $0.commissionedAt < $1.commissionedAt }
    }

    /// 已登记节点 ID。
    func nodeIDs() -> [UInt64] {
        allDevices().map(\.nodeID)
    }

    func device(nodeID: UInt64) -> DeviceRecord? {
        lock.lock(); defer { lock.unlock() }
        return loadLocked().first { $0.nodeID == nodeID }
    }

    // MARK: - 写入

    /// 配网成功后登记（幂等）。已存在时不覆盖用户命名，仅补齐仍空缺的 VID / PID。
    func registerCommissioned(nodeID: UInt64, vendorID: UInt32? = nil, productID: UInt32? = nil) -> DeviceRecord {
        lock.lock()
        var records = loadLocked()
        if let index = records.firstIndex(where: { $0.nodeID == nodeID }) {
            var record = records[index]
            var changed = false
            if let vendorID, record.vendorID == nil { record.vendorID = vendorID; changed = true }
            if let productID, record.productID == nil { record.productID = productID; changed = true }
            if changed {
                records[index] = record
                persistLocked(records)
            }
            lock.unlock()
            if changed { postChange() }
            return record
        }
        let record = DeviceRecord(
            nodeID: nodeID,
            name: nil,
            vendorID: vendorID,
            productID: productID,
            networkKind: .unknown,
            commissionedAt: Date(),
            endpointCount: nil
        )
        records.append(record)
        persistLocked(records)
        lock.unlock()
        postChange()
        return record
    }

    /// 重命名（空字符串清除命名）。
    func rename(nodeID: UInt64, name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        updateLocked(nodeID: nodeID) { record in
            record.name = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }
    }

    /// 从本地列表移除记录（不影响 Matter fabric；退网需 RemoveFabric 命令或设备恢复出厂）。
    func remove(nodeID: UInt64) {
        lock.lock()
        var records = loadLocked()
        records.removeAll { $0.nodeID == nodeID }
        persistLocked(records)
        lock.unlock()
        postChange()
    }

    /// 清空全部记录（设置页「重置」使用）。
    func removeAll() {
        lock.lock()
        persistLocked([])
        lock.unlock()
        postChange()
    }

    func setVendorProduct(nodeID: UInt64, vendorID: UInt32?, productID: UInt32?) {
        updateLocked(nodeID: nodeID) { record in
            if let vendorID { record.vendorID = vendorID }
            if let productID { record.productID = productID }
        }
    }

    /// 记录「上次观测到」的网络类型（由诊断结果推断，不是权威值；实时判断以读取结果为准）。
    func setNetworkKind(nodeID: UInt64, kind: DeviceNetworkKind) {
        guard kind != .unknown else { return }
        updateLocked(nodeID: nodeID) { record in
            record.networkKind = kind
        }
    }

    /// 记录「上次观测到」的端点数量（不是权威值；实时判断以读取结果为准）。
    func setEndpointCount(nodeID: UInt64, count: UInt16) {
        updateLocked(nodeID: nodeID) { record in
            record.endpointCount = count
        }
    }

    // MARK: - 内部

    private func updateLocked(nodeID: UInt64, mutate: (inout DeviceRecord) -> Void) {
        lock.lock()
        var records = loadLocked()
        guard let index = records.firstIndex(where: { $0.nodeID == nodeID }) else {
            lock.unlock()
            return
        }
        mutate(&records[index])
        persistLocked(records)
        lock.unlock()
        postChange()
    }

    /// 载入（首次访问时解码，并迁移 M3 遗留的裸 nodeID 列表）。调用方须持有锁。
    private func loadLocked() -> [DeviceRecord] {
        if let _records { return _records }
        var records: [DeviceRecord] = []
        let storedVersion = defaults.object(forKey: Self.schemaVersionKey) as? Int ?? Self.currentSchemaVersion
        if storedVersion > Self.currentSchemaVersion {
            // 记录由更新版本写入：不解析、不回写，避免旧版本把数据覆盖成空。
            isReadOnlyStore = true
            LogStore.shared.log(
                category: .system, level: .warning,
                message: "设备记录版本高于当前支持版本，本次按只读处理",
                detail: ["记录版本": "\(storedVersion)", "支持版本": "\(Self.currentSchemaVersion)"]
            )
            _records = []
            return []
        }
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([DeviceRecord].self, from: data) {
            records = decoded
        }
        if let legacy = defaults.stringArray(forKey: Self.legacyNodesKey) {
            let known = Set(records.map(\.nodeID))
            let imported = legacy
                .compactMap { UInt64($0) }
                .filter { !known.contains($0) }
                .map { nodeID in
                    DeviceRecord(
                        nodeID: nodeID,
                        name: nil,
                        vendorID: nil,
                        productID: nil,
                        networkKind: .unknown,
                        commissionedAt: Date(),
                        endpointCount: nil
                    )
                }
            if !imported.isEmpty {
                records.append(contentsOf: imported)
                persistLocked(records)
                LogStore.shared.log(
                    category: .system, level: .info,
                    message: "已迁移历史配网节点记录", detail: ["数量": "\(imported.count)"]
                )
            }
        }
        _records = records
        return records
    }

    /// 写盘并更新内存缓存。调用方须持有锁。
    private func persistLocked(_ records: [DeviceRecord]) {
        _records = records
        guard !isReadOnlyStore else { return }
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
        defaults.set(Self.currentSchemaVersion, forKey: Self.schemaVersionKey)
    }
}