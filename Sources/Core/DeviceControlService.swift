import Foundation
import Matter
import os

// MARK: - 值类型

/// 单个端点的可控能力与状态快照（跨线程安全）。
struct EndpointControlSnapshot: Identifiable, Sendable {
    let endpointID: UInt16
    var capabilities: [ControlCapability]
    /// 状态属性值（集群 + 属性 → 值）。
    var values: [ControlAttributeKey: MatterScalar]
    /// 读取失败说明（信息性，不影响其余控件可用）。
    var notices: [String]

    var id: UInt16 { endpointID }

    func number(_ key: ControlAttributeKey) -> Double? {
        values[key]?.numberValue
    }

    // MARK: 派生展示值

    /// 开关状态（OnOff 属性）。
    var isOn: Bool? {
        values[ControlAttributeKey(clusterID: 0x06, attributeID: 0x0000)]?.boolValue
    }

    /// 亮度等级区间（MinLevel / MaxLevel，缺失时用规范默认值）。
    var levelRange: ClosedRange<Double> {
        let min = number(ControlAttributeKey(clusterID: 0x08, attributeID: 0x0002))
        let max = number(ControlAttributeKey(clusterID: 0x08, attributeID: 0x0003))
        guard let max, max > 0 else { return DeviceControlCatalog.defaultLevelRange }
        return (min ?? 0)...max
    }

    /// 当前亮度百分比（0–100）。
    var brightnessPercent: Double? {
        guard let level = number(ControlAttributeKey(clusterID: 0x08, attributeID: 0x0000)) else { return nil }
        return DeviceControlCatalog.percent(fromLevel: level)
    }

    /// 色温区间（mireds，物理范围缺失时用兜底区间）。
    var miredsRange: ClosedRange<Double> {
        let min = number(ControlAttributeKey(clusterID: 0x0300, attributeID: 0x4001))
        let max = number(ControlAttributeKey(clusterID: 0x0300, attributeID: 0x4002))
        guard let min, let max, max > min else { return DeviceControlCatalog.defaultMiredsRange }
        return min...max
    }

    /// 当前色温（mireds）。
    var colorTemperatureMireds: Double? {
        number(ControlAttributeKey(clusterID: 0x0300, attributeID: 0x0007))
    }

    /// 当前开合位置百分比（0–100）。
    var liftPercent: Double? {
        guard let value = number(ControlAttributeKey(clusterID: 0x0102, attributeID: 0x000E)) else { return nil }
        return (value / 100).rounded()
    }

    /// 开合运行状态（OperationalStatus 位掩码，展示用十六进制）。
    var coveringStatusText: String? {
        guard let value = number(ControlAttributeKey(clusterID: 0x0102, attributeID: 0x000A)) else { return nil }
        return MatterHex.hex(UInt8(clamping: Int(value)))
    }
}

/// 能力探测结果（端点快照 + 整体提示）。
struct DeviceControlDetection: Sendable {
    var endpoints: [EndpointControlSnapshot] = []
    var notices: [String] = []
}

/// 订阅角色：区分详情页「设备特征」与「设备控制」面板。
/// 两者可能同栈存在（详情页 → 设备控制页），需各自持有令牌，避免互相取消订阅。
enum MonitoringRole: String, Sendable {
    case control
    case traits

    var label: String {
        switch self {
        case .control: "设备控制面板"
        case .traits: "设备特征"
        }
    }
}

// MARK: - 服务

/// 设备控制服务：能力探测（端点 → ServerList → 可控集群）、状态读取、常用命令封装与实时订阅。
/// 复用 ClusterToolService 的 MTRBaseDevice 读写与 MTRDevice 订阅能力，不重复实现协议层。
final class DeviceControlService: @unchecked Sendable {
    static let shared = DeviceControlService()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.example.MatterExplorer", category: "DeviceControl")

    /// 活动订阅令牌（按角色区分：控制面板 / 设备特征）。
    private var subscriptionTokens: [String: String] = [:]

