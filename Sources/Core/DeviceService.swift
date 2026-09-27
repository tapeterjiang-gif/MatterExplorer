import Foundation
import Matter
import os

// MARK: - 值类型（跨线程安全）

/// 设备在线状态（MTRDeviceState 的值类型映射）。
enum DeviceReachability: String, Sendable, CaseIterable {
    case unknown
    case reachable
    case unreachable

    var label: String {
        switch self {
        case .unknown: "未知"
        case .reachable: "在线"
        case .unreachable: "离线"
        }
    }

    init(_ state: MTRDeviceState) {
        switch state {
        case .unknown: self = .unknown
        case .reachable: self = .reachable
        case .unreachable: self = .unreachable
        @unknown default: self = .unknown
        }
    }
}

/// 设备基本信息快照（端点 0 / Basic Information 集群 0x28）。
struct DeviceBasicInfo: Sendable, Equatable {
    var vendorName: String?
    var vendorID: UInt32?
    var productName: String?
    var productID: UInt32?
    var nodeLabel: String?
    var hardwareVersion: UInt16?
    var hardwareVersionString: String?
    var softwareVersion: UInt32?
    var softwareVersionString: String?
    var serialNumber: String?
    var uniqueID: String?
    var dataModelRevision: UInt16?
}

/// 设备网络信息摘要（General Diagnostics 0x33 + Thread 0x35 / Wi-Fi 0x36 诊断）。
struct DeviceNetworkSummary: Sendable {
    struct Interface: Identifiable, Sendable {
        let id: String
        let name: String
        let kind: DeviceNetworkKind
        let isOperational: Bool
        let hardwareAddress: String?

        var typeLabel: String { kind.label }
    }

    var interfaces: [Interface] = []
    var threadNetworkName: String?
    var threadChannel: UInt16?
    var threadExtendedPANID: String?
    var wifiBSSID: String?
    var wifiChannel: UInt16?
    var wifiRSSI: Int8?
    /// 读取失败的集群说明（设备可能未实现对应诊断集群）。
    var notices: [String] = []

    /// 由接口类型 / 诊断数据推断承载网络。
    var inferredKind: DeviceNetworkKind {
        if threadNetworkName != nil { return .thread }
        if let kind = interfaces.first(where: { $0.kind != .unknown })?.kind { return kind }
        return wifiBSSID != nil || wifiChannel != nil ? .wifi : .unknown
    }
}

/// OTA 只读状态（端点 0：Descriptor.ServerList + OTA Software Update Requestor 集群 0x2A）。
/// 仅供诊断展示——固件下发由 `OTAProviderService`（Provider 侧）与设备详情页的镜像库完成。
struct DeviceOTAStatus: Sendable {
    /// 设备端点 0 是否提供 OTA Software Update Requestor 集群。
    var supportsRequestor = false
    var updatePossible: Bool?
    var updateState: UInt8?
    var updateStateProgress: UInt8?
    var defaultProviderCount: Int?
    /// 读取失败的说明（设备未实现对应集群 / 属性）。
    var notices: [String] = []

    /// UpdateStateEnum → 文案。
    /// 取值以 Matter.framework 头文件 `MTROTASoftwareUpdateRequestorUpdateState` 为准（勿凭印象手写：
    /// 3 是 DelayedOnQuery、4 是 Downloading，曾误把 3 当作 Downloading 导致整体错位一格）。
    var updateStateLabel: String? {
        guard let updateState else { return nil }
        switch updateState {
        case 0: return "Unknown（未知）"
        case 1: return "Idle（空闲）"
        case 2: return "Querying（查询中）"
        case 3: return "DelayedOnQuery（推迟查询）"
        case 4: return "Downloading（下载中）"
        case 5: return "Applying（应用中）"
        case 6: return "DelayedOnApply（推迟应用）"
        case 7: return "RollingBack（回滚中）"
        case 8: return "DelayedOnUserConsent（等待用户确认）"
        default: return MatterHex.hex(Int(updateState), width: 2)
        }
    }
}

/// 电池 / 电源只读状态（Power Source 集群 0x2F）。
/// 电源端点由端点 0 的 Power Source Configuration（0x2E.Sources）给出——Power Source 集群
/// 常挂在独立端点（如端点 1），并非总是在端点 0。
struct DeviceBatteryStatus: Sendable {
    /// 单个电源端点：电池，或（有线供电时）仅含 Status / Description 的电源。
    struct Source: Identifiable, Sendable {
        let endpointID: UInt16
        var id: UInt16 { endpointID }

