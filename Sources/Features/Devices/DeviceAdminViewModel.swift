import Foundation
import Observation

/// 设备管理 ViewModel：fabric 归属（查看 / 移除本 fabric）→ 设备标识（NodeLabel / Location）
/// → 网络凭证（接口发现 / Wi-Fi / Thread / 移除 / 连接）。
@MainActor
@Observable
final class DeviceAdminViewModel {
    // MARK: - 状态

    var isLoadingFabrics = false
    var isLoadingIdentity = false
    var isLoadingInterfaces = false
    /// 最近一次操作结果（状态码 / 耗时 / 原始响应）。
    var lastOperation: ClusterOperationResult?
    var message: String?

    // MARK: - Fabric 归属

    var fabrics: [FabricEntryInfo] = []
    var isRemovingFabric = false

    /// 本机控制器对应的设备侧 fabric 索引（未匹配到时为 nil）。
    var localFabricIndex: UInt8? {
        fabrics.first(where: \.isLocal)?.fabricIndex
    }

    // MARK: - 设备标识

    var nodeLabelDraft = ""
    var locationDraft = ""
    /// 已读回的值（用于判断草稿是否变更）。
    private var savedNodeLabel = ""
    private var savedLocation = ""
    var isSavingNodeLabel = false
    var isSavingLocation = false

    var isNodeLabelDirty: Bool { nodeLabelDraft != savedNodeLabel }
    var isLocationDirty: Bool { locationDraft != savedLocation }
    var isNodeLabelValid: Bool { nodeLabelDraft.count <= 32 }
    var isLocationValid: Bool { locationDraft.count <= 2 }

    // MARK: - 网络凭证

    var interfaces: [NetworkInterfaceInfo] = []
    var selectedEndpointID: UInt16?
    var wifiSSID = ""
    var wifiPassword = ""
    var threadDatasetHex = ""
    /// 正在进行的网络操作标识（形如 "wifi-0" / "remove-0-3"）。
    var pendingNetworkAction: String?

    var selectedInterface: NetworkInterfaceInfo? {
        guard let selectedEndpointID else { return nil }
        return interfaces.first { $0.endpointID == selectedEndpointID }
    }

    var isSSIDValid: Bool { !wifiSSID.isEmpty && Data(wifiSSID.utf8).count <= 32 }
    var isPasswordValid: Bool {
        let count = Data(wifiPassword.utf8).count
        return count >= 8 && count <= 63
    }
    var isThreadDatasetValid: Bool {
        guard let data = Data(hexString: threadDatasetHex) else { return false }
        return data.count >= 4
    }

    // MARK: - 载入

    func load(nodeID: UInt64) {
        loadFabrics(nodeID: nodeID)
        loadIdentity(nodeID: nodeID)
        loadInterfaces(nodeID: nodeID)
    }

    func refresh(nodeID: UInt64) {
        load(nodeID: nodeID)
    }

    // MARK: - Fabric

