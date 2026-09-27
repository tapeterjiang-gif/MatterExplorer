import Foundation
import Observation

/// 设备特征 ViewModel：特征探测 → 详情页订阅实时回填 → 卡片内嵌控件复用控制逻辑。
@MainActor
@Observable
final class DeviceTraitViewModel {
    /// 当前特征快照。
    var snapshot: DeviceTraitSnapshot?
    var isLoading = false
    var message: String?
    /// 设备在线状态（订阅回传）。
    var deviceState = "未知"
    var isSubscribed = false

    /// 特征卡片内嵌控件复用同一份控制逻辑（草稿 / 进行中 / 失败回滚）。
    let control = DeviceControlViewModel()

    // MARK: - 加载

    /// 页面出现时调用：已有快照则仅重启订阅，否则重新探测。
    func activate(nodeID: UInt64) {
        if snapshot == nil {
            load(nodeID: nodeID)
        } else {
            startSubscription(nodeID: nodeID)
        }
    }

    func load(nodeID: UInt64) {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        DeviceControlService.shared.detectTraits(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let snapshot):
                    self.apply(snapshot)
                    self.startSubscription(nodeID: nodeID)
                case .failure(let operation):
                    self.snapshot = nil
                    self.message = "设备特征读取失败：\(operation.message)"
                }
            }
        }
    }

    // MARK: - 订阅

    /// 订阅特征属性；离开页面时取消。
    func startSubscription(nodeID: UInt64) {
        guard let snapshot else { return }
        let paths = snapshot.endpoints.flatMap { endpoint in
            endpoint.traits.flatMap(\.attributeKeys).map {
                ControlAttributePath(endpointID: endpoint.endpointID, key: $0)
            }
        }
        guard !paths.isEmpty else { return }
        isSubscribed = DeviceControlService.shared.startTraitMonitoring(
            nodeID: nodeID,
            paths: paths,
            onUpdate: { [weak self] reports in
                Task { @MainActor in
                    self?.applyReports(reports)
                }
            },
            onState: { [weak self] text in
                Task { @MainActor in
                    self?.deviceState = text
                }
            }
        )
        if !isSubscribed {
            message = "订阅未建立：Matter 控制器未就绪（读数不会实时更新，可点击「重新读取特征」）。"
        }
    }

    func stopSubscription() {
        DeviceControlService.shared.stopMonitoring(role: .traits)
        isSubscribed = false
    }

    // MARK: - 应用快照

    /// 写入快照：更新缓存，并把可交互特征映射为控制面板快照供卡片控件使用。
    private func apply(_ snapshot: DeviceTraitSnapshot) {
        self.snapshot = snapshot
        DeviceTraitCache.shared.store(snapshot)

        var detection = DeviceControlDetection()
        detection.endpoints = snapshot.endpoints.compactMap { endpoint in
            let capabilities = endpoint.traits.compactMap(\.controlCapability)
            guard !capabilities.isEmpty else { return nil }
            return EndpointControlSnapshot(
                endpointID: endpoint.endpointID,
                capabilities: capabilities,
                values: endpoint.values,
                notices: endpoint.notices
            )
        }
        control.detection = detection
        control.syncDrafts()
    }

    /// 订阅报告 → 回填属性值并重建快照（仅本页已展示的特征属性）。
    private func applyReports(_ reports: [ClusterAttributeReport]) {
        guard let snapshot else { return }
        var updates: [UInt16: [ControlAttributeKey: MatterScalar]] = [:]
        for report in reports {
            guard !report.isError,
                  let endpointID = report.endpointID,
                  let clusterID = report.clusterID,
                  let attributeID = report.attributeID,
                  let scalar = report.scalar,
                  let endpoint = snapshot.endpoints.first(where: { $0.endpointID == endpointID }) else { continue }
            let key = ControlAttributeKey(clusterID: clusterID, attributeID: attributeID)
            guard endpoint.traits.contains(where: { $0.attributeKeys.contains(key) }) else { continue }
            updates[endpointID, default: [:]][key] = scalar
        }
        guard !updates.isEmpty else { return }
        let endpoints = snapshot.endpoints.map { endpoint -> EndpointTraitSnapshot in
            guard let values = updates[endpoint.endpointID] else { return endpoint }
            var merged = endpoint.values
            merged.merge(values) { _, new in new }
            return EndpointTraitSnapshot(
                endpointID: endpoint.endpointID, traits: endpoint.traits,
                values: merged, notices: endpoint.notices, deviceTypeIDs: endpoint.deviceTypeIDs
            )
        }
        apply(DeviceTraitSnapshot(
            nodeID: snapshot.nodeID,
            endpoints: endpoints,
            notices: snapshot.notices,
            updatedAt: Date(),
            summaryReadings: DeviceControlService.summaryReadings(from: endpoints)
        ))
    }

    // MARK: - 控制

    /// 卡片控件的控制面板快照（按端点）。
    func controlSnapshot(for endpointID: UInt16) -> EndpointControlSnapshot? {
        control.detection.endpoints.first { $0.endpointID == endpointID }
    }

    /// 操作失败提示（由卡片控件写入 `control.message` 后弹出）。
    var controlFailure: String? { control.message }

    func clearControlFailure() {
        control.clearMessage()
    }
}