        /// 属性 0x00 PowerSourceStatus。
        var powerSourceStatus: UInt8?
        /// 属性 0x02 Description。
        var description: String?
        /// 属性 0x11 BatPresent。
        var present: Bool?
        /// 属性 0x0E BatChargeLevel。
        var chargeLevel: UInt8?
        /// 属性 0x0C BatPercentRemaining（规范单位：半个百分点，取值 0–200）。
        var percentRemainingHalf: UInt16?
        /// 属性 0x0B BatVoltage（mV）。
        var voltageMilliVolts: UInt32?
        /// 属性 0x1A BatChargeState。
        var chargeState: UInt8?
        /// 属性 0x0D BatTimeRemaining（秒）。
        var timeRemainingSeconds: UInt32?
        /// 属性 0x1B BatTimeToFullCharge（秒）。
        var timeToFullChargeSeconds: UInt32?
        /// 属性 0x1D BatChargingCurrent（mA）。
        var chargingCurrentMilliAmps: UInt32?
        /// 属性 0x18 BatCapacity（mAh）。
        var capacityMilliAmpHours: UInt32?
        /// 属性 0x19 BatQuantity。
        var quantity: UInt8?
        /// 属性 0x0F BatReplacementNeeded。
        var replacementNeeded: Bool?
        /// 属性 0x10 BatReplaceability。
        var replaceability: UInt8?
        /// 属性 0x1C BatFunctionalWhileCharging。
        var functionalWhileCharging: Bool?
        /// 属性 0x13 BatReplacementDescription。
        var replacementDescription: String?
        /// 属性 0x15 BatANSIDesignation。
        var ansiDesignation: String?
        /// 属性 0x16 BatIECDesignation。
        var iecDesignation: String?
        /// 属性 0x12 ActiveBatFaults。
        var activeBatFaults: [UInt8] = []
        /// 属性 0x1E ActiveBatChargeFaults。
        var activeBatChargeFaults: [UInt8] = []

        /// 该端点是否为电池（有线电源只有 Wired* 属性）。
        var isBattery: Bool {
            present == true || chargeLevel != nil || percentRemainingHalf != nil
                || voltageMilliVolts != nil || chargeState != nil
        }

        /// 是否有任何上报的电池字段（决定是否需要「未上报电池属性」占位文案）。
        var hasDetails: Bool {
            percentRemainingHalf != nil || chargeLevel != nil || voltageMilliVolts != nil
                || chargeState != nil || timeRemainingSeconds != nil || timeToFullChargeSeconds != nil
                || chargingCurrentMilliAmps != nil || capacityMilliAmpHours != nil || quantity != nil
                || replacementNeeded != nil || replaceability != nil || functionalWhileCharging != nil
                || replacementDescription != nil || ansiDesignation != nil || iecDesignation != nil
                || !activeBatFaults.isEmpty || !activeBatChargeFaults.isEmpty
        }

        /// 电量百分比文案（已由半个百分点换算）。
        var percentText: String? {
            guard let percentRemainingHalf else { return nil }
            let percent = Double(percentRemainingHalf) / 2
            return percent == percent.rounded() ? "\(Int(percent))%" : String(format: "%.1f%%", percent)
        }

        var powerSourceStatusLabel: String? {
            guard let powerSourceStatus else { return nil }
            switch powerSourceStatus {
            case 0: return "Unspecified（未指定）"
            case 1: return "Active（供电中）"
            case 2: return "Standby（待机）"
            case 3: return "Unavailable（不可用）"
            default: return MatterHex.hex(Int(powerSourceStatus), width: 2)
            }
        }

        var chargeLevelLabel: String? {
            guard let chargeLevel else { return nil }
            switch chargeLevel {
            case 0: return "OK（正常）"
            case 1: return "Warning（偏低）"
            case 2: return "Critical（严重不足）"
            default: return MatterHex.hex(Int(chargeLevel), width: 2)
            }
        }

        var chargeStateLabel: String? {
            guard let chargeState else { return nil }
            switch chargeState {
            case 0: return "Unknown（未知）"
            case 1: return "IsCharging（充电中）"
            case 2: return "IsAtFullCharge（已充满）"
            case 3: return "IsNotCharging（未充电）"
            default: return MatterHex.hex(Int(chargeState), width: 2)
            }
        }

        var replaceabilityLabel: String? {
            guard let replaceability else { return nil }
            switch replaceability {
            case 0: return "Unspecified（未指定）"
            case 1: return "NotReplaceable（不可更换）"
            case 2: return "UserReplaceable（用户可更换）"
            case 3: return "FactoryReplaceable（需返厂更换）"
            default: return MatterHex.hex(Int(replaceability), width: 2)
            }
        }

        var batFaultLabels: [String] { activeBatFaults.map(Self.faultLabel) }
        var batChargeFaultLabels: [String] { activeBatChargeFaults.map(Self.chargeFaultLabel) }