    func loadFabrics(nodeID: UInt64) {
        guard !isLoadingFabrics else { return }
        isLoadingFabrics = true
        DeviceAdminService.shared.readFabrics(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingFabrics = false
                switch result {
                case .success(let entries):
                    self.fabrics = entries
                    if entries.isEmpty {
                        self.message = "设备未报告任何 fabric（Fabrics 属性为空）。"
                    }
                case .failure(let operation):
                    self.fabrics = []
                    self.message = "Fabric 列表读取失败：\(operation.message)"
                }
            }
        }
    }

    /// 移除设备上属于本机控制器的 fabric（设备退网，破坏性操作）。
    func removeLocalFabric(nodeID: UInt64) {
        guard let fabricIndex = localFabricIndex, !isRemovingFabric else { return }
        isRemovingFabric = true
        message = nil
        DeviceAdminService.shared.removeFabric(nodeID: nodeID, fabricIndex: fabricIndex) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRemovingFabric = false
                self.lastOperation = result
                if result.isSuccess {
                    self.message = result.message + "；已从本地设备列表移除该节点。"
                    self.fabrics.removeAll { $0.fabricIndex == fabricIndex }
                } else {
                    self.message = result.message
                }
            }
        }
    }

    // MARK: - 设备标识

    func loadIdentity(nodeID: UInt64) {
        guard !isLoadingIdentity else { return }
        isLoadingIdentity = true
        DeviceAdminService.shared.readIdentity(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingIdentity = false
                switch result {
                case .success(let info):
                    self.savedNodeLabel = info.nodeLabel
                    self.savedLocation = info.location
                    self.nodeLabelDraft = info.nodeLabel
                    self.locationDraft = info.location
                case .failure(let operation):
                    self.message = "设备标识读取失败：\(operation.message)"
                }
            }
        }
    }

    func saveNodeLabel(nodeID: UInt64) {
        guard !isSavingNodeLabel, isNodeLabelValid else { return }
        isSavingNodeLabel = true
        let label = nodeLabelDraft
        DeviceAdminService.shared.writeNodeLabel(nodeID: nodeID, label: label) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isSavingNodeLabel = false
                self.lastOperation = result
                if result.isSuccess {
                    self.savedNodeLabel = label
                } else {
                    self.message = result.message
                }
            }
        }
    }

    func saveLocation(nodeID: UInt64) {
        guard !isSavingLocation, isLocationValid else { return }
        isSavingLocation = true
        let location = locationDraft
        DeviceAdminService.shared.writeLocation(nodeID: nodeID, location: location) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isSavingLocation = false
                self.lastOperation = result
                if result.isSuccess {
                    self.savedLocation = location
                } else {
                    self.message = result.message
                }
            }
        }
    }

    // MARK: - 网络接口 / 凭证

    func loadInterfaces(nodeID: UInt64) {
        guard !isLoadingInterfaces else { return }
        isLoadingInterfaces = true
        DeviceAdminService.shared.discoverNetworkInterfaces(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingInterfaces = false
                switch result {
                case .success(let interfaces):
                    self.interfaces = interfaces
                    if interfaces.isEmpty {
                        self.message = "设备未报告 Network Commissioning 集群（0x31），无法管理网络凭证。"
                    } else if let selected = self.selectedEndpointID,
                              !interfaces.contains(where: { $0.endpointID == selected }) {
                        self.selectedEndpointID = interfaces.first?.endpointID
                    } else if self.selectedEndpointID == nil {
                        self.selectedEndpointID = interfaces.first?.endpointID
                    }
                case .failure(let operation):
                    self.interfaces = []
                    self.message = "网络接口发现失败：\(operation.message)"
                }
            }
        }
    }

    /// 仅重新读取已配置网络列表（不重做接口发现）。
    func reloadNetworks(nodeID: UInt64) {
        loadInterfaces(nodeID: nodeID)
    }

    func addOrUpdateWiFi(nodeID: UInt64) {
        guard let endpointID = selectedEndpointID, isSSIDValid, isPasswordValid else { return }
        let ssid = wifiSSID
        let password = wifiPassword
        runNetworkOperation(nodeID: nodeID, key: "wifi-\(endpointID)") { completion in
            DeviceAdminService.shared.updateWiFiNetwork(
                nodeID: nodeID, endpointID: endpointID,
                ssid: ssid, password: password, completion: completion
            )
        } then: { [weak self] in
            self?.wifiPassword = ""
            self?.reloadNetworks(nodeID: nodeID)
        }
    }

    func addOrUpdateThread(nodeID: UInt64) {
        guard let endpointID = selectedEndpointID, isThreadDatasetValid else { return }
        let datasetHex = threadDatasetHex
        runNetworkOperation(nodeID: nodeID, key: "thread-\(endpointID)") { completion in
            DeviceAdminService.shared.updateThreadNetwork(
                nodeID: nodeID, endpointID: endpointID,
                datasetHex: datasetHex, completion: completion
            )
        } then: { [weak self] in
            self?.reloadNetworks(nodeID: nodeID)
        }
    }

    func removeNetwork(nodeID: UInt64, networkIDHex: String) {
        guard let endpointID = selectedEndpointID else { return }
        runNetworkOperation(nodeID: nodeID, key: "remove-\(endpointID)-\(networkIDHex)") { completion in
            DeviceAdminService.shared.removeNetwork(
                nodeID: nodeID, endpointID: endpointID,
                networkIDHex: networkIDHex, completion: completion
            )
        } then: { [weak self] in
            self?.reloadNetworks(nodeID: nodeID)
        }
    }

    func connectNetwork(nodeID: UInt64, networkIDHex: String) {
        guard let endpointID = selectedEndpointID else { return }
        runNetworkOperation(nodeID: nodeID, key: "connect-\(endpointID)-\(networkIDHex)") { completion in
            DeviceAdminService.shared.connectNetwork(
                nodeID: nodeID, endpointID: endpointID,
                networkIDHex: networkIDHex, completion: completion
            )
        } then: { [weak self] in
            self?.reloadNetworks(nodeID: nodeID)
        }
    }

    func isPending(_ key: String) -> Bool { pendingNetworkAction == key }

    /// 网络操作统一流程：置进行中 → 记录结果 → 成功后刷新网络列表。
    private func runNetworkOperation(
        nodeID: UInt64,
        key: String,
        operation: @escaping @Sendable (@escaping @Sendable (ClusterOperationResult) -> Void) -> Void,
        then afterSuccess: @escaping @MainActor () -> Void
    ) {
        guard pendingNetworkAction == nil else { return }
        pendingNetworkAction = key
        message = nil
        operation { result in
            Task { @MainActor in
                self.pendingNetworkAction = nil
                self.lastOperation = result
                if result.isSuccess {
                    afterSuccess()
                } else {
                    self.message = result.message
                }
            }
        }
    }

    func clearMessage() {
        message = nil
    }
}