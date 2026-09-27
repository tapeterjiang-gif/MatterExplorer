import Foundation
import Matter
import os

// MARK: - 值类型（跨线程安全）

/// 设备侧 fabric 条目（Operational Credentials / Fabrics 属性解析结果）。
struct FabricEntryInfo: Identifiable, Sendable, Hashable {
    let fabricIndex: UInt8
    let rootPublicKeyHex: String
    let vendorID: UInt32
    let fabricID: UInt64
    let nodeID: UInt64
    let label: String
    /// 是否属于本机 App 的控制器（按 fabric 根公钥匹配）。
    let isLocal: Bool

    var id: UInt8 { fabricIndex }

    var vendorText: String { MatterHex.hex(vendorID) }
    var labelText: String { label.isEmpty ? "（空）" : label }
}

/// 已配置网络条目（Network Commissioning / Networks 属性解析结果）。
struct ConfiguredNetworkInfo: Identifiable, Sendable, Hashable {
    let networkIDHex: String
    let connected: Bool

    var id: String { networkIDHex }
    /// 展示用短 ID（完整 networkID 较长，日志与列表均以短 ID 呈现）。
    var shortID: String { String(networkIDHex.prefix(16)) }
}

/// 网络接口条目：某端点上的一个 Network Commissioning 集群实例。
struct NetworkInterfaceInfo: Identifiable, Sendable, Hashable {
    let endpointID: UInt16
    /// 支持的网络类型（来自 FeatureMap 位掩码）。
    let kinds: [DeviceNetworkKind]
    var networks: [ConfiguredNetworkInfo]

    var id: UInt16 { endpointID }

    var supportsWiFi: Bool { kinds.isEmpty || kinds.contains(.wifi) }
    var supportsThread: Bool { kinds.isEmpty || kinds.contains(.thread) }
    var kindsText: String { kinds.isEmpty ? "类型未识别" : kinds.map(\.label).joined(separator: " / ") }
}

/// 设备标识（Basic Information 的 NodeLabel / Location）。
struct DeviceIdentityInfo: Sendable, Equatable {
    var nodeLabel: String = ""
    var location: String = ""
}

// MARK: - 服务

/// 设备管理服务：fabric 归属查看与移除（RemoveFabric）、设备标识写入（NodeLabel / Location）、
/// 网络凭证增删连（Network Commissioning AddOrUpdateWiFi/Thread、RemoveNetwork、ConnectNetwork）。
/// 使用 Matter 类型化集群 API（MTRBaseCluster*），字段标签与状态码由框架转换，避免手写字典出错。
final class DeviceAdminService: @unchecked Sendable {
    static let shared = DeviceAdminService()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.example.MatterExplorer", category: "DeviceAdmin")
    private let queue = DispatchQueue(label: "com.example.MatterExplorer.deviceAdmin")

    /// Network Commissioning 的 breadcrumb：非零且单调变化即可（用于识别被中断的操作序列）。
    private var breadcrumb: UInt32 = 1

    // MARK: - 集群实例

    private func operationalCredentials(nodeID: UInt64, endpointID: UInt16 = 0) -> MTRBaseClusterOperationalCredentials? {
        guard let device = ClusterToolService.shared.baseDevice(nodeID: nodeID) else { return nil }
        return MTRBaseClusterOperationalCredentials(
            device: device, endpointID: NSNumber(value: endpointID), queue: queue
        )
    }

    private func networkCommissioning(nodeID: UInt64, endpointID: UInt16) -> MTRBaseClusterNetworkCommissioning? {
        guard let device = ClusterToolService.shared.baseDevice(nodeID: nodeID) else { return nil }
        return MTRBaseClusterNetworkCommissioning(
            device: device, endpointID: NSNumber(value: endpointID), queue: queue
        )
    }

    private func basicInformation(nodeID: UInt64) -> MTRBaseClusterBasicInformation? {
        guard let device = ClusterToolService.shared.baseDevice(nodeID: nodeID) else { return nil }
        return MTRBaseClusterBasicInformation(
            device: device, endpointID: NSNumber(value: 0), queue: queue
        )
    }