        /// 秒 → 中文时长文案。
        static func durationText(_ seconds: UInt32) -> String {
            let total = Int(seconds)
            let days = total / 86400
            let hours = (total % 86400) / 3600
            let minutes = (total % 3600) / 60
            if days > 0 { return "\(days) 天 \(hours) 小时" }
            if hours > 0 { return "\(hours) 小时 \(minutes) 分" }
            if minutes > 0 { return "\(minutes) 分" }
            return "\(total) 秒"
        }

        private static func faultLabel(_ value: UInt8) -> String {
            switch value {
            case 0: return "Unspecified"
            case 1: return "OverTemperature"
            case 2: return "OverVoltage"
            case 3: return "UnderVoltage"
            default: return MatterHex.hex(Int(value), width: 2)
            }
        }

        private static func chargeFaultLabel(_ value: UInt8) -> String {
            switch value {
            case 0: return "Unspecified"
            case 1: return "AmbientTooHot"
            case 2: return "AmbientTooCold"
            case 3: return "BatteryTooHot"
            case 4: return "BatteryTooCold"
            case 5: return "BatteryAbsent"
            case 6: return "BatteryOverVoltage"
            case 7: return "BatteryUnderVoltage"
            case 8: return "ChargerOverVoltage"
            case 9: return "ChargerUnderVoltage"
            case 10: return "SafetyTimeout"
            default: return MatterHex.hex(Int(value), width: 2)
            }
        }
    }

    var sources: [Source] = []
    /// 读取失败的说明（设备未实现电源集群 / 属性）。
    var notices: [String] = []

    var hasBattery: Bool { sources.contains { $0.isBattery } }
}

/// DNS-SD / BLE 发现的待配网设备。
struct DiscoveredDevice: Identifiable, Sendable, Hashable {
    let instanceName: String
    let vendorID: UInt32?
    let productID: UInt32?
    let discriminator: UInt16?
    let commissioningMode: Bool
    /// 配网广播 TXT 记录里的设备类型 ID（仅 DNS-SD 提供；BLE 广播不含，故通常为 nil）。
    var txtDeviceTypeID: UInt32?

    var id: String { instanceName }

    var isBLE: Bool { instanceName == "BLE" }

    var transportLabel: String { isBLE ? "蓝牙 BLE" : "局域网 DNS-SD" }

    /// 厂商名称（框架只提供 16 位 VID，名称由 CSA DCL 厂商表查得；未收录时为 nil）。
    var vendorName: String? { vendorID.flatMap(MatterVendorCatalog.name(for:)) }

    /// DCL 产品表查得的型号信息（未认证 / 自研型号不在表内）。
    var catalogEntry: MatterProductCatalog.Entry? {
        guard let vendorID, let productID else { return nil }
        return MatterProductCatalog.entry(vendorID: vendorID, productID: productID)
    }

    /// 商业产品名（如 "ALPSTUGA air quality monitor"）。
    var productName: String? { catalogEntry?.name }

    /// 设备类型 ID：优先取配网广播的 TXT `DT` 字段，缺失时用 DCL 产品表兜底。
    var deviceTypeID: UInt32? { txtDeviceTypeID ?? catalogEntry?.deviceTypeID }

    /// 设备类型名称（Matter 规范标准类型，由 Matter.framework 内置表查得；未收录时为 nil）。
    var deviceTypeName: String? {
        guard let deviceTypeID,
              let deviceType = MTRDeviceType(forID: NSNumber(value: deviceTypeID))
        else { return nil }
        return deviceType.name
    }

    /// 设备类型展示文本；名称已出现在主标题里时只补充规范里的十六进制 ID。
    var deviceTypeText: String? {
        guard let deviceTypeID else { return nil }
        let identifier = MatterHex.hex(deviceTypeID, width: 4)
        guard let deviceTypeName else { return "设备类型 \(identifier)（未收录）" }
        return title.contains(deviceTypeName) ? "设备类型 \(identifier)" : "设备类型 \(identifier) \(deviceTypeName)"
    }

    /// 主标题：产品名优先，其次设备类型名、厂商名；都缺失时退回传输方式 / 实例名。
    var title: String {
        if let productName { return productName }
        if let deviceTypeName { return "\(deviceTypeName) · \(vendorName ?? transportLabel)" }
        if let vendorName { return "\(vendorName) · \(transportLabel)" }
        return "\(transportLabel) · \(instanceName)"
    }