    /// 无字段命令的数据值（Off / On / Toggle）。
    private static func emptyCommandFields() -> [String: Any] {
        MatterValueCodec.makeDataValue(from: [String: Any]()) ?? [:]
    }

    // MARK: - 能力探测

    /// 探测设备可控能力：遍历端点读取 ServerList，仅保留含可控集群的端点，并读取其状态属性。
    func detect(nodeID: UInt64, completion: @escaping @Sendable (Result<DeviceControlDetection, ClusterOperationResult>) -> Void) {
        ClusterToolService.shared.discoverEndpoints(nodeID: nodeID) { result in
            switch result {
            case .failure(let operation):
                completion(.failure(operation))
            case .success(let endpoints):
                LogStore.shared.log(
                    category: .dataModel, level: .info, message: "开始能力探测",
                    detail: ["端点数": "\(endpoints.count)"], nodeID: nodeID
                )
                self.detectNext(nodeID: nodeID, remaining: endpoints, detection: DeviceControlDetection(), completion: completion)
            }
        }
    }

    private func detectNext(
        nodeID: UInt64,
        remaining: [UInt16],
        detection: DeviceControlDetection,
        completion: @escaping @Sendable (Result<DeviceControlDetection, ClusterOperationResult>) -> Void
    ) {
        guard let endpointID = remaining.first else {
            completion(.success(detection))
            return
        }
        let base = detection
        let rest = Array(remaining.dropFirst())
        ClusterToolService.shared.discoverClusters(nodeID: nodeID, endpointID: endpointID) { result in
            switch result {
            case .failure(let operation):
                var next = base
                next.notices.append("端点 \(endpointID)：集群列表读取失败（\(operation.message)）")
                self.detectNext(nodeID: nodeID, remaining: rest, detection: next, completion: completion)
            case .success(let clusterIDs):
                let capabilities = DeviceControlCatalog.capabilities(from: clusterIDs)
                guard !capabilities.isEmpty else {
                    self.detectNext(nodeID: nodeID, remaining: rest, detection: base, completion: completion)
                    return
                }
                self.readStates(
                    nodeID: nodeID, endpointID: endpointID,
                    keys: Self.deduped(capabilities.flatMap { DeviceControlCatalog.stateAttributes[$0] ?? [] }),
                    index: 0, values: [:], notices: []
                ) { values, notices in
                    var next = base
                    next.endpoints.append(EndpointControlSnapshot(
                        endpointID: endpointID, capabilities: capabilities, values: values, notices: notices
                    ))
                    self.detectNext(nodeID: nodeID, remaining: rest, detection: next, completion: completion)
                }
            }
        }
    }

    /// 逐个属性读取状态值（单属性粒度，容忍个别属性不支持）。控制页与特征页共用。
    private func readStates(
        nodeID: UInt64,
        endpointID: UInt16,
        keys: [ControlAttributeKey],
        index: Int,
        values: [ControlAttributeKey: MatterScalar],
        notices: [String],
        completion: @escaping @Sendable ([ControlAttributeKey: MatterScalar], [String]) -> Void
    ) {
        guard index < keys.count else {
            completion(values, notices)
            return
        }
        let key = keys[index]
        ClusterToolService.shared.readScalars(
            nodeID: nodeID, endpointID: endpointID, clusterID: key.clusterID, attributeIDs: [key.attributeID]
        ) { result in
            var values = values
            var notices = notices
            switch result {
            case .success(let scalars):
                for (id, scalar) in scalars {
                    values[ControlAttributeKey(clusterID: key.clusterID, attributeID: id)] = scalar
                }
            case .failure(let operation):
                let name = DeviceControlCatalog.attributeName(key)
                notices.append("\(ClusterCatalog.clusterName(key.clusterID)).\(name) 读取失败：\(operation.message)")
            }
            self.readStates(
                nodeID: nodeID, endpointID: endpointID, keys: keys,
                index: index + 1, values: values, notices: notices, completion: completion
            )
        }
    }

