import Foundation
import Matter
import os

// MARK: - 配网阶段模型

/// 配网状态机阶段（按执行顺序）。
enum CommissioningPhase: String, CaseIterable, Identifiable, Sendable {
    case connecting = "发现 / 连接"
    case pase = "PASE 安全会话"
    case attestation = "设备认证"
    case readInfo = "读取设备信息"
    case network = "网络凭证"
    case join = "入网 / CASE"
    case done = "完成"

    var id: String { rawValue }
}

/// 单个阶段的状态（含耗时）。
struct CommissioningStageState: Identifiable, Sendable {
    enum Status: Sendable {
        case pending, active, succeeded, failed

        var isTerminal: Bool { self == .succeeded || self == .failed }
    }

    let phase: CommissioningPhase
    var status: Status = .pending
    var duration: TimeInterval?
    var note: String?

    var id: CommissioningPhase { phase }
}

/// 结构化的 MTRMetricData（跨线程安全传递）。
struct CommissionMetric: Identifiable, Sendable {
    let key: String
    let value: Double?
    let duration: TimeInterval?
    let errorCode: Int?

    var id: String { key }
}

/// 设备扫描到的 Thread 网络（跨线程安全传递，供 UI 展示参考）。
struct ThreadScanResult: Identifiable, Sendable {
    let networkName: String
    let panID: String
    let extendedPANID: String
    let channel: UInt16
    let rssi: Int8
    let lqi: UInt8

    var id: String { extendedPANID + networkName }
}

/// 配网进度快照（纯值类型，UI 直接消费）。
struct CommissioningProgress: Sendable {
    var isRunning: Bool
    var stages: [CommissioningStageState]
    var metrics: [CommissionMetric]
    var succeededNodeID: UInt64?
    var failureMessage: String?
    /// 设备扫描到的 Thread 网络（请求 Thread 凭证时填充，信息性展示）。
    var threadScanResults: [ThreadScanResult] = []

    static func initial() -> CommissioningProgress {
        var progress = CommissioningProgress(
            isRunning: true,
            stages: CommissioningPhase.allCases.map { CommissioningStageState(phase: $0) },
            metrics: [],
            succeededNodeID: nil,
            failureMessage: nil
        )
        // 首个阶段立即进入活动状态。
        if let idx = progress.stages.firstIndex(where: { $0.phase == .connecting }) {
            progress.stages[idx].status = .active
            progress.stages[idx].note = "正在发现 / 连接设备"
        }
        return progress
    }
}

/// 配网网络凭证（向导页选择）。
enum CommissionNetwork: Sendable, Equatable {
    case wifi(ssid: String, password: String)
    case thread(datasetHex: String)
    case none

    var label: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .thread: "Thread"
        case .none: "不提供（设备已在线）"
        }
    }
}

/// 配网服务：封装 MTRCommissioningOperation（iOS 26.2+ 新配网 API）。
/// 所有 delegate 回调桥接为 LogStore 事件 + 进度快照，UI 通过 onUpdate 订阅。
/// 线程安全：状态由 NSLock 保护；进度快照为 Sendable 值类型。
final class CommissioningService: @unchecked Sendable {
    static let shared = CommissioningService()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.example.MatterExplorer", category: "Commissioning")
    private let queue = DispatchQueue(label: "com.example.MatterExplorer.commissioning")

    private var operation: MTRCommissioningOperation?
    private var delegateBridge: CommissioningDelegateBridge?
    private var pendingWiFiCompletion: ((Data, Data?) -> Void)?
    private var pendingThreadCompletion: ((Data) -> Void)?
    private var phaseStart: [CommissioningPhase: Date] = [:]
    /// 本次配网中设备报告的 VID / PID（证明信息 → Commissionee 信息），配网成功后写入注册表。
    private var pendingVendorID: UInt32?
    private var pendingProductID: UInt32?

    private var _progress = CommissioningProgress(
        isRunning: false, stages: [], metrics: [], succeededNodeID: nil, failureMessage: nil
    )