    var detailText: String {
        var parts: [String] = []
        // 已出现在主标题里的信息不重复。
        if let vendorName, !title.contains(vendorName) { parts.append(vendorName) }
        if !title.contains(transportLabel) { parts.append(transportLabel) }
        // 蓝牙广播的实例名固定为 "BLE"，与传输方式重复，不展示。
        if !isBLE { parts.append("实例名 \(instanceName)") }
        if let discriminator { parts.append("识别码 \(discriminator)") }
        if let vendorID { parts.append("VID \(MatterHex.hex(vendorID))") }
        if let productID { parts.append("PID \(MatterHex.hex(productID))") }
        if let deviceTypeText { parts.append(deviceTypeText) }
        parts.append(commissioningMode ? "配网窗口开启" : "配网窗口关闭")
        return parts.joined(separator: " · ")
    }
}

// MARK: - 设备服务

/// 设备服务：在线状态监视（MTRDevice）+ 基本信息 / 网络信息读取 + 局域网待配网设备发现。
/// 线程安全：句柄由 NSLock 保护；回调经 Sendable 值类型在主线程触发。
final class DeviceService: @unchecked Sendable {
    static let shared = DeviceService()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.example.MatterExplorer", category: "DeviceService")
    private let queue = DispatchQueue(label: "com.example.MatterExplorer.device")

    /// 状态监视句柄：nodeID → (MTRDevice, delegate)。MTRDevice 对 delegate 弱引用，须强持有。
    private var monitors: [UInt64: (device: MTRDevice, delegate: DeviceStatusDelegate)] = [:]
    private var browser: CommissionableBrowserBridge?
    private var txtBrowser: CommissionableTXTBrowser?
    private var isBrowsing = false
    /// 已发现设备（instanceName → 设备），用于与 TXT 记录中的设备类型合并。
    private var foundDevices: [String: DiscoveredDevice] = [:]
    /// TXT 记录中的设备类型（instanceName → 设备类型 ID），可能先于框架结果到达。
    private var deviceTypes: [String: UInt32] = [:]

    /// 在线状态变化回调（主线程触发）：(nodeID, 状态)。
    var onStatusChange: (@Sendable (UInt64, DeviceReachability) -> Void)?

    // MARK: - 在线状态

    /// 开始监视节点在线状态（幂等）。返回控制器是否就绪。
    @discardableResult
    func startMonitoring(nodeIDs: [UInt64]) -> Bool {
        guard let controller = MatterManager.shared.controller else { return false }
        var started: [UInt64] = []
        for nodeID in nodeIDs {
            lock.lock()
            let exists = monitors[nodeID] != nil
            lock.unlock()
            guard !exists else { continue }

            let device = MTRDevice(nodeID: NSNumber(value: nodeID), controller: controller)
            let delegate = DeviceStatusDelegate(nodeID: nodeID) { [weak self] id, state in
                guard let self else { return }
                DispatchQueue.main.async { self.onStatusChange?(id, state) }
            }
            device.add(delegate, queue: queue, interestedPathsForAttributes: nil, interestedPathsForEvents: nil)

            lock.lock()
            monitors[nodeID] = (device, delegate)
            let state = DeviceReachability(device.state)
            lock.unlock()

            started.append(nodeID)
            DispatchQueue.main.async { [weak self] in
                self?.onStatusChange?(nodeID, state)
            }
        }
        if !started.isEmpty {
            LogStore.shared.log(
                category: .network, level: .debug,
                message: "已开始监视设备在线状态",
                detail: ["节点": started.map(String.init).joined(separator: "、")]
            )
        }
        return true
    }

    /// 停止监视指定节点。
    func stopMonitoring(nodeIDs: [UInt64]) {
        for nodeID in nodeIDs {
            lock.lock()
            let handle = monitors.removeValue(forKey: nodeID)
            lock.unlock()
            guard let handle else { continue }
            handle.device.remove(handle.delegate)
        }
    }

    func stopAllMonitoring() {
        lock.lock()
        let handles = monitors
        monitors.removeAll()
        lock.unlock()
        for handle in handles.values {
            handle.device.remove(handle.delegate)
        }
    }

    /// 当前缓存的在线状态。
    func currentState(nodeID: UInt64) -> DeviceReachability? {
        lock.lock(); defer { lock.unlock() }
        guard let handle = monitors[nodeID] else { return nil }
        return DeviceReachability(handle.device.state)
    }

    // MARK: - 基本信息

