import Foundation
import Matter
import Observation

// MARK: - 导航路由

/// 设备模块导航层级：列表 → 设备详情 → 设备控制 / 设备管理 / 集群工具。
enum DeviceRoute: Hashable {
    case detail(UInt64)
    case control(UInt64)
    case admin(UInt64)
    case clusterIO(UInt64)
}

/// 设备模块 ViewModel：已配网设备列表 + 在线状态 + 详情（基本信息 / 网络信息 / 拓扑）。
@MainActor
@Observable
final class DevicesViewModel {
    // MARK: - 列表

    var devices: [DeviceRecord] = []
    var statuses: [UInt64: DeviceReachability] = [:]
    /// 列表行读数摘要（nodeID → 快照摘要；无缓存时为空）。
    var traitSummaries: [UInt64: [TraitReading]] = [:]

    // MARK: - 详情

    var basicInfo: DeviceBasicInfo?
    var isLoadingBasicInfo = false
    var networkSummary: DeviceNetworkSummary?
    var isLoadingNetwork = false
    /// OTA 只读状态（端点 0）。
    var otaStatus: DeviceOTAStatus?
    var isLoadingOTA = false
    /// 电池 / 电源只读状态（各电源端点）。
    var batteryStatus: DeviceBatteryStatus?
    var isLoadingBattery = false
    /// 订阅诊断：本次订阅已收到的报告条数（含非 0x2F）。
    /// 用于区分「订阅没生效」与「设备确实没上报 0x2F」——两者在界面上都不显示电池值，但原因完全不同。
    var batteryReportCount = 0
    /// 订阅是否已建立（已建立但零报告 ≠ 未订阅）。
    var isBatterySubscribed: Bool { batterySubscriptionToken != nil }
    /// 本地 OTA 镜像库。
    var otaImages: [OTAImageStore.Item] = []
    /// OTA 镜像导入 / 通告的结果提示。
    var otaActionMessage: String?
    var isAnnouncingOTA = false
    var endpoints: [UInt16] = []
    var detailMessage: String?
    var renameText = ""

    /// 状态监视失败等提示（待配网设备发现已迁至配网页）。
    var message: String?

    private var monitorRetryTask: Task<Void, Never>?
    /// 列表摘要补读任务（串行，避免同时向多个设备发起读取）。
    private var traitLoadTask: Task<Void, Never>?
    /// 电池 / 电源订阅累计的属性值（端点 → 属性 ID → 值）。
    private var batteryValues: [UInt16: [UInt32: MatterScalar]] = [:]
    private var batterySubscriptionToken: String?