    /// 进度更新回调（主线程触发）。
    var onUpdate: (@Sendable (CommissioningProgress) -> Void)?
    /// 配网暂停等待用户提供网络凭证（主线程触发）。
    var onCredentialsRequested: (@Sendable (CommissionNetwork) -> Void)?

    // MARK: - 启动 / 停止

    /// 发起配网。payload 可为 QR 字符串或 manual pairing code。
    func start(onboardingPayload: String, network: CommissionNetwork) {
        let payload = onboardingPayload.trimmingCharacters(in: .whitespacesAndNewlines)
        LogStore.shared.log(category: .commissioning, level: .info, message: "发起配网", detail: [
            "payload": payload,
            "网络凭证": network.label,
        ])

        lock.lock()
        _progress = CommissioningProgress.initial()
        phaseStart = [CommissioningPhase.connecting: Date()]
        pendingWiFiCompletion = nil
        pendingThreadCompletion = nil
        pendingVendorID = nil
        pendingProductID = nil
        lock.unlock()

        guard let controller = MatterManager.shared.controller else {
            fail(message: "Matter 控制器未就绪，无法配网（请查看设置页诊断）")
            return
        }

        let params = MTRCommissioningParameters()
        switch network {
        case .wifi(let ssid, let password):
            params.wifiSSID = Data(ssid.utf8)
            params.wifiCredentials = Data(password.utf8)
        case .thread(let hex):
            if let dataset = Data(hexString: hex) {
                params.threadOperationalDataset = dataset
            }
        case .none:
            break
        }
        params.countryCode = "CN"
        params.readEndpointInformation = true

        let bridge = CommissioningDelegateBridge()
        bridge.service = self

        guard let op = MTRCommissioningOperation(
            parameters: params,
            setupPayload: payload,
            delegate: bridge,
            queue: queue
        ) else {
            fail(message: "Onboarding payload 无效：请检查扫码或输入的内容")
            return
        }

        lock.lock()
        operation = op
        delegateBridge = bridge
        lock.unlock()

        logger.info("配网操作已创建，开始执行")
        op.start(with: controller)
        emitUpdate()
    }

    /// 停止进行中的配网。
    func stop() {
        lock.lock()
        let op = operation
        operation = nil
        lock.unlock()
        if let op, op.stop() {
            LogStore.shared.log(category: .commissioning, level: .warning, message: "配网已手动停止")
        } else {
            LogStore.shared.log(category: .commissioning, level: .debug, message: "停止请求已发出（操作可能已结束）")
        }
    }

    /// 提供 Wi-Fi 凭证（响应用户点击"提供"）。
    func provideWiFiCredentials(ssid: String, password: String) {
        lock.lock()
        let completion = pendingWiFiCompletion
        pendingWiFiCompletion = nil
        lock.unlock()
        guard let completion else { return }
        LogStore.shared.log(category: .commissioning, level: .info, message: "提供 Wi-Fi 凭证", detail: ["SSID": ssid])
        completion(Data(ssid.utf8), Data(password.utf8))
        updateStage(.network, status: .succeeded, note: "Wi-Fi 凭证已提供")
        emitUpdate()
    }

    /// 提供 Thread 凭证（Active Operational Dataset 十六进制）。
    func provideThreadDataset(hex: String) {
        lock.lock()
        let completion = pendingThreadCompletion
        pendingThreadCompletion = nil
        lock.unlock()
        guard let completion, let dataset = Data(hexString: hex) else { return }
        LogStore.shared.log(category: .commissioning, level: .info, message: "提供 Thread 凭证", detail: ["长度": "\(dataset.count) 字节"])
        completion(dataset)
        updateStage(.network, status: .succeeded, note: "Thread 凭证已提供")
        emitUpdate()
    }

    // MARK: - Delegate 回调桥接

