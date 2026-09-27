import Foundation
import Matter
import Observation

// MARK: - 导航路由

/// 集群工具浏览层级：端点 → 集群 → 属性 → 操作页（节点由设备详情传入）。
enum ClusterRoute: Hashable {
    case clusters(UInt64, UInt16)
    case attributes(UInt64, UInt16, UInt32)
    case operation(UInt64, UInt16, UInt32, UInt32)
}

// MARK: - 展示模型

/// 端点条目。
struct EndpointEntry: Identifiable, Sendable {
    let endpointID: UInt16
    var id: UInt16 { endpointID }
    var title: String { "端点 \(endpointID)" }
}

/// 集群条目（发现结果 + 目录命名）。
struct ClusterEntry: Identifiable, Sendable {
    let endpointID: UInt16
    let clusterID: UInt32
    var id: String { "\(endpointID)-\(clusterID)" }
    var title: String { ClusterCatalog.clusterName(clusterID) }
    var detailText: String { MatterHex.hex(clusterID, width: 4) }
}

/// 属性条目（目录 + 手动扩展）。
struct AttributeEntry: Identifiable, Sendable {
    let clusterID: UInt32
    let attributeID: UInt32
    var id: UInt32 { attributeID }
    var title: String { ClusterCatalog.attributeName(clusterID: clusterID, attributeID: attributeID) }
    var detailText: String { MatterHex.hex(attributeID, width: 4) }
}

/// 集群工具 ViewModel：端点与集群发现 / 属性浏览与读 / 写 / 命令 / 订阅。
@MainActor
@Observable
final class ClusterToolViewModel {
    // MARK: - 浏览

    var endpoints: [EndpointEntry] = []
    var endpointMessage: String?
    var isLoadingEndpoints = false
    /// 端点 → 已发现集群。
    var clustersByEndpoint: [UInt16: [ClusterEntry]] = [:]
    var isLoadingClusters: Set<UInt16> = []
    /// 手动添加的额外属性（集群 ID → 属性 ID 列表）。
    var extraAttributes: [UInt32: [UInt32]] = [:]
    var manualAttributeText = ""
    /// 手动输入校验失败提示。
    var inputError: String?

    // MARK: - 操作

    var isReading = false
    var lastResult: ClusterOperationResult?
    var writeJSON = ""
    var commandJSON = ""
    var operationError: String?

    // MARK: - 订阅

    var isSubscribed = false
    var deviceState = "未知"
    var subscriptionReports: [ClusterAttributeReport] = []
    /// 本页订阅的取消令牌（按令牌取消，避免误伤同节点上其他页面的订阅）。
    private var subscriptionToken: String?

    // MARK: - 端点 / 集群发现