    init() {
        DeviceService.shared.onStatusChange = { [weak self] nodeID, state in
            Task { @MainActor in
                guard let self else { return }
                let previous = self.statuses[nodeID]
                self.statuses[nodeID] = state
                // 刚从不可达转为可达：缓存读数可能已陈旧，丢弃后重新补读。
                if previous == .unreachable, state == .reachable {
                    DeviceTraitCache.shared.remove(nodeID: nodeID)
                    self.loadTraitSummaries()
                }
            }
        }
        // 注册表变更（如配网成功登记）即刷新：列表页以 sheet 承载配网时不会重新触发 onAppear。
        NotificationCenter.default.addObserver(
            forName: DeviceRegistry.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // DCL 数据更新后厂商名 / 产品名会变，列表标题与身份文案需同步刷新。
        NotificationCenter.default.addObserver(
            forName: DCLCatalogStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }

    // MARK: - 列表 / 状态

    /// 重新载入注册表并确保状态监视已启动。
    func reload() {
        devices = DeviceRegistry.shared.allDevices()
        startStatusMonitoring()
        loadTraitSummaries()
    }

    /// 启动在线状态监视。控制器引导是异步的，早期失败时短暂重试。
    func startStatusMonitoring() {
        let nodeIDs = devices.map(\.nodeID)
        guard !nodeIDs.isEmpty else { return }
        guard DeviceService.shared.startMonitoring(nodeIDs: nodeIDs) else {
            scheduleMonitorRetry()
            return
        }
        monitorRetryTask?.cancel()
        monitorRetryTask = nil
        message = nil
        refreshCachedStatuses()
    }

    /// 控制器未就绪时每秒重试（最多 5 次），仍失败才提示。
    private func scheduleMonitorRetry() {
        guard monitorRetryTask == nil else { return }
        monitorRetryTask = Task { [weak self] in
            for _ in 0..<5 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if DeviceService.shared.startMonitoring(nodeIDs: self.devices.map(\.nodeID)) {
                    self.monitorRetryTask = nil
                    self.message = nil
                    self.refreshCachedStatuses()
                    return
                }
            }
            guard let self else { return }
            self.monitorRetryTask = nil
            self.message = "Matter 控制器未就绪，无法监视设备在线状态（请查看设置页诊断）"
        }
    }

    private func refreshCachedStatuses() {
        for nodeID in devices.map(\.nodeID) where statuses[nodeID] == nil {
            statuses[nodeID] = DeviceService.shared.currentState(nodeID: nodeID)
        }
    }

    func status(for nodeID: UInt64) -> DeviceReachability {
        statuses[nodeID] ?? .unknown
    }

    func record(for nodeID: UInt64) -> DeviceRecord? {
        devices.first { $0.nodeID == nodeID }
    }

    // MARK: - 列表读数摘要

    func traitSummary(for nodeID: UInt64) -> [TraitReading] {
        traitSummaries[nodeID] ?? []
    }

    /// 为未缓存 / 已过期的可达设备补读特征摘要（串行，并发 1）。
    func loadTraitSummaries() {
        traitLoadTask?.cancel()
        let nodeIDs = devices.map(\.nodeID)
        traitLoadTask = Task { [weak self] in
            for nodeID in nodeIDs {
                guard !Task.isCancelled, let self else { return }
                if DeviceTraitCache.shared.isFresh(nodeID: nodeID) {
                    self.publishCachedSummary(nodeID: nodeID)
                    continue
                }
                // 不可达设备不发起读取（避免无谓等待）。
                guard self.status(for: nodeID) != .unreachable else { continue }
                await self.fetchTraitSummary(nodeID: nodeID)
            }
        }
    }

    private func publishCachedSummary(nodeID: UInt64) {
        guard let snapshot = DeviceTraitCache.shared.snapshot(nodeID: nodeID) else { return }
        traitSummaries[nodeID] = snapshot.summaryReadings
    }

    private func fetchTraitSummary(nodeID: UInt64) async {
        let snapshot: DeviceTraitSnapshot? = await withCheckedContinuation { continuation in
            DeviceControlService.shared.detectTraits(nodeID: nodeID) { result in
                switch result {
                case .success(let snapshot): continuation.resume(returning: snapshot)
                case .failure: continuation.resume(returning: nil)
                }
            }
        }
        guard let snapshot else { return }
        DeviceTraitCache.shared.store(snapshot)
        traitSummaries[nodeID] = snapshot.summaryReadings
    }

    // MARK: - 重命名 / 移除

    func beginRename(nodeID: UInt64) {
        renameText = record(for: nodeID)?.name ?? ""
    }

    func saveRename(nodeID: UInt64) {
        DeviceRegistry.shared.rename(nodeID: nodeID, name: renameText)
        LogStore.shared.log(
            category: .system, level: .info,
            message: renameText.isEmpty ? "已清除设备命名" : "已重命名设备",
            detail: ["名称": renameText.isEmpty ? "（默认）" : renameText], nodeID: nodeID
        )
        reload()
    }

    /// 从本地列表移除记录（不解除 Matter fabric）。
    func removeRecord(nodeID: UInt64) {
        DeviceRegistry.shared.remove(nodeID: nodeID)
        DeviceService.shared.stopMonitoring(nodeIDs: [nodeID])
        DeviceTraitCache.shared.remove(nodeID: nodeID)
        traitSummaries.removeValue(forKey: nodeID)
        LogStore.shared.log(
            category: .system, level: .warning,
            message: "已从本地列表移除设备（未解除 fabric）", nodeID: nodeID
        )
        reload()
    }

    // MARK: - 详情

    func loadDetail(nodeID: UInt64) {
        beginRename(nodeID: nodeID)
        loadBasicInfo(nodeID: nodeID)
        loadEndpoints(nodeID: nodeID)
        loadOTAStatus(nodeID: nodeID)
        reloadOTAImages()
    }

    func loadBasicInfo(nodeID: UInt64) {
        guard !isLoadingBasicInfo else { return }
        isLoadingBasicInfo = true
        detailMessage = nil
        DeviceService.shared.readBasicInfo(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingBasicInfo = false
                switch result {
                case .success(let info):
                    self.basicInfo = info
                    DeviceRegistry.shared.setVendorProduct(
                        nodeID: nodeID, vendorID: info.vendorID, productID: info.productID
                    )
                    self.devices = DeviceRegistry.shared.allDevices()
                case .failure(let operation):
                    self.basicInfo = nil
                    self.detailMessage = "基本信息读取失败：\(operation.message)"
                }
            }
        }
    }