    func handleAttestation(info: MTRDeviceAttestationDeviceInfo, error: Error?) {
        var detail: [String: String] = [
            "DAC VID": info.vendorID?.stringValue ?? "-",
            "DAC PID": info.productID?.stringValue ?? "-",
            "BasicInfo VID": info.basicInformationVendorID.stringValue,
            "BasicInfo PID": info.basicInformationProductID.stringValue,
            "DAC 证书": String(info.dacCertificate.hexString.prefix(32)) + "…",
        ]
        if let error {
            detail["认证错误"] = String(describing: error)
            LogStore.shared.log(category: .commissioning, level: .error, message: "设备认证失败", detail: detail)
        } else {
            LogStore.shared.log(category: .commissioning, level: .info, message: "设备认证完成", detail: detail)
        }
        // PASE 与连接已在认证前建立。
        updateStage(.connecting, status: .succeeded, note: "PASE 已建立")
        updateStage(.pase, status: .succeeded)
        updateStage(.attestation, status: error == nil ? .succeeded : .failed)
        // 证明信息里的厂商 / 产品标识（优先设备自报的 Basic Information，缺失时退回 DAC）。
        captureProductIdentity(
            vendorID: positiveUInt32(info.basicInformationVendorID) ?? positiveUInt32(info.vendorID),
            productID: positiveUInt32(info.basicInformationProductID) ?? positiveUInt32(info.productID)
        )
        emitUpdate()
    }

    func handleCommissioneeInfo(_ info: MTRCommissioneeInfo) {
        var detail: [String: String] = [:]
        let identity = info.productIdentity
        detail["VID"] = identity.vendorID.stringValue
        detail["PID"] = identity.productID.stringValue
        if let endpoints = info.endpointsById {
            detail["端点数"] = "\(endpoints.count)"
        }
        LogStore.shared.log(category: .commissioning, level: .info, message: "读取 Commissionee 信息", detail: detail)
        // Basic Information 读取到的产品标识比证明信息更贴近设备实际身份，覆盖之。
        captureProductIdentity(
            vendorID: positiveUInt32(identity.vendorID),
            productID: positiveUInt32(identity.productID)
        )
        updateStage(.readInfo, status: .succeeded)
        emitUpdate()
    }

    func handleNeedsWiFi(
        networks: [MTRNetworkCommissioningClusterWiFiInterfaceScanResultStruct]?,
        error: Error?,
        completion: @escaping (Data, Data?) -> Void
    ) {
        lock.lock()
        pendingWiFiCompletion = completion
        lock.unlock()

        var detail: [String: String] = ["扫描结果": "\(networks?.count ?? 0) 个网络"]
        if let networks, !networks.isEmpty {
            let names = networks.prefix(5).compactMap { String(data: $0.ssid, encoding: .utf8) }
            detail["可见网络"] = names.joined(separator: "、")
        }
        if let error { detail["扫描错误"] = String(describing: error) }
        LogStore.shared.log(category: .commissioning, level: .warning, message: "设备需要 Wi-Fi 凭证（未预填）", detail: detail)

        updateStage(.connecting, status: .succeeded, note: "PASE 已建立")
        updateStage(.pase, status: .succeeded)
        updateStage(.attestation, status: .succeeded)
        updateStage(.network, status: .active, note: "等待用户提供 Wi-Fi 凭证")
        emitUpdate()
        requestCredentials(.wifi(ssid: "", password: ""))
    }

    func handleNeedsThread(
        networks: [MTRNetworkCommissioningClusterThreadInterfaceScanResultStruct]?,
        error: Error?,
        completion: @escaping (Data) -> Void
    ) {
        lock.lock()
        pendingThreadCompletion = completion
        let scans: [ThreadScanResult] = (networks ?? []).map { result in
            ThreadScanResult(
                networkName: result.networkName,
                panID: MatterHex.hex(result.panId.uint16Value),
                extendedPANID: MatterHex.hex(result.extendedPanId.uint64Value),
                channel: result.channel.uint16Value,
                rssi: result.rssi.int8Value,
                lqi: result.lqi.uint8Value
            )
        }
        _progress.threadScanResults = scans
        lock.unlock()

        var detail: [String: String] = ["扫描结果": "\(networks?.count ?? 0) 个网络"]
        if !scans.isEmpty {
            detail["可见网络"] = scans.prefix(5)
                .map { "\($0.networkName)（信道 \($0.channel)，RSSI \($0.rssi)）" }
                .joined(separator: "、")
        }
        if let error { detail["扫描错误"] = String(describing: error) }
        LogStore.shared.log(category: .commissioning, level: .warning, message: "设备需要 Thread 凭证（未预填）", detail: detail)

        updateStage(.connecting, status: .succeeded, note: "PASE 已建立")
        updateStage(.pase, status: .succeeded)
        updateStage(.attestation, status: .succeeded)
        updateStage(.network, status: .active, note: "等待用户提供 Thread 凭证")
        emitUpdate()
        requestCredentials(.thread(datasetHex: ""))
    }