    /// 读取端点 0 的 Basic Information 集群全部属性。
    func readBasicInfo(nodeID: UInt64, completion: @escaping @Sendable (Result<DeviceBasicInfo, ClusterOperationResult>) -> Void) {
        ClusterToolService.shared.readScalars(nodeID: nodeID, endpointID: 0, clusterID: 0x28, attributeIDs: []) { result in
            switch result {
            case .failure(let operation):
                LogStore.shared.log(
                    category: .dataModel, level: .warning, message: "读取设备基本信息失败",
                    detail: ["原因": operation.message], nodeID: nodeID
                )
                completion(.failure(operation))
            case .success(let values):
                var info = DeviceBasicInfo()
                info.dataModelRevision = values[0]?.uintValue.map { UInt16(clamping: $0) }
                info.vendorName = values[1]?.stringValue
                info.vendorID = values[2]?.uintValue
                info.productName = values[3]?.stringValue
                info.productID = values[4]?.uintValue
                info.nodeLabel = values[5]?.stringValue
                info.hardwareVersion = values[7]?.uintValue.map { UInt16(clamping: $0) }
                info.hardwareVersionString = values[8]?.stringValue
                info.softwareVersion = values[9]?.uintValue
                info.softwareVersionString = values[10]?.stringValue
                info.serialNumber = values[15]?.stringValue
                info.uniqueID = values[18]?.stringValue

                var detail: [String: String] = [:]
                if let vendorName = info.vendorName { detail["厂商"] = vendorName }
                if let productName = info.productName { detail["产品"] = productName }
                if let nodeLabel = info.nodeLabel { detail["NodeLabel"] = nodeLabel }
                detail["有效属性"] = "\(values.values.filter { $0 != .null }.count) / \(values.count)"
                LogStore.shared.log(
                    category: .dataModel, level: .info, message: "已读取设备基本信息",
                    detail: detail, nodeID: nodeID, endpointID: 0
                )
                completion(.success(info))
            }
        }
    }

    /// 读取拓扑：端点列表（Descriptor.PartsList）。
    func readEndpoints(nodeID: UInt64, completion: @escaping @Sendable (Result<[UInt16], ClusterOperationResult>) -> Void) {
        ClusterToolService.shared.discoverEndpoints(nodeID: nodeID, completion: completion)
    }

    // MARK: - 网络信息

    /// 读取网络信息：接口列表（0x33）+ Thread / Wi-Fi 诊断（0x35 / 0x36，缺失时记入 notices）。
    func readNetworkInfo(nodeID: UInt64, completion: @escaping @Sendable (DeviceNetworkSummary) -> Void) {
        ClusterToolService.shared.readScalars(
            nodeID: nodeID, endpointID: 0, clusterID: 0x33, attributeIDs: [0]
        ) { result in
            var summary = DeviceNetworkSummary()
            switch result {
            case .failure(let operation):
                summary.notices.append("NetworkInterfaces 读取失败：\(operation.message)")
            case .success(let values):
                summary.interfaces = Self.interfaces(from: values[0])
                if summary.interfaces.isEmpty {
                    summary.notices.append("NetworkInterfaces 为空：设备未报告网络接口")
                }
            }
            self.readThreadDiagnostics(nodeID: nodeID, summary: summary, completion: completion)
        }
    }

    private func readThreadDiagnostics(
        nodeID: UInt64,
        summary: DeviceNetworkSummary,
        completion: @escaping @Sendable (DeviceNetworkSummary) -> Void
    ) {
        ClusterToolService.shared.readScalars(
            nodeID: nodeID, endpointID: 0, clusterID: 0x35, attributeIDs: [0, 2, 4]
        ) { result in
            var summary = summary
            switch result {
            case .failure(let operation):
                summary.notices.append("Thread 诊断读取失败：\(operation.message)")
            case .success(let values):
                summary.threadChannel = values[0]?.uintValue.map { UInt16(clamping: $0) }
                summary.threadNetworkName = values[2]?.stringValue
                summary.threadExtendedPANID = values[4]?.bytesValue
            }
            self.readWiFiDiagnostics(nodeID: nodeID, summary: summary, completion: completion)
        }
    }

    private func readWiFiDiagnostics(
        nodeID: UInt64,
        summary: DeviceNetworkSummary,
        completion: @escaping @Sendable (DeviceNetworkSummary) -> Void
    ) {
        ClusterToolService.shared.readScalars(
            nodeID: nodeID, endpointID: 0, clusterID: 0x36, attributeIDs: [0, 3, 4]
        ) { result in
            var summary = summary
            switch result {
            case .failure(let operation):
                summary.notices.append("Wi-Fi 诊断读取失败：\(operation.message)")
            case .success(let values):
                summary.wifiBSSID = values[0]?.bytesValue
                summary.wifiChannel = values[3]?.uintValue.map { UInt16(clamping: $0) }
                if let rssi = values[4]?.numberValue { summary.wifiRSSI = Int8(clamping: Int(rssi)) }
            }
            LogStore.shared.log(
                category: .network, level: .info, message: "已读取设备网络信息",
                detail: [
                    "接口": "\(summary.interfaces.count) 个",
                    "推断网络类型": summary.inferredKind.label,
                    "提示": summary.notices.isEmpty ? "无" : summary.notices.joined(separator: "；"),
                ],
                nodeID: nodeID, endpointID: 0
            )
            completion(summary)
        }
    }