    private func nextBreadcrumb() -> NSNumber {
        lock.lock(); defer { lock.unlock() }
        breadcrumb &+= 1
        if breadcrumb == 0 { breadcrumb = 1 }
        return NSNumber(value: breadcrumb)
    }

    // MARK: - Fabric 归属

    /// 读取设备 Fabrics 属性，标记哪些条目属于本机控制器。
    func readFabrics(
        nodeID: UInt64,
        completion: @escaping @Sendable (Result<[FabricEntryInfo], ClusterOperationResult>) -> Void
    ) {
        guard let cluster = operationalCredentials(nodeID: nodeID) else {
            completion(.failure(Self.missingController(nodeID: nodeID)))
            return
        }
        let start = Date()
        cluster.readAttributeFabrics(with: nil) { value, error in
            if let error {
                let result = Self.failure(nodeID: nodeID, start: start, error: error)
                LogStore.shared.log(
                    category: .dataModel, level: .error, message: "读取 Fabrics 属性失败",
                    detail: ["集群": "0x003E", "属性": "0x0001", "结果": result.message], nodeID: nodeID
                )
                completion(.failure(result))
                return
            }

            let descriptors = (value as? [MTROperationalCredentialsClusterFabricDescriptorStruct]) ?? []
            let localKeys = Self.localRootPublicKeys()
            // knownFabrics 不可用时的兜底：按控制器 nodeID 匹配。
            let fallbackNodeID = localKeys.isEmpty
                ? MatterManager.shared.controller?.controllerNodeID?.uint64Value
                : nil

            let entries = descriptors.map { descriptor -> FabricEntryInfo in
                let nodeIDValue = descriptor.nodeID.uint64Value
                let matchedByKey = localKeys.contains(descriptor.rootPublicKey)
                let matchedByNode = fallbackNodeID.map { $0 == nodeIDValue } ?? false
                return FabricEntryInfo(
                    fabricIndex: UInt8(clamping: descriptor.fabricIndex.intValue),
                    rootPublicKeyHex: descriptor.rootPublicKey.hexString,
                    vendorID: descriptor.vendorID.uint32Value,
                    fabricID: descriptor.fabricID.uint64Value,
                    nodeID: nodeIDValue,
                    label: descriptor.label,
                    isLocal: matchedByKey || matchedByNode
                )
            }
            .sorted { $0.fabricIndex < $1.fabricIndex }

            LogStore.shared.log(
                category: .dataModel, level: .info, message: "已读取设备 fabric 列表",
                detail: [
                    "集群": "0x003E",
                    "fabric 数": "\(entries.count)",
                    "本 fabric 索引": entries.first(where: \.isLocal).map { "\($0.fabricIndex)" } ?? "未匹配",
                ],
                nodeID: nodeID
            )
            completion(.success(entries))
        }
    }

    /// 移除设备上属于本机控制器的 fabric（设备退网）。成功后同步清理本地注册表记录。
    func removeFabric(
        nodeID: UInt64,
        fabricIndex: UInt8,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let cluster = operationalCredentials(nodeID: nodeID) else {
            completion(Self.missingController(nodeID: nodeID))
            return
        }
        let params = MTROperationalCredentialsClusterRemoveFabricParams()
        params.fabricIndex = NSNumber(value: fabricIndex)

        let start = Date()
        cluster.removeFabric(with: params) { response, error in
            let result: ClusterOperationResult
            if let error {
                result = Self.failure(nodeID: nodeID, start: start, error: error)
            } else if let status = response?.statusCode.uint8Value, status != 0 {
                result = Self.failure(
                    nodeID: nodeID, start: start,
                    message: "移除 fabric 失败：\(Self.nocStatusText(status))",
                    json: response?.debugText
                )
            } else {
                result = Self.success(
                    nodeID: nodeID, start: start,
                    message: "已移除设备上的本 fabric（索引 \(fabricIndex)），设备已退网"
                )
            }

            if result.isSuccess {
                DeviceRegistry.shared.remove(nodeID: nodeID)
                DeviceService.shared.stopMonitoring(nodeIDs: [nodeID])
            }

            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .warning : .error,
                message: "RemoveFabric\(result.isSuccess ? "成功" : "失败")",
                detail: [
                    "集群": "0x003E", "命令": "RemoveFabric (0x0A)",
                    "fabricIndex": "\(fabricIndex)",
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: 0
            )
            completion(result)
        }
    }