    func handleNetworkScanStarted() {
        updateStage(.network, status: .active, note: "正在扫描网络")
        LogStore.shared.log(category: .commissioning, level: .debug, message: "网络扫描开始")
        emitUpdate()
    }

    func handleNetworkCredentialsProvisioned() {
        updateStage(.network, status: .succeeded, note: "凭证已下发")
        updateStage(.join, status: .active, note: "等待设备入网")
        LogStore.shared.log(category: .commissioning, level: .info, message: "网络凭证已下发，设备开始入网")
        emitUpdate()
    }

    func handleSuccess(nodeID: UInt64, metrics: MTRMetrics) {
        updateStage(.join, status: .succeeded)
        updateStage(.done, status: .succeeded, note: "nodeID \(nodeID)")
        lock.lock()
        _progress.succeededNodeID = nodeID
        _progress.isRunning = false
        let vendorID = pendingVendorID
        let productID = pendingProductID
        lock.unlock()
        ingestMetrics(metrics)
        ClusterToolService.shared.registerCommissionedNode(nodeID, vendorID: vendorID, productID: productID)
        LogStore.shared.log(category: .commissioning, level: .info, message: "配网成功", detail: ["nodeID": "\(nodeID)"], nodeID: nodeID)
        emitUpdate()
    }

    /// 记录设备报告的产品标识：非零值才写入，后到的来源（Commissionee 信息）覆盖先到的。
    private func captureProductIdentity(vendorID: UInt32?, productID: UInt32?) {
        lock.lock()
        if let vendorID { pendingVendorID = vendorID }
        if let productID { pendingProductID = productID }
        lock.unlock()
    }

    /// NSNumber → UInt32：缺失或非正数时返回 nil（0 表示设备未提供该项）。
    private func positiveUInt32(_ value: NSNumber?) -> UInt32? {
        guard let value, value.intValue > 0 else { return nil }
        return value.uint32Value
    }

    func handleFailure(error: Error, metrics: MTRMetrics) {
        lock.lock()
        _progress.isRunning = false
        _progress.failureMessage = MatterErrorDictionary.description(for: error)
        if let idx = _progress.stages.firstIndex(where: { $0.status == .active }) {
            var stage = _progress.stages[idx]
            stage.status = .failed
            if let start = phaseStart[stage.phase], stage.duration == nil {
                stage.duration = Date().timeIntervalSince(start)
            }
            _progress.stages[idx] = stage
            phaseStart[stage.phase] = nil
        }
        lock.unlock()
        ingestMetrics(metrics)
        LogStore.shared.log(
            category: .commissioning, level: .error, message: "配网失败",
            detail: ["错误": MatterErrorDictionary.description(for: error)],
            errorCode: (error as NSError).code
        )
        emitUpdate()
    }

    // MARK: - 内部工具

    /// 早期失败（控制器未就绪 / payload 无效）。
    private func fail(message: String) {
        LogStore.shared.log(category: .commissioning, level: .error, message: message)
        lock.lock()
        _progress.isRunning = false
        _progress.failureMessage = message
        if let idx = _progress.stages.firstIndex(where: { $0.status == .active }) {
            var stage = _progress.stages[idx]
            stage.status = .failed
            if let start = phaseStart[stage.phase], stage.duration == nil {
                stage.duration = Date().timeIntervalSince(start)
            }
            _progress.stages[idx] = stage
        }
        lock.unlock()
        emitUpdate()
    }