    /// NetworkInterfaces（结构体数组）→ 接口条目。
    private static func interfaces(from scalar: MatterScalar?) -> [DeviceNetworkSummary.Interface] {
        guard let elements = scalar?.arrayValue else { return [] }
        return elements.compactMap { element in
            guard let fields = element.structureValue, let name = fields[0]?.stringValue else { return nil }
            let type = UInt8(clamping: Int(fields[7]?.uintValue ?? 0))
            return DeviceNetworkSummary.Interface(
                id: name,
                name: name,
                kind: DeviceNetworkKind.from(interfaceType: type),
                isOperational: fields[1]?.boolValue ?? false,
                hardwareAddress: fields[4]?.bytesValue
            )
        }
    }

    // MARK: - OTA 状态（只读）

    /// 读取 OTA 只读状态：端点 0 的 Descriptor.ServerList 判断是否实现 0x2A，再读 Requestor 属性。
    func readOTAStatus(nodeID: UInt64, completion: @escaping @Sendable (DeviceOTAStatus) -> Void) {
        ClusterToolService.shared.readScalars(
            nodeID: nodeID, endpointID: 0, clusterID: 0x1D, attributeIDs: [1]
        ) { result in
            var status = DeviceOTAStatus()
            switch result {
            case .failure(let operation):
                status.notices.append("ServerList 读取失败：\(operation.message)")
            case .success(let values):
                let servers = values[1]?.arrayValue?.compactMap(\.uintValue) ?? []
                status.supportsRequestor = servers.contains(0x2A)
            }
            self.readOTARequestorAttributes(nodeID: nodeID, status: status, completion: completion)
        }
    }

    /// 读取 OTA Requestor 属性；读取成功即视为设备实现了该集群。
    private func readOTARequestorAttributes(
        nodeID: UInt64,
        status: DeviceOTAStatus,
        completion: @escaping @Sendable (DeviceOTAStatus) -> Void
    ) {
        ClusterToolService.shared.readScalars(
            nodeID: nodeID, endpointID: 0, clusterID: 0x2A, attributeIDs: [0, 1, 2, 3]
        ) { result in
            var status = status
            switch result {
            case .failure(let operation):
                // ServerList 已表明实现该集群时，属性读取失败需单独提示。
                if status.supportsRequestor {
                    status.notices.append("OTA Requestor 属性读取失败：\(operation.message)")
                }
            case .success(let values):
                status.supportsRequestor = true
                status.defaultProviderCount = values[0]?.arrayValue?.count
                status.updatePossible = values[1]?.boolValue
                status.updateState = values[2]?.uintValue.map { UInt8(clamping: $0) }
                status.updateStateProgress = values[3]?.uintValue.map { UInt8(clamping: $0) }
            }
            LogStore.shared.log(
                category: .dataModel, level: .info, message: "已读取设备 OTA 状态",
                detail: [
                    "支持 Requestor": status.supportsRequestor ? "是" : "否",
                    "可更新": status.updatePossible.map { $0 ? "是" : "否" } ?? "未知",
                    "更新状态": status.updateStateLabel ?? "未知",
                    "默认 Provider": status.defaultProviderCount.map(String.init) ?? "未知",
                    "提示": status.notices.isEmpty ? "无" : status.notices.joined(separator: "；"),
                ],
                nodeID: nodeID, endpointID: 0
            )
            completion(status)
        }
    }

    // MARK: - 电池 / 电源（只读）

    /// 属性值快照 → 电池状态。
    /// 数据来自 Power Source（0x2F）的订阅报告：订阅的 priming 报告一次带回该端点全部已实现属性，
    /// 之后电量 / 充电状态变化也会继续推送，故不需要逐属性网络读——电池设备多为低功耗休眠设备，
    /// 逐属性网络读会长时间挂起（实测 0x2F 通配读 >2 分钟无响应）。
    /// 键为端点：Power Source 可能挂在任意端点，不一定是端点 0。
    static func batteryStatus(from values: [UInt16: [UInt32: MatterScalar]]) -> DeviceBatteryStatus {
        var status = DeviceBatteryStatus()
        status.sources = values.keys.sorted().map {
            batterySource(endpointID: $0, values: values[$0] ?? [:])
        }
        if status.sources.isEmpty {
            status.notices = ["设备未报告 Power Source（0x2F）属性——可能未实现该集群（如纯有线供电），或订阅的首次报告尚未到达。"]
        }
        return status
    }