    /// 保序去重。
    private static func deduped(_ keys: [ControlAttributeKey]) -> [ControlAttributeKey] {
        var seen = Set<ControlAttributeKey>()
        return keys.filter { seen.insert($0).inserted }
    }

    // MARK: - 特征探测

    /// 探测设备特征：与能力探测同一套端点 / 集群遍历，但改用 `DeviceTraitCatalog`（含传感器与非可控状态）。
    func detectTraits(
        nodeID: UInt64,
        completion: @escaping @Sendable (Result<DeviceTraitSnapshot, ClusterOperationResult>) -> Void
    ) {
        ClusterToolService.shared.discoverEndpoints(nodeID: nodeID) { result in
            switch result {
            case .failure(let operation):
                completion(.failure(operation))
            case .success(let endpoints):
                LogStore.shared.log(
                    category: .dataModel, level: .info, message: "开始特征探测",
                    detail: ["端点数": "\(endpoints.count)"], nodeID: nodeID
                )
                self.detectTraitsNext(
                    nodeID: nodeID, remaining: endpoints, endpoints: [], notices: [], completion: completion
                )
            }
        }
    }

    private func detectTraitsNext(
        nodeID: UInt64,
        remaining: [UInt16],
        endpoints: [EndpointTraitSnapshot],
        notices: [String],
        completion: @escaping @Sendable (Result<DeviceTraitSnapshot, ClusterOperationResult>) -> Void
    ) {
        guard let endpointID = remaining.first else {
            if !endpoints.isEmpty {
                LogStore.shared.log(
                    category: .dataModel, level: .info,
                    message: "特征探测完成",
                    detail: ["端点 / 设备类型": Self.deviceTypeSummary(endpoints)],
                    nodeID: nodeID
                )
            }
            completion(.success(DeviceTraitSnapshot(
                nodeID: nodeID,
                endpoints: endpoints,
                notices: notices,
                updatedAt: Date(),
                summaryReadings: Self.summaryReadings(from: endpoints)
            )))
            return
        }
        let rest = Array(remaining.dropFirst())
        ClusterToolService.shared.discoverClusters(nodeID: nodeID, endpointID: endpointID) { result in
            switch result {
            case .failure(let operation):
                var nextNotices = notices
                nextNotices.append("端点 \(endpointID)：集群列表读取失败（\(operation.message)）")
                self.detectTraitsNext(
                    nodeID: nodeID, remaining: rest, endpoints: endpoints, notices: nextNotices, completion: completion
                )
            case .success(let clusterIDs):
                let traits = DeviceTraitCatalog.traits(from: clusterIDs)
                guard !traits.isEmpty else {
                    self.detectTraitsNext(
                        nodeID: nodeID, remaining: rest, endpoints: endpoints, notices: notices, completion: completion
                    )
                    return
                }
                self.readDeviceTypes(nodeID: nodeID, endpointID: endpointID) { deviceTypeIDs in
                    self.readStates(
                        nodeID: nodeID, endpointID: endpointID,
                        keys: Self.deduped(traits.flatMap(\.attributeKeys)),
                        index: 0, values: [:], notices: []
                    ) { values, endpointNotices in
                        var next = endpoints
                        next.append(EndpointTraitSnapshot(
                            endpointID: endpointID, traits: traits, values: values,
                            notices: endpointNotices, deviceTypeIDs: deviceTypeIDs
                        ))
                        self.detectTraitsNext(
                            nodeID: nodeID, remaining: rest, endpoints: next, notices: notices, completion: completion
                        )
                    }
                }
            }
        }
    }

    /// 读取端点的设备类型列表（诊断用）。失败按空处理：标题退化为端点号，不影响特征展示。
    private func readDeviceTypes(
        nodeID: UInt64,
        endpointID: UInt16,
        completion: @escaping @Sendable ([UInt32]) -> Void
    ) {
        ClusterToolService.shared.discoverDeviceTypes(nodeID: nodeID, endpointID: endpointID) { result in
            switch result {
            case .success(let deviceTypeIDs): completion(deviceTypeIDs)
            case .failure: completion([])
            }
        }
    }