    // MARK: - 设备标识（Basic Information 0x28）

    /// 读取 NodeLabel / Location。
    func readIdentity(
        nodeID: UInt64,
        completion: @escaping @Sendable (Result<DeviceIdentityInfo, ClusterOperationResult>) -> Void
    ) {
        guard let cluster = basicInformation(nodeID: nodeID) else {
            completion(.failure(Self.missingController(nodeID: nodeID)))
            return
        }
        // MTRBaseCluster* 未标注 Sendable；框架保证按 queue 串行回调，跨闭包共享是安全的。
        nonisolated(unsafe) let readCluster = cluster
        let start = Date()
        cluster.readAttributeNodeLabel { labelValue, labelError in
            if let labelError {
                completion(.failure(Self.failure(nodeID: nodeID, start: start, error: labelError)))
                return
            }
            readCluster.readAttributeLocation { locationValue, locationError in
                if let locationError {
                    completion(.failure(Self.failure(nodeID: nodeID, start: start, error: locationError)))
                    return
                }
                let info = DeviceIdentityInfo(
                    nodeLabel: labelValue ?? "", location: locationValue ?? ""
                )
                LogStore.shared.log(
                    category: .dataModel, level: .info, message: "已读取设备标识",
                    detail: [
                        "NodeLabel": info.nodeLabel.isEmpty ? "（空）" : info.nodeLabel,
                        "Location": info.location.isEmpty ? "（空）" : info.location,
                    ],
                    nodeID: nodeID, endpointID: 0
                )
                completion(.success(info))
            }
        }
    }

    /// 写入 NodeLabel（最长 32 字符）。
    func writeNodeLabel(
        nodeID: UInt64,
        label: String,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let cluster = basicInformation(nodeID: nodeID) else {
            completion(Self.missingController(nodeID: nodeID))
            return
        }
        let start = Date()
        cluster.writeAttributeNodeLabel(withValue: label) { error in
            let result = error.map { Self.failure(nodeID: nodeID, start: start, error: $0) }
                ?? Self.success(nodeID: nodeID, start: start, message: "NodeLabel 已写入")
            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .info : .error,
                message: "写入 NodeLabel\(result.isSuccess ? "成功" : "失败")",
                detail: [
                    "集群": "0x0028", "属性": "NodeLabel (0x0005)",
                    "值": label.isEmpty ? "（空）" : label,
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: 0
            )
            completion(result)
        }
    }

    /// 写入 Location（ISO 3166-1 alpha-2，最长 2 字符）。
    func writeLocation(
        nodeID: UInt64,
        location: String,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let cluster = basicInformation(nodeID: nodeID) else {
            completion(Self.missingController(nodeID: nodeID))
            return
        }
        let start = Date()
        cluster.writeAttributeLocation(withValue: location) { error in
            let result = error.map { Self.failure(nodeID: nodeID, start: start, error: $0) }
                ?? Self.success(nodeID: nodeID, start: start, message: "Location 已写入")
            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .info : .error,
                message: "写入 Location\(result.isSuccess ? "成功" : "失败")",
                detail: [
                    "集群": "0x0028", "属性": "Location (0x0006)",
                    "值": location.isEmpty ? "（空）" : location,
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: 0
            )
            completion(result)
        }
    }

    // MARK: - 网络接口发现（Network Commissioning 0x31）

    /// 发现设备上所有 Network Commissioning 实例（端点 + 接口类型 + 已配置网络）。
    func discoverNetworkInterfaces(
        nodeID: UInt64,
        completion: @escaping @Sendable (Result<[NetworkInterfaceInfo], ClusterOperationResult>) -> Void
    ) {
        ClusterToolService.shared.discoverEndpoints(nodeID: nodeID) { result in
            switch result {
            case .failure(let operation):
                completion(.failure(operation))
            case .success(let endpoints):
                self.probeInterfaces(
                    nodeID: nodeID, remaining: endpoints, accumulated: [], completion: completion
                )
            }
        }
    }