    /// 0x2F 属性快照 → 电池值类型。
    private static func batterySource(
        endpointID: UInt16,
        values: [UInt32: MatterScalar]
    ) -> DeviceBatteryStatus.Source {
        var source = DeviceBatteryStatus.Source(endpointID: endpointID)
        source.powerSourceStatus = values[0x00]?.uintValue.map { UInt8(clamping: $0) }
        source.description = values[0x02]?.stringValue
        source.voltageMilliVolts = values[0x0B]?.uintValue
        source.percentRemainingHalf = values[0x0C]?.uintValue.map { UInt16(clamping: $0) }
        source.timeRemainingSeconds = values[0x0D]?.uintValue
        source.chargeLevel = values[0x0E]?.uintValue.map { UInt8(clamping: $0) }
        source.replacementNeeded = values[0x0F]?.boolValue
        source.replaceability = values[0x10]?.uintValue.map { UInt8(clamping: $0) }
        source.present = values[0x11]?.boolValue
        source.activeBatFaults = faultList(values[0x12])
        source.replacementDescription = values[0x13]?.stringValue
        source.ansiDesignation = values[0x15]?.stringValue
        source.iecDesignation = values[0x16]?.stringValue
        source.capacityMilliAmpHours = values[0x18]?.uintValue
        source.quantity = values[0x19]?.uintValue.map { UInt8(clamping: $0) }
        source.chargeState = values[0x1A]?.uintValue.map { UInt8(clamping: $0) }
        source.timeToFullChargeSeconds = values[0x1B]?.uintValue
        source.functionalWhileCharging = values[0x1C]?.boolValue
        source.chargingCurrentMilliAmps = values[0x1D]?.uintValue
        source.activeBatChargeFaults = faultList(values[0x1E])
        return source
    }

    /// 枚举数组属性 → 取值列表。
    private static func faultList(_ scalar: MatterScalar?) -> [UInt8] {
        scalar?.arrayValue?.compactMap { $0.uintValue.map { UInt8(clamping: $0) } } ?? []
    }

    // MARK: - 待配网设备发现

    var browsing: Bool {
        lock.lock(); defer { lock.unlock() }
        return isBrowsing
    }

    /// 开始扫描局域网 / 蓝牙上的待配网设备（DNS-SD）。
    @discardableResult
    func startBrowse(
        onFound: @escaping @Sendable (DiscoveredDevice) -> Void,
        onLost: @escaping @Sendable (String) -> Void
    ) -> Bool {
        guard let controller = MatterManager.shared.controller else { return false }
        lock.lock()
        if isBrowsing {
            lock.unlock()
            return true
        }
        lock.unlock()

        let bridge = CommissionableBrowserBridge(
            onFound: { [weak self] device in self?.merge(device, emit: onFound) },
            onLost: { [weak self] instanceName in
                self?.forget(instanceName)
                onLost(instanceName)
            }
        )
        let started = controller.startBrowse(forCommissionables: bridge, queue: queue)

        let txtBrowser = CommissionableTXTBrowser()
        txtBrowser.onDeviceType = { [weak self] instanceName, deviceTypeID in
            self?.applyDeviceType(deviceTypeID, to: instanceName, emit: onFound)
        }

        lock.lock()
        if started {
            browser = bridge
            self.txtBrowser = txtBrowser
            isBrowsing = true
        }
        lock.unlock()
        if started { txtBrowser.start() }
        LogStore.shared.log(
            category: .network, level: started ? .info : .warning,
            message: started ? "已开始扫描待配网设备" : "扫描待配网设备失败（控制器未就绪或已在扫描）"
        )
        return started
    }

    /// 停止扫描待配网设备。
    func stopBrowse() {
        lock.lock()
        let wasBrowsing = isBrowsing
        browser = nil
        let txtBrowser = self.txtBrowser
        self.txtBrowser = nil
        isBrowsing = false
        foundDevices.removeAll()
        deviceTypes.removeAll()
        lock.unlock()
        txtBrowser?.stop()
        guard wasBrowsing, let controller = MatterManager.shared.controller else { return }
        let stopped = controller.stopBrowseForCommissionables()
        LogStore.shared.log(
            category: .network, level: .debug,
            message: stopped ? "已停止扫描待配网设备" : "停止扫描请求未生效（可能已停止）"
        )
    }

    // MARK: - 扫描结果与 TXT 字段的合并