    /// 更新单个阶段状态（自动记录耗时）。
    private func updateStage(_ phase: CommissioningPhase, status: CommissioningStageState.Status, note: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let idx = _progress.stages.firstIndex(where: { $0.phase == phase }) else { return }
        var stage = _progress.stages[idx]
        let now = Date()
        if status == .active {
            phaseStart[phase] = now
            stage.duration = nil
        } else if status.isTerminal {
            if let start = phaseStart[phase], stage.duration == nil {
                stage.duration = now.timeIntervalSince(start)
            }
            phaseStart[phase] = nil
        }
        stage.status = status
        if let note { stage.note = note }
        _progress.stages[idx] = stage
    }

    /// 结构化 MTRMetrics 并写入日志。
    private func ingestMetrics(_ metrics: MTRMetrics) {
        let entries = metrics.allKeys.compactMap { key -> CommissionMetric? in
            guard let data = metrics.metricData(forKey: key) else { return nil }
            return CommissionMetric(
                key: key,
                value: data.value?.doubleValue,
                duration: data.duration?.doubleValue,
                errorCode: data.errorCode?.intValue
            )
        }
        guard !entries.isEmpty else { return }
        lock.lock()
        _progress.metrics = entries
        lock.unlock()
        for entry in entries {
            var detail: [String: String] = ["指标": entry.key]
            if let v = entry.value { detail["值"] = "\(v)" }
            if let d = entry.duration { detail["耗时"] = String(format: "%.3f 秒", d) }
            if let code = entry.errorCode { detail["错误码"] = "\(code)" }
            LogStore.shared.log(category: .commissioning, level: .debug, message: "阶段指标: \(entry.key)", detail: detail)
        }
    }

    private func emitUpdate() {
        let snapshot: CommissioningProgress
        lock.lock()
        snapshot = _progress
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }

    private func requestCredentials(_ request: CommissionNetwork) {
        DispatchQueue.main.async { [weak self] in
            self?.onCredentialsRequested?(request)
        }
    }
}

/// MTRCommissioningDelegate 桥接：回调转发给 CommissioningService。
/// 回调运行在创建操作时传入的串行 queue 上。
final class CommissioningDelegateBridge: NSObject, MTRCommissioningDelegate, @unchecked Sendable {
    weak var service: CommissioningService?

    // required
    func commissioning(
        _ commissioning: MTRCommissioningOperation,
        completedDeviceAttestation attestationDeviceInfo: MTRDeviceAttestationDeviceInfo,
        error: Error?,
        completion: @escaping () -> Void
    ) {
        service?.handleAttestation(info: attestationDeviceInfo, error: error)
        completion()
    }

    // optional
    func commissioning(_ commissioning: MTRCommissioningOperation, read info: MTRCommissioneeInfo) {
        service?.handleCommissioneeInfo(info)
    }

    func commissioning(
        _ commissioning: MTRCommissioningOperation,
        needsWiFiCredentialsWithScanResults networks: [MTRNetworkCommissioningClusterWiFiInterfaceScanResultStruct]?,
        error: Error?,
        completion: @escaping (Data, Data?) -> Void
    ) {
        service?.handleNeedsWiFi(networks: networks, error: error, completion: completion)
    }

    func commissioning(
        _ commissioning: MTRCommissioningOperation,
        needsThreadCredentialsWithScanResults networks: [MTRNetworkCommissioningClusterThreadInterfaceScanResultStruct]?,
        error: Error?,
        completion: @escaping (Data) -> Void
    ) {
        service?.handleNeedsThread(networks: networks, error: error, completion: completion)
    }

    func commissioningStartingNetworkScan(_ commissioning: MTRCommissioningOperation) {
        service?.handleNetworkScanStarted()
    }

    func commissioningProvisionedNetworkCredentials(_ commissioning: MTRCommissioningOperation) {
        service?.handleNetworkCredentialsProvisioned()
    }

    func commissioning(_ commissioning: MTRCommissioningOperation, failedWithError error: Error, metrics: MTRMetrics) {
        service?.handleFailure(error: error, metrics: metrics)
    }

    func commissioning(_ commissioning: MTRCommissioningOperation, succeededForNodeID nodeID: NSNumber, metrics: MTRMetrics) {
        service?.handleSuccess(nodeID: nodeID.uint64Value, metrics: metrics)
    }
}