    private func probeInterfaces(
        nodeID: UInt64,
        remaining: [UInt16],
        accumulated: [NetworkInterfaceInfo],
        completion: @escaping @Sendable (Result<[NetworkInterfaceInfo], ClusterOperationResult>) -> Void
    ) {
        guard let endpointID = remaining.first else {
            LogStore.shared.log(
                category: .dataModel, level: .info, message: "已发现网络接口",
                detail: [
                    "接口数": "\(accumulated.count)",
                    "端点": accumulated.map { "\($0.endpointID)(\($0.kindsText))" }.joined(separator: "、"),
                ],
                nodeID: nodeID
            )
            completion(.success(accumulated))
            return
        }
        let rest = Array(remaining.dropFirst())
        let base = accumulated

        ClusterToolService.shared.discoverClusters(nodeID: nodeID, endpointID: endpointID) { result in
            let clusters = (try? result.get()) ?? []
            guard clusters.contains(0x31), let cluster = self.networkCommissioning(nodeID: nodeID, endpointID: endpointID) else {
                self.probeInterfaces(nodeID: nodeID, remaining: rest, accumulated: base, completion: completion)
                return
            }
            // MTRBaseCluster* 未标注 Sendable；框架保证按 queue 串行回调，跨闭包共享是安全的。
            nonisolated(unsafe) let probeCluster = cluster
            cluster.readAttributeFeatureMap { featureValue, _ in
                let kinds = Self.networkKinds(fromFeatureMap: featureValue?.uint32Value ?? 0)
                probeCluster.readAttributeNetworks { networkValue, _ in
                    let networks = ((networkValue as? [MTRNetworkCommissioningClusterNetworkInfoStruct]) ?? [])
                        .map { ConfiguredNetworkInfo(networkIDHex: $0.networkID.hexString, connected: $0.connected.boolValue) }
                    var next = base
                    next.append(NetworkInterfaceInfo(endpointID: endpointID, kinds: kinds, networks: networks))
                    self.probeInterfaces(nodeID: nodeID, remaining: rest, accumulated: next, completion: completion)
                }
            }
        }
    }

    // MARK: - 网络凭证操作

    /// 添加 / 更新 Wi-Fi 网络（AddOrUpdateWiFiNetwork 0x02）。
    func updateWiFiNetwork(
        nodeID: UInt64,
        endpointID: UInt16,
        ssid: String,
        password: String,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let cluster = networkCommissioning(nodeID: nodeID, endpointID: endpointID) else {
            completion(Self.missingController(nodeID: nodeID))
            return
        }
        let params = MTRNetworkCommissioningClusterAddOrUpdateWiFiNetworkParams()
        params.ssid = Data(ssid.utf8)
        params.credentials = Data(password.utf8)
        params.breadcrumb = nextBreadcrumb()

        let start = Date()
        cluster.addOrUpdateWiFiNetwork(with: params) { response, error in
            let result = Self.configResult(
                nodeID: nodeID, start: start,
                action: "添加 / 更新 Wi-Fi 网络「\(ssid)」",
                status: response?.networkingStatus, debugText: response?.debugText, error: error
            )
            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .info : .error,
                message: "Wi-Fi 网络配置\(result.isSuccess ? "成功" : "失败")",
                detail: [
                    "端点": "\(endpointID)", "命令": "AddOrUpdateWiFiNetwork (0x02)",
                    "SSID": ssid, "SSID 长度": "\(Data(ssid.utf8).count) 字节",
                    "networkIndex": response?.networkIndex.map { "\($0)" } ?? "—",
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: endpointID
            )
            completion(result)
        }
    }