    /// 框架扫描结果：补上已缓存的设备类型后回调。
    private func merge(_ device: DiscoveredDevice, emit: @Sendable (DiscoveredDevice) -> Void) {
        lock.lock()
        var merged = device
        merged.txtDeviceTypeID = deviceTypes[device.instanceName]
        let isNew = foundDevices.updateValue(merged, forKey: device.instanceName) == nil
        lock.unlock()
        emit(merged)
        // 框架会对同一实例反复回调；仅在首次发现时记录，避免扫描期间重复刷屏。
        guard isNew else { return }
        LogStore.shared.log(
            category: .network, level: .info, message: "发现待配网设备",
            detail: ["实例名": merged.instanceName, "传输": merged.transportLabel, "详情": merged.detailText]
        )
    }

    /// TXT 记录中的设备类型：补充到已发现设备上（框架结果未到时先缓存）。
    private func applyDeviceType(
        _ deviceTypeID: UInt32?,
        to instanceName: String,
        emit: @Sendable (DiscoveredDevice) -> Void
    ) {
        lock.lock()
        // TXT 浏览器可能对同一实例重复上报，类型未变化时不再记录。
        if let cached = foundDevices[instanceName], cached.txtDeviceTypeID == deviceTypeID {
            lock.unlock()
            return
        }
        guard var device = foundDevices[instanceName] else {
            deviceTypes[instanceName] = deviceTypeID
            lock.unlock()
            LogStore.shared.log(
                category: .network, level: .debug, message: "待配网设备 TXT 记录",
                detail: ["实例名": instanceName, "设备类型": deviceTypeID.map { MatterHex.hex($0, width: 4) } ?? "无 DT 字段"]
            )
            return
        }
        deviceTypes[instanceName] = deviceTypeID
        device.txtDeviceTypeID = deviceTypeID
        foundDevices[instanceName] = device
        lock.unlock()
        emit(device)
        LogStore.shared.log(
            category: .network, level: .debug, message: "待配网设备设备类型已更新",
            detail: ["实例名": instanceName, "设备类型": device.deviceTypeText ?? "无 DT 字段"]
        )
    }

    /// 设备不可见：清理缓存。
    private func forget(_ instanceName: String) {
        lock.lock()
        foundDevices[instanceName] = nil
        deviceTypes[instanceName] = nil
        lock.unlock()
    }
}

// MARK: - Delegate 桥接

/// MTRDeviceDelegate 桥接：仅关注在线状态变化，属性 / 事件报告由集群工具订阅承担。
/// 回调运行在创建时传入的串行 queue 上，再由桥接转发到主线程。
final class DeviceStatusDelegate: NSObject, MTRDeviceDelegate, @unchecked Sendable {
    private let nodeID: UInt64
    private let onState: @Sendable (UInt64, DeviceReachability) -> Void

    init(nodeID: UInt64, onState: @escaping @Sendable (UInt64, DeviceReachability) -> Void) {
        self.nodeID = nodeID
        self.onState = onState
        super.init()
    }

    func device(_ device: MTRDevice, stateChanged state: MTRDeviceState) {
        let reachability = DeviceReachability(state)
        onState(nodeID, reachability)
        LogStore.shared.log(
            category: .network, level: .debug, message: "设备在线状态：\(reachability.label)", nodeID: nodeID
        )
    }

    func device(_ device: MTRDevice, receivedAttributeReport attributeReport: [[String: Any]]) {
        // 状态监视不需要属性报告。
    }

    func device(_ device: MTRDevice, receivedEventReport eventReport: [[String: Any]]) {
        // 状态监视不需要事件报告。
    }
}

/// MTRCommissionableBrowserDelegate 桥接：发现结果转换为 Sendable 值类型。
final class CommissionableBrowserBridge: NSObject, MTRCommissionableBrowserDelegate, @unchecked Sendable {
    private let onFound: @Sendable (DiscoveredDevice) -> Void
    private let onLost: @Sendable (String) -> Void

    init(
        onFound: @escaping @Sendable (DiscoveredDevice) -> Void,
        onLost: @escaping @Sendable (String) -> Void
    ) {
        self.onFound = onFound
        self.onLost = onLost
        super.init()
    }

    func controller(_ controller: MTRDeviceController, didFindCommissionableDevice device: MTRCommissionableBrowserResult) {
        let discovered = DiscoveredDevice(
            instanceName: device.instanceName,
            vendorID: device.vendorID.uint32Value,
            productID: device.productID.uint32Value,
            discriminator: device.discriminator.uint16Value,
            commissioningMode: device.commissioningMode
        )
        onFound(discovered)
    }

    func controller(_ controller: MTRDeviceController, didRemoveCommissionableDevice device: MTRCommissionableBrowserResult) {
        onLost(device.instanceName)
        LogStore.shared.log(
            category: .network, level: .debug, message: "待配网设备已不可见",
            detail: ["实例名": device.instanceName]
        )
    }
}