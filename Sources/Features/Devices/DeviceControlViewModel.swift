import Foundation
import Observation

/// 设备控制 ViewModel：能力探测 → 控件状态读取 → 命令下发 → 订阅实时回填。
@MainActor
@Observable
final class DeviceControlViewModel {
    /// 探测结果（端点控制能力 + 状态）。
    var detection = DeviceControlDetection()
    var isLoading = false
    var message: String?

    /// 设备在线状态（订阅回传）。
    var deviceState = "未知"
    var isSubscribed = false
    /// 最近一次控制命令结果（展示状态码与耗时）。
    var lastOperation: ClusterOperationResult?

    /// 控件草稿值（拖动中即时反馈；订阅报告回填后会同步）。
    var onOffDraft: [UInt16: Bool] = [:]
    var brightnessDraft: [UInt16: Double] = [:]
    var miredsDraft: [UInt16: Double] = [:]
    var liftDraft: [UInt16: Double] = [:]
    /// 识别闪烁时长（秒）。
    var identifySeconds: UInt16 = 5

    /// 正在下发命令的控件（键为「能力-端点」，用于禁用与进度显示）。
    var pendingControls: Set<String> = []

    // MARK: - 加载 / 刷新

    func load(nodeID: UInt64) {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        DeviceControlService.shared.detect(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let detection):
                    self.detection = detection
                    if detection.endpoints.isEmpty {
                        self.message = "该设备未报告可控集群（On/Off、Level Control、Color Control、Window Covering）。"
                    }
                    self.syncDrafts()
                    self.startMonitoring(nodeID: nodeID)
                case .failure(let operation):
                    self.detection = DeviceControlDetection()
                    self.message = "能力探测失败：\(operation.message)"
                }
            }
        }
    }

    /// 仅重新读取控件状态（不重新做能力探测）。
    func refresh(nodeID: UInt64) {
        guard !isLoading else { return }
        isLoading = true
        message = nil
        DeviceControlService.shared.detect(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let detection):
                    if !detection.endpoints.isEmpty {
                        self.detection = detection
                    }
                    self.syncDrafts()
                case .failure(let operation):
                    self.message = "状态刷新失败：\(operation.message)"
                }
            }
        }
    }

    // MARK: - 订阅

    /// 订阅控制属性，设备端（物理开关 / 其它控制器）变化会实时回填控件。
    private func startMonitoring(nodeID: UInt64) {
        let paths = detection.endpoints.flatMap { snapshot in
            snapshot.capabilities.flatMap { capability in
                (DeviceControlCatalog.stateAttributes[capability] ?? []).map {
                    ControlAttributePath(endpointID: snapshot.endpointID, key: $0)
                }
            }
        }
        guard !paths.isEmpty else { return }
        isSubscribed = DeviceControlService.shared.startMonitoring(
            nodeID: nodeID,
            paths: paths,
            onUpdate: { [weak self] reports in
                Task { @MainActor in
                    self?.apply(reports)
                }
            },
            onState: { [weak self] text in
                Task { @MainActor in
                    self?.deviceState = text
                }
            }
        )
        if !isSubscribed {
            message = "订阅未建立：Matter 控制器未就绪（状态不会实时更新，可手动刷新）。"
        }
    }

    func stopMonitoring() {
        DeviceControlService.shared.stopMonitoring()
        isSubscribed = false
    }

    /// 订阅报告 → 回填状态值与草稿。
    private func apply(_ reports: [ClusterAttributeReport]) {
        var detection = self.detection
        var changed = false
        for report in reports {
            guard !report.isError,
                  let endpointID = report.endpointID,
                  let clusterID = report.clusterID,
                  let attributeID = report.attributeID,
                  let scalar = report.scalar,
                  let index = detection.endpoints.firstIndex(where: { $0.endpointID == endpointID }) else { continue }
            let key = ControlAttributeKey(clusterID: clusterID, attributeID: attributeID)
            // 仅回填本面板已展示的控制属性。
            let known = detection.endpoints[index].capabilities.contains { capability in
                (DeviceControlCatalog.stateAttributes[capability] ?? []).contains(key)
            }
            guard known else { continue }
            detection.endpoints[index].values[key] = scalar
            changed = true
        }
        guard changed else { return }
        self.detection = detection
        syncDrafts()
    }

    // MARK: - 草稿同步

    /// 由当前快照同步草稿值（特征详情页复用同一份控制逻辑时也会调用）。
    func syncDrafts() {
        for snapshot in detection.endpoints {
            if let isOn = snapshot.isOn {
                onOffDraft[snapshot.endpointID] = isOn
            }
            if let percent = snapshot.brightnessPercent {
                brightnessDraft[snapshot.endpointID] = percent
            }
            if let mireds = snapshot.colorTemperatureMireds {
                miredsDraft[snapshot.endpointID] = mireds
            }
            if let percent = snapshot.liftPercent {
                liftDraft[snapshot.endpointID] = percent
            }
        }
    }

    func snapshot(for endpointID: UInt16) -> EndpointControlSnapshot? {
        detection.endpoints.first { $0.endpointID == endpointID }
    }

    func pendingKey(_ capability: ControlCapability, _ endpointID: UInt16) -> String {
        "\(capability.rawValue)-\(endpointID)"
    }

    func isPending(_ capability: ControlCapability, _ endpointID: UInt16) -> Bool {
        pendingControls.contains(pendingKey(capability, endpointID))
    }

    // MARK: - 控制动作

    func toggleOnOff(nodeID: UInt64, endpointID: UInt16, isOn: Bool) {
        let previous = onOffDraft[endpointID]
        onOffDraft[endpointID] = isOn
        run(capability: .onOff, endpointID: endpointID) { completion in
            DeviceControlService.shared.setOnOff(nodeID: nodeID, endpointID: endpointID, on: isOn) { result in
                if !result.isSuccess {
                    Task { @MainActor in
                        self.onOffDraft[endpointID] = previous
                    }
                }
                completion(result)
            }
        }
    }

    func identify(nodeID: UInt64, endpointID: UInt16) {
        let seconds = identifySeconds
        run(capability: .identify, endpointID: endpointID) { completion in
            DeviceControlService.shared.identify(
                nodeID: nodeID, endpointID: endpointID, seconds: seconds, completion: completion
            )
        }
    }

    func setBrightness(nodeID: UInt64, endpointID: UInt16, percent: Double) {
        run(capability: .brightness, endpointID: endpointID) { completion in
            DeviceControlService.shared.setBrightness(
                nodeID: nodeID, endpointID: endpointID, percent: percent,
                transitionTimeTenths: 4, completion: completion
            )
        }
    }

    func setColorTemperature(nodeID: UInt64, endpointID: UInt16, mireds: Double) {
        let value = UInt16(min(max(mireds.rounded(), 1), Double(UInt16.max)))
        run(capability: .colorTemperature, endpointID: endpointID) { completion in
            DeviceControlService.shared.setColorTemperature(
                nodeID: nodeID, endpointID: endpointID, mireds: value,
                transitionTimeTenths: 4, completion: completion
            )
        }
    }

    func setLift(nodeID: UInt64, endpointID: UInt16, percent: Double) {
        run(capability: .windowCovering, endpointID: endpointID) { completion in
            DeviceControlService.shared.setLiftPercent(
                nodeID: nodeID, endpointID: endpointID, percent: percent, completion: completion
            )
        }
    }

    /// 统一下发流程：标记进行中 → 结果写入 lastOperation + 失败提示。
    private func run(
        capability: ControlCapability,
        endpointID: UInt16,
        operation: @escaping @Sendable (@escaping @Sendable (ClusterOperationResult) -> Void) -> Void
    ) {
        let key = pendingKey(capability, endpointID)
        guard !pendingControls.contains(key) else { return }
        pendingControls.insert(key)
        message = nil
        operation { result in
            Task { @MainActor in
                self.pendingControls.remove(key)
                self.lastOperation = result
                if !result.isSuccess {
                    self.message = "\(capability.title)操作失败：\(result.message)"
                }
            }
        }
    }

    func clearMessage() {
        message = nil
    }
}