    /// 添加 / 更新 Thread 网络（AddOrUpdateThreadNetwork 0x03）。
    func updateThreadNetwork(
        nodeID: UInt64,
        endpointID: UInt16,
        datasetHex: String,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let dataset = Data(hexString: datasetHex) else {
            completion(ClusterOperationResult(
                isSuccess: false, message: "Thread operational dataset 不是合法十六进制",
                json: nil, duration: 0, nodeID: nodeID
            ))
            return
        }
        guard let cluster = networkCommissioning(nodeID: nodeID, endpointID: endpointID) else {
            completion(Self.missingController(nodeID: nodeID))
            return
        }
        let params = MTRNetworkCommissioningClusterAddOrUpdateThreadNetworkParams()
        params.operationalDataset = dataset
        params.breadcrumb = nextBreadcrumb()

        let start = Date()
        cluster.addOrUpdateThreadNetwork(with: params) { response, error in
            let result = Self.configResult(
                nodeID: nodeID, start: start,
                action: "添加 / 更新 Thread 网络",
                status: response?.networkingStatus, debugText: response?.debugText, error: error
            )
            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .info : .error,
                message: "Thread 网络配置\(result.isSuccess ? "成功" : "失败")",
                detail: [
                    "端点": "\(endpointID)", "命令": "AddOrUpdateThreadNetwork (0x03)",
                    "dataset 长度": "\(dataset.count) 字节",
                    "networkIndex": response?.networkIndex.map { "\($0)" } ?? "—",
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: endpointID
            )
            completion(result)
        }
    }

    /// 移除网络凭证（RemoveNetwork 0x04）。
    func removeNetwork(
        nodeID: UInt64,
        endpointID: UInt16,
        networkIDHex: String,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let networkID = Data(hexString: networkIDHex) else {
            completion(ClusterOperationResult(
                isSuccess: false, message: "networkID 不是合法十六进制",
                json: nil, duration: 0, nodeID: nodeID
            ))
            return
        }
        guard let cluster = networkCommissioning(nodeID: nodeID, endpointID: endpointID) else {
            completion(Self.missingController(nodeID: nodeID))
            return
        }
        let params = MTRNetworkCommissioningClusterRemoveNetworkParams()
        params.networkID = networkID
        params.breadcrumb = nextBreadcrumb()

        let start = Date()
        cluster.removeNetwork(with: params) { response, error in
            let result = Self.configResult(
                nodeID: nodeID, start: start,
                action: "移除网络凭证",
                status: response?.networkingStatus, debugText: response?.debugText, error: error
            )
            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .info : .error,
                message: "移除网络凭证\(result.isSuccess ? "成功" : "失败")",
                detail: [
                    "端点": "\(endpointID)", "命令": "RemoveNetwork (0x04)",
                    "networkID": networkIDHex,
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: endpointID
            )
            completion(result)
        }
    }

    /// 连接网络（ConnectNetwork 0x06）。
    func connectNetwork(
        nodeID: UInt64,
        endpointID: UInt16,
        networkIDHex: String,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let networkID = Data(hexString: networkIDHex) else {
            completion(ClusterOperationResult(
                isSuccess: false, message: "networkID 不是合法十六进制",
                json: nil, duration: 0, nodeID: nodeID
            ))
            return
        }
        guard let cluster = networkCommissioning(nodeID: nodeID, endpointID: endpointID) else {
            completion(Self.missingController(nodeID: nodeID))
            return
        }
        let params = MTRNetworkCommissioningClusterConnectNetworkParams()
        params.networkID = networkID
        params.breadcrumb = nextBreadcrumb()

        let start = Date()
        cluster.connectNetwork(with: params) { response, error in
            var result = Self.configResult(
                nodeID: nodeID, start: start,
                action: "连接网络",
                status: response?.networkingStatus, debugText: response?.debugText, error: error
            )
            // ConnectNetwork 会额外返回设备侧错误值（如 Thread 附着失败原因）。
            if let errorValue = response?.errorValue, result.isSuccess {
                result = ClusterOperationResult(
                    isSuccess: true,
                    message: "\(result.message)（设备错误值 \(errorValue)）",
                    json: result.json, duration: result.duration, nodeID: nodeID
                )
            }
            LogStore.shared.log(
                category: .dataModel, level: result.isSuccess ? .info : .error,
                message: "连接网络\(result.isSuccess ? "成功" : "失败")",
                detail: [
                    "端点": "\(endpointID)", "命令": "ConnectNetwork (0x06)",
                    "networkID": networkIDHex,
                    "设备错误值": response?.errorValue.map { "\($0)" } ?? "—",
                    "耗时": result.durationText,
                    "结果": result.message,
                ],
                nodeID: nodeID, endpointID: endpointID
            )
            completion(result)
        }
    }

    // MARK: - 结果组装