    /// 端点设备类型摘要（日志用）。
    private static func deviceTypeSummary(_ endpoints: [EndpointTraitSnapshot]) -> String {
        endpoints
            .map { "端点 \($0.endpointID)=\($0.deviceTypeText ?? "未读到")" }
            .joined(separator: "；")
    }

    /// 列表行摘要：有效读数优先，其次控制状态；同类别按展示优先级；取前 4 条。
    static func summaryReadings(from endpoints: [EndpointTraitSnapshot]) -> [TraitReading] {
        let available = endpoints.flatMap(\.readings).filter(\.isAvailable)
        let sorted = available.sorted { lhs, rhs in
            let lhsRank = lhs.trait.kind == .reading ? 0 : 1
            let rhsRank = rhs.trait.kind == .reading ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            if lhs.trait.listPriority != rhs.trait.listPriority {
                return lhs.trait.listPriority < rhs.trait.listPriority
            }
            return lhs.endpointID < rhs.endpointID
        }
        return Array(sorted.prefix(4))
    }

    // MARK: - 控制命令

    /// 开关（On/Off/Toggle）。
    func setOnOff(
        nodeID: UInt64,
        endpointID: UInt16,
        on: Bool,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        invoke(
            nodeID: nodeID, endpointID: endpointID, clusterID: 0x06,
            commandID: on ? DeviceControlCatalog.commandOn : DeviceControlCatalog.commandOff,
            fields: Self.emptyCommandFields(), label: "开关 → \(on ? "开" : "关")", completion: completion
        )
    }

    /// 识别闪烁（Identify，单位秒）。
    func identify(
        nodeID: UInt64,
        endpointID: UInt16,
        seconds: UInt16,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        let fields = MatterValueCodec.makeDataValue(from: ["0": Int(seconds)]) ?? Self.emptyCommandFields()
        invoke(
            nodeID: nodeID, endpointID: endpointID, clusterID: 0x03,
            commandID: DeviceControlCatalog.commandIdentify,
            fields: fields, label: "识别闪烁 \(seconds) 秒", completion: completion
        )
    }

    /// 设置亮度（百分比 0–100，transitionTime 单位 0.1 秒）。
    func setBrightness(
        nodeID: UInt64,
        endpointID: UInt16,
        percent: Double,
        transitionTimeTenths: UInt16 = 0,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        let level = DeviceControlCatalog.level(fromPercent: percent)
        let fields = MatterValueCodec.makeDataValue(from: [
            "0": Int(level),
            "1": Int(transitionTimeTenths),
            "2": 0,
            "3": 0,
        ]) ?? Self.emptyCommandFields()
        invoke(
            nodeID: nodeID, endpointID: endpointID, clusterID: 0x08,
            commandID: DeviceControlCatalog.commandMoveToLevelWithOnOff,
            fields: fields, label: "亮度 → \(Int(percent.rounded()))%（等级 \(level)）", completion: completion
        )
    }

    /// 设置色温（mireds，transitionTime 单位 0.1 秒）。
    func setColorTemperature(
        nodeID: UInt64,
        endpointID: UInt16,
        mireds: UInt16,
        transitionTimeTenths: UInt16 = 0,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        let fields = MatterValueCodec.makeDataValue(from: [
            "0": Int(mireds),
            "1": Int(transitionTimeTenths),
            "2": 0,
            "3": 0,
        ]) ?? Self.emptyCommandFields()
        let kelvinText = DeviceControlCatalog.kelvin(fromMireds: Double(mireds)).map { "（约 \($0) K）" } ?? ""
        invoke(
            nodeID: nodeID, endpointID: endpointID, clusterID: 0x0300,
            commandID: DeviceControlCatalog.commandMoveToColorTemperature,
            fields: fields, label: "色温 → \(mireds) mireds\(kelvinText)", completion: completion
        )
    }