    func discoverEndpoints(nodeID: UInt64) {
        guard !isLoadingEndpoints else { return }
        isLoadingEndpoints = true
        endpointMessage = "正在读取 Descriptor.PartsList…"
        ClusterToolService.shared.discoverEndpoints(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingEndpoints = false
                switch result {
                case .success(let ids):
                    self.endpoints = ids.map { EndpointEntry(endpointID: $0) }
                    self.endpointMessage = "发现 \(ids.count) 个端点"
                case .failure(let operation):
                    self.endpointMessage = operation.message
                    self.lastResult = operation
                }
            }
        }
    }

    func discoverClusters(nodeID: UInt64, endpointID: UInt16) {
        guard !isLoadingClusters.contains(endpointID) else { return }
        isLoadingClusters.insert(endpointID)
        ClusterToolService.shared.discoverClusters(nodeID: nodeID, endpointID: endpointID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingClusters.remove(endpointID)
                switch result {
                case .success(let ids):
                    self.clustersByEndpoint[endpointID] = ids.map { ClusterEntry(endpointID: endpointID, clusterID: $0) }
                case .failure(let operation):
                    self.clustersByEndpoint[endpointID] = []
                    self.lastResult = operation
                }
            }
        }
    }

    /// 集群属性列表：集群特有属性 + 全局属性 + 手动添加。
    func attributes(for clusterID: UInt32) -> [AttributeEntry] {
        var ids = Set<UInt32>()
        if let clusterAttrs = ClusterCatalog.clusterAttributes[clusterID] {
            ids.formUnion(clusterAttrs.keys)
        }
        ids.formUnion(ClusterCatalog.globalAttributes.keys)
        ids.formUnion(extraAttributes[clusterID] ?? [])
        return ids.sorted().map { AttributeEntry(clusterID: clusterID, attributeID: $0) }
    }

    func addManualAttribute(clusterID: UInt32) {
        let text = manualAttributeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributeID: UInt32?
        if text.lowercased().hasPrefix("0x") {
            attributeID = UInt32(text.dropFirst(2), radix: 16)
        } else {
            attributeID = UInt32(text)
        }
        guard let attributeID else {
            inputError = "属性 ID 无效：请输入十进制数或 0x 十六进制数"
            return
        }
        inputError = nil
        var list = extraAttributes[clusterID] ?? []
        if !list.contains(attributeID) {
            list.append(attributeID)
        }
        extraAttributes[clusterID] = list
        manualAttributeText = ""
    }

    // MARK: - 读 / 写 / 命令

    func read(nodeID: UInt64, endpointID: UInt16, clusterID: UInt32, attributeID: UInt32) {
        guard !isReading else { return }
        isReading = true
        operationError = nil
        ClusterToolService.shared.readAttribute(
            nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, attributeID: attributeID
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isReading = false
                self.lastResult = result
            }
        }
    }

    func write(nodeID: UInt64, endpointID: UInt16, clusterID: UInt32, attributeID: UInt32) {
        guard let value = parsedJSON(writeJSON) else {
            operationError = "写值 JSON 无效，请检查格式"
            return
        }
        guard let dataValue = MatterValueCodec.makeDataValue(from: value) else {
            operationError = "无法转换为 Matter 数据值：仅支持数字 / 布尔 / 字符串 / null / 数组 / {\"标签\": 值} 结构"
            return
        }
        operationError = nil
        ClusterToolService.shared.writeAttribute(
            nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, attributeID: attributeID, value: dataValue
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.lastResult = result
            }
        }
    }

    func invoke(nodeID: UInt64, endpointID: UInt16, clusterID: UInt32, commandID: UInt32) {
        guard let value = parsedJSON(commandJSON) else {
            operationError = "命令 JSON 无效，请检查格式"
            return
        }
        guard let dataValue = MatterValueCodec.makeDataValue(from: value),
              dataValue[MTRTypeKey] as? String == MTRStructureValueType else {
            operationError = "命令字段需为 JSON 对象（{\"标签\": 值}），框架会组装为结构体"
            return
        }
        operationError = nil
        ClusterToolService.shared.invokeCommand(
            nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, commandID: commandID, commandFields: dataValue
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.lastResult = result
            }
        }
    }

    private func parsedJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return object
    }

    // MARK: - 订阅

    func toggleSubscription(nodeID: UInt64, endpointID: UInt16, clusterID: UInt32, attributeID: UInt32) {
        if isSubscribed {
            unsubscribe()
            return
        }
        subscriptionReports = []
        deviceState = "未知"
        subscriptionToken = ClusterToolService.shared.subscribe(
            nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, attributeID: attributeID
        ) { [weak self] reports in
            Task { @MainActor in
                guard let self else { return }
                self.subscriptionReports.append(contentsOf: reports)
            }
        } onState: { [weak self] text in
            Task { @MainActor in
                guard let self else { return }
                self.deviceState = text
            }
        }
        isSubscribed = subscriptionToken != nil
    }

    func unsubscribe() {
        if let token = subscriptionToken {
            ClusterToolService.shared.unsubscribe(token: token)
            subscriptionToken = nil
        }
        isSubscribed = false
    }

    func clearSubscriptionReports() {
        subscriptionReports = []
    }
}