    private static func missingController(nodeID: UInt64) -> ClusterOperationResult {
        ClusterOperationResult(
            isSuccess: false, message: "Matter 控制器未就绪", json: nil, duration: 0, nodeID: nodeID
        )
    }

    private static func success(nodeID: UInt64, start: Date, message: String) -> ClusterOperationResult {
        ClusterOperationResult(
            isSuccess: true, message: message, json: nil,
            duration: Date().timeIntervalSince(start), nodeID: nodeID
        )
    }

    private static func failure(
        nodeID: UInt64, start: Date, message: String, json: String? = nil
    ) -> ClusterOperationResult {
        ClusterOperationResult(
            isSuccess: false, message: message, json: json,
            duration: Date().timeIntervalSince(start), nodeID: nodeID
        )
    }

    private static func failure(nodeID: UInt64, start: Date, error: Error) -> ClusterOperationResult {
        ClusterOperationResult(
            isSuccess: false, message: MatterErrorDictionary.description(for: error), json: nil,
            duration: Date().timeIntervalSince(start), nodeID: nodeID
        )
    }

    /// 网络凭证类命令的统一结果：非成功状态码转中文说明。
    private static func configResult(
        nodeID: UInt64, start: Date, action: String,
        status: NSNumber?, debugText: String?, error: Error?
    ) -> ClusterOperationResult {
        if let error {
            return failure(nodeID: nodeID, start: start, error: error)
        }
        let code = status?.uint8Value ?? 0
        guard code != 0 else {
            return success(nodeID: nodeID, start: start, message: "\(action)完成")
        }
        return failure(
            nodeID: nodeID, start: start,
            message: "\(action)失败：\(networkStatusText(code))",
            json: debugText
        )
    }

    // MARK: - 状态码 / 密钥

    /// NetworkCommissioning FeatureMap 位掩码 → 支持的网络类型（0=Wi-Fi，1=Thread，2=Ethernet）。
    private static func networkKinds(fromFeatureMap raw: UInt32) -> [DeviceNetworkKind] {
        var kinds: [DeviceNetworkKind] = []
        if raw & 0x1 != 0 { kinds.append(.wifi) }
        if raw & 0x2 != 0 { kinds.append(.thread) }
        if raw & 0x4 != 0 { kinds.append(.ethernet) }
        return kinds
    }

    /// NetworkCommissioningStatus（规范 §11.9.4.4）中文说明。
    private static func networkStatusText(_ code: UInt8) -> String {
        switch code {
        case 0x01: "参数超出范围"
        case 0x02: "超出设备网络列表容量"
        case 0x03: "未找到该 networkID"
        case 0x04: "networkID 重复"
        case 0x05: "未找到网络（信号或信道不匹配）"
        case 0x06: "监管限制错误"
        case 0x07: "认证失败：请检查 SSID / 密码或 Thread 凭证"
        case 0x08: "不支持的安全类型"
        case 0x09: "连接失败"
        case 0x0A: "IPv6 地址获取失败"
        case 0x0B: "IPv6 地址绑定失败"
        case 0x0C: "未知错误"
        default: "状态码 \(MatterHex.hex(code))"
        }
    }

    /// NodeOperationalCertStatus（规范 §11.18.5.1）中文说明。
    private static func nocStatusText(_ code: UInt8) -> String {
        switch code {
        case 0x01: "公钥无效"
        case 0x02: "节点操作 ID 无效"
        case 0x03: "NOC 无效"
        case 0x04: "缺少 CSR"
        case 0x05: "设备 fabric 表已满"
        case 0x06: "管理员主体无效"
        case 0x09: "fabric 冲突"
        case 0x0A: "fabric 标签冲突"
        case 0x0B: "fabric 索引无效（可能已被移除）"
        default: "状态码 \(MatterHex.hex(code))"
        }
    }

    /// 本机控制器已持 fabric 的根公钥集合（用于在设备 Fabrics 列表中识别「本 fabric」）。
    private static func localRootPublicKeys() -> Set<Data> {
        let fabrics = MTRDeviceControllerFactory.sharedInstance().knownFabrics ?? []
        return Set(fabrics.map(\.rootPublicKey))
    }
}