    /// 设置开合位置（百分比 0–100）。
    func setLiftPercent(
        nodeID: UInt64,
        endpointID: UInt16,
        percent: Double,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        let raw = DeviceControlCatalog.percent100ths(fromPercent: percent)
        let fields = MatterValueCodec.makeDataValue(from: ["0": Int(raw)]) ?? Self.emptyCommandFields()
        invoke(
            nodeID: nodeID, endpointID: endpointID, clusterID: 0x0102,
            commandID: DeviceControlCatalog.commandGoToLiftPercentage,
            fields: fields, label: "开合 → \(Int(percent.rounded()))%", completion: completion
        )
    }

    /// 统一命令调用：结果同时进入日志台。
    private func invoke(
        nodeID: UInt64,
        endpointID: UInt16,
        clusterID: UInt32,
        commandID: UInt32,
        fields: [String: Any],
        label: String,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        ClusterToolService.shared.invokeCommand(
            nodeID: nodeID, endpointID: endpointID, clusterID: clusterID,
            commandID: commandID, commandFields: fields
        ) { result in
            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .info : .error,
                message: "控制命令\(result.isSuccess ? "成功" : "失败")：\(label)",
                detail: [
                    "端点": "\(endpointID)",
                    "集群": MatterHex.hex(clusterID, width: 4),
                    "命令": MatterHex.hex(commandID, width: 2),
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: endpointID
            )
            completion(result)
        }
    }

    // MARK: - 实时订阅

    /// 订阅控制状态属性（控制面板，页面打开期间），收到报告后在主线程回调。
    func startMonitoring(
        nodeID: UInt64,
        paths: [ControlAttributePath],
        onUpdate: @escaping @Sendable ([ClusterAttributeReport]) -> Void,
        onState: @escaping @Sendable (String) -> Void
    ) -> Bool {
        startMonitoring(role: .control, nodeID: nodeID, paths: paths, onUpdate: onUpdate, onState: onState)
    }

    /// 订阅设备特征属性（详情页「设备特征」分区，页面打开期间）。
    func startTraitMonitoring(
        nodeID: UInt64,
        paths: [ControlAttributePath],
        onUpdate: @escaping @Sendable ([ClusterAttributeReport]) -> Void,
        onState: @escaping @Sendable (String) -> Void
    ) -> Bool {
        startMonitoring(role: .traits, nodeID: nodeID, paths: paths, onUpdate: onUpdate, onState: onState)
    }

    private func startMonitoring(
        role: MonitoringRole,
        nodeID: UInt64,
        paths: [ControlAttributePath],
        onUpdate: @escaping @Sendable ([ClusterAttributeReport]) -> Void,
        onState: @escaping @Sendable (String) -> Void
    ) -> Bool {
        stopMonitoring(role: role)
        let interestedPaths: [Any] = paths.map { path in
            MTRAttributePath(
                endpointID: NSNumber(value: path.endpointID),
                clusterID: NSNumber(value: path.key.clusterID),
                attributeID: NSNumber(value: path.key.attributeID)
            )
        }
        let detail: [String: String] = [
            "来源": role.label,
            "属性数": "\(paths.count)",
        ]
        guard let token = ClusterToolService.shared.subscribe(
            nodeID: nodeID, interestedPaths: interestedPaths, detail: detail,
            onUpdate: onUpdate, onState: onState
        ) else {
            return false
        }
        lock.lock()
        subscriptionTokens[role.rawValue] = token
        lock.unlock()
        return true
    }

    /// 取消指定角色的订阅（离开页面时调用）。
    func stopMonitoring(role: MonitoringRole) {
        lock.lock()
        let token = subscriptionTokens.removeValue(forKey: role.rawValue)
        lock.unlock()
        guard let token else { return }
        ClusterToolService.shared.unsubscribe(token: token)
    }

    /// 取消全部角色的订阅。
    func stopMonitoring() {
        lock.lock()
        let tokens = Array(subscriptionTokens.values)
        subscriptionTokens.removeAll()
        lock.unlock()
        for token in tokens {
            ClusterToolService.shared.unsubscribe(token: token)
        }
    }
}