    func loadEndpoints(nodeID: UInt64) {
        DeviceService.shared.readEndpoints(nodeID: nodeID) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let endpoints):
                    self.endpoints = endpoints
                    DeviceRegistry.shared.setEndpointCount(
                        nodeID: nodeID, count: UInt16(clamping: endpoints.count)
                    )
                    self.devices = DeviceRegistry.shared.allDevices()
                case .failure(let operation):
                    self.endpoints = []
                    self.detailMessage = self.detailMessage ?? "端点读取失败：\(operation.message)"
                }
            }
        }
    }

    func loadNetworkInfo(nodeID: UInt64) {
        guard !isLoadingNetwork else { return }
        isLoadingNetwork = true
        DeviceService.shared.readNetworkInfo(nodeID: nodeID) { [weak self] summary in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingNetwork = false
                self.networkSummary = summary
                DeviceRegistry.shared.setNetworkKind(nodeID: nodeID, kind: summary.inferredKind)
                self.devices = DeviceRegistry.shared.allDevices()
            }
        }
    }

    /// 读取端点 0 的 OTA 只读状态（不涉及镜像下发）。
    func loadOTAStatus(nodeID: UInt64) {
        guard !isLoadingOTA else { return }
        isLoadingOTA = true
        DeviceService.shared.readOTAStatus(nodeID: nodeID) { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                self.isLoadingOTA = false
                self.otaStatus = status
            }
        }
    }

    /// 订阅电池 / 电源状态（Power Source 集群 0x2F，端点通配）。
    /// 用订阅而非读取：首次报告一次带回该端点全部已实现属性（电池属性稀疏且逐属性读易挂起），
    /// 之后电量 / 充电状态变化会继续推送。重复调用视为重新订阅。
    func loadBatteryStatus(nodeID: UInt64) {
        stopBatteryStatus()
        batteryValues = [:]
        batteryStatus = nil
        batteryReportCount = 0
        isLoadingBattery = true
        batterySubscriptionToken = ClusterToolService.shared.subscribe(
            nodeID: nodeID,
            // 端点用通配：addDelegate 的兴趣路径只支持具体端点，故不加过滤，
            // 由 mergeBatteryReports 按集群 0x2F 过滤。首次报告会一次带回全部已实现属性。
            interestedPaths: [],
            detail: ["用途": "电池 / 电源（Power Source 0x2F，端点通配）"],
            onUpdate: { [weak self] reports in
                Task { @MainActor in self?.mergeBatteryReports(reports) }
            },
            onState: { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.isLoadingBattery = false
                }
            }
        )
        if batterySubscriptionToken == nil {
            isLoadingBattery = false
            batteryStatus = DeviceService.batteryStatus(from: [:])
        }
    }

    /// 取消电池 / 电源订阅。
    func stopBatteryStatus() {
        if let token = batterySubscriptionToken {
            ClusterToolService.shared.unsubscribe(token: token)
            batterySubscriptionToken = nil
        }
        isLoadingBattery = false
    }

    /// 订阅报告 → 属性值快照（端点 → 属性 ID → 值），并重建电池状态。
    private func mergeBatteryReports(_ reports: [ClusterAttributeReport]) {
        batteryReportCount += reports.count
        for report in reports {
            guard !report.isError,
                  report.clusterID == 0x2F,
                  let endpointID = report.endpointID,
                  let attributeID = report.attributeID,
                  let scalar = report.scalar else { continue }
            batteryValues[endpointID, default: [:]][attributeID] = scalar
        }
        isLoadingBattery = false
        batteryStatus = DeviceService.batteryStatus(from: batteryValues)
    }

    // MARK: - OTA 镜像库 / 下发

    func reloadOTAImages() {
        otaImages = OTAImageStore.shared.all()
    }

    func importOTAImage(from url: URL) {
        do {
            let item = try OTAImageStore.shared.add(from: url)
            otaActionMessage = "已导入 \(item.fileName)：\(item.versionText)，\(item.byteCount.byteText)"
        } catch {
            otaActionMessage = "导入失败：\(error.localizedDescription)"
        }
        reloadOTAImages()
    }

    func deleteOTAImage(id: String) {
        OTAImageStore.shared.remove(id: id)
        reloadOTAImages()
    }

    /// 本设备（VID / PID）可下发的镜像：版本高于设备当前版本。
    var availableOTAImage: OTAImageStore.Item? {
        guard let vendorID = basicInfo?.vendorID, let productID = basicInfo?.productID else { return nil }
        return OTAImageStore.shared.image(
            vendorID: vendorID, productID: productID, newerThan: basicInfo?.softwareVersion ?? 0
        )
    }

    /// 镜像是否面向本设备（用于列表标注；VID / PID 为 0 视为通配）。
    func isOTAMatch(_ item: OTAImageStore.Item) -> Bool {
        guard let vendorID = basicInfo?.vendorID, let productID = basicInfo?.productID else { return false }
        return (item.vendorID == vendorID || item.vendorID == 0)
            && (item.productID == productID || item.productID == 0)
    }

    /// 向设备发送 AnnounceOTAProvider（集群 0x2A / 命令 0x00）：告知本机为 OTA Provider 及可用版本，
    /// 设备随后会向本机发起 QueryImage 并下载镜像。需 App 保持前台直至传输完成。
    func announceOTAUpdate(nodeID: UInt64) {
        guard let image = availableOTAImage else {
            otaActionMessage = "没有匹配该设备且版本更高的镜像，请先导入 .ota 文件"
            return
        }
        guard let providerNodeID = MatterManager.shared.controllerNodeID else {
            otaActionMessage = "Matter 控制器未就绪，无法取得 Provider 节点 ID"
            return
        }
        // 字段标签：0 providerNodeID / 1 vendorID / 2 announcementReason / 4 endpoint。
        let commandFields: [String: Any] = [
            MTRTypeKey: MTRStructureValueType,
            MTRValueKey: [
                Self.commandField(0, providerNodeID),
                Self.commandField(1, UInt64(image.vendorID)),
                Self.commandField(2, UInt64(Self.announcementReasonUpdateAvailable)),
                Self.commandField(4, 0),
            ],
        ]

        isAnnouncingOTA = true
        otaActionMessage = nil
        ClusterToolService.shared.invokeCommand(
            nodeID: nodeID, endpointID: 0, clusterID: 0x2A, commandID: 0x00, commandFields: commandFields
        ) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isAnnouncingOTA = false
                self.otaActionMessage = result.isSuccess
                    ? "已通告设备：Provider 节点 \(providerNodeID)，镜像 \(image.fileName)（\(image.versionText)）"
                    : "OTA 通告失败：\(result.message)"
                self.loadOTAStatus(nodeID: nodeID)
            }
        }
    }

    /// AnnounceOTAProvider.announcementReason：UpdateAvailable。
    private static let announcementReasonUpdateAvailable: UInt8 = 1

    /// 命令字段（上下文标签 + 无符号整数值）。
    private static func commandField(_ tag: UInt32, _ value: UInt64) -> [String: Any] {
        [
            MTRContextTagKey: NSNumber(value: tag),
            MTRDataKey: [MTRTypeKey: MTRUnsignedIntegerValueType, MTRValueKey: NSNumber(value: value)],
        ]
    }

    func clearOTAActionMessage() {
        otaActionMessage = nil
    }

    // MARK: - 提示

    func clearMessage() {
        message = nil
    }
}