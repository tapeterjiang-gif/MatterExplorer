import Foundation
import Matter
import Observation

/// 网络凭证类型（仅用于 UI 选择；具体值见对应字段）。
enum NetworkKind: String, CaseIterable, Identifiable, Sendable {
    case wifi = "Wi-Fi"
    case thread = "Thread"
    case none = "无"

    var id: String { rawValue }
}

/// 配网向导 ViewModel：附近设备扫描 + payload 解析展示 + 配网流程状态驱动。
@MainActor
@Observable
final class CommissionViewModel {
    // MARK: - 输入

    var inputText = ""
    var parseError: String?
    var formError: String?
    var parsed: PayloadSummary?

    // MARK: - 配网

    /// 默认「无」：设备已在线时无需凭证，避免默认要求用户填写 Wi-Fi。
    var networkKind: NetworkKind = .none
    var wifiSSID = ""
    var wifiPassword = ""
    var threadDatasetHex = ""

    var isCommissioning = false
    var progress = CommissioningProgress(
        isRunning: false, stages: [], metrics: [], succeededNodeID: nil, failureMessage: nil
    )
    /// 设备扫描到的 Thread 网络（信息性展示，来自 progress）。
    var threadScanResults: [ThreadScanResult] = []
    var credentialRequest: CommissionNetwork?

    // MARK: - 系统 Thread 凭证（THClient）

    var systemNetworks: [SystemThreadNetwork] = []
    var systemNetworkMessage: String?
    var isLoadingSystemNetworks = false

    // MARK: - 附近待配网设备（DNS-SD / BLE 扫描）

    var isBrowsing = false
    var discovered: [DiscoveredDevice] = []
    var browseMessage: String?

    /// 已点选、待输入配对码的设备（非 nil 时弹出输入弹窗）。
    var pendingDevice: DiscoveredDevice?
    /// 用户输入的 11 位配对码，展示态（按 4-3-4 带连字符，如 `0203-013-5439`）。
    var pairingCodeInput = ""
    var pairingCodeError: String?

    /// 输入框内容的纯数字部分（去掉连字符等分隔符）。
    var pairingCodeDigits: String {
        pairingCodeInput.filter(\.isNumber)
    }

    /// 归一化输入：只保留数字、最多 11 位，并按 4-3-4 重新分组。
    /// 由输入框的 onChange 调用——展示态是存储属性，SwiftUI 每次都会把带分隔符的文本渲染回输入框。
    func normalizePairingCode() {
        let digits = String(pairingCodeInput.filter(\.isNumber).prefix(11))
        let normalized = Self.groupedPairingCode(digits)
        if normalized != pairingCodeInput {
            pairingCodeInput = normalized
        }
    }

    /// 11 位配对码的分组显示：4-3-4（`02030135439` → `0203-013-5439`）。
    private static func groupedPairingCode(_ digits: String) -> String {
        var result = ""
        for (index, character) in digits.enumerated() {
            if index == 4 || index == 7 { result.append("-") }
            result.append(character)
        }
        return result
    }

    var showScanner = false
    var showProgress = false
    var showCredentialSheet = false

    /// 用户选择的网络凭证（组装自 UI 字段）。
    var selectedNetwork: CommissionNetwork {
        switch networkKind {
        case .wifi: .wifi(ssid: wifiSSID, password: wifiPassword)
        case .thread: .thread(datasetHex: threadDatasetHex)
        case .none: .none
        }
    }

    /// 解析结果摘要（值类型）。
    struct PayloadSummary {
        let isConcatenated: Bool
        let version: Int?
        let vendorID: Int?
        let productID: Int?
        let discriminator: Int?
        let hasShortDiscriminator: Bool
        let setupPasscode: Int?
        let capabilities: [String]
        let flow: String
        let serialNumber: String?
        let manualCode: String?
    }

    // MARK: - Payload 解析

    func parsePayload() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            parseError = "请输入 onboarding payload（QR 字符串或 manual pairing code）"
            parsed = nil
            return
        }
        guard let payload = MTRSetupPayload(payload: text) else {
            parseError = "无法解析：内容不是有效的 onboarding payload"
            parsed = nil
            return
        }
        parseError = nil
        parsed = summarize(payload)
        LogStore.shared.log(
            category: .commissioning, level: .info,
            message: "Onboarding payload 解析成功", detail: summaryDetail(payload)
        )
    }

    private func summarize(_ p: MTRSetupPayload) -> PayloadSummary {
        PayloadSummary(
            isConcatenated: p.isConcatenated,
            version: p.version.intValue,
            vendorID: p.vendorID.intValue,
            productID: p.productID.intValue,
            discriminator: p.discriminator.intValue,
            hasShortDiscriminator: p.hasShortDiscriminator,
            setupPasscode: p.setupPasscode.intValue,
            capabilities: discoveryCapabilities(p.discoveryCapabilities.rawValue),
            flow: flowName(p.commissioningFlow.rawValue),
            serialNumber: p.serialNumber,
            manualCode: p.manualEntryCode()
        )
    }

    private func summaryDetail(_ p: MTRSetupPayload) -> [String: String] {
        [
            "版本": p.version.stringValue,
            "VID": p.vendorID.stringValue,
            "PID": p.productID.stringValue,
            "Discriminator": p.discriminator.stringValue,
            "Setup PIN": p.setupPasscode.stringValue,
            "发现能力": discoveryCapabilities(p.discoveryCapabilities.rawValue).joined(separator: ", "),
            "配网模式": flowName(p.commissioningFlow.rawValue),
        ]
    }

    private func discoveryCapabilities(_ raw: UInt) -> [String] {
        var caps: [String] = []
        if raw & 2 != 0 { caps.append("BLE") }
        if raw & 1 != 0 { caps.append("SoftAP") }
        if raw & 4 != 0 { caps.append("OnNetwork") }
        if raw & 16 != 0 { caps.append("NFC") }
        if caps.isEmpty { caps.append("未知") }
        return caps
    }

    private func flowName(_ raw: UInt) -> String {
        switch raw {
        case 0: return "Standard（上电进入配网模式）"
        case 1: return "User Action Required（需用户操作）"
        case 2: return "Custom（分布式合规账本）"
        default: return "未知 (\(raw))"
        }
    }

    func handleScanned(_ text: String) {
        showScanner = false
        inputText = text
        parsePayload()
    }

    // MARK: - 配网流程

    func startCommissioning() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            formError = "请先输入 onboarding payload 并解析"
            return
        }
        switch selectedNetwork {
        case .wifi(let ssid, _):
            guard !ssid.isEmpty else {
                formError = "请填写 Wi-Fi SSID"
                return
            }
        case .thread(let hex):
            guard Data(hexString: hex) != nil else {
                formError = "Thread dataset 需为偶数位十六进制字符串"
                return
            }
        case .none:
            break
        }
        formError = nil
        isCommissioning = true
        showProgress = true

        let service = CommissioningService.shared
        service.onUpdate = { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.progress = progress
                self.threadScanResults = progress.threadScanResults
                self.isCommissioning = progress.isRunning
            }
        }
        service.onCredentialsRequested = { [weak self] request in
            Task { @MainActor in
                guard let self else { return }
                self.credentialRequest = request
                self.showCredentialSheet = true
            }
        }
        service.start(onboardingPayload: text, network: selectedNetwork)
    }

    func stopCommissioning() {
        CommissioningService.shared.stop()
    }

    func provideWiFi(ssid: String, password: String) {
        credentialRequest = nil
        guard isCommissioning else {
            // 由「添加」发起的凭证补全：写入表单后直接开始配网。
            wifiSSID = ssid
            wifiPassword = password
            startCommissioning()
            return
        }
        CommissioningService.shared.provideWiFiCredentials(ssid: ssid, password: password)
    }

    func provideThread(hex: String) {
        credentialRequest = nil
        guard isCommissioning else {
            // 由「添加」发起的凭证补全：dataset 已在表单里，直接开始配网。
            threadDatasetHex = hex
            startCommissioning()
            return
        }
        CommissioningService.shared.provideThreadDataset(hex: hex)
    }

    // MARK: - 系统 Thread 凭证

    /// 读取系统已保存的 Thread 网络（THClient；模拟器 / 无 entitlement 时降级提示）。
    func loadSystemNetworks() {
        guard !isLoadingSystemNetworks else { return }
        isLoadingSystemNetworks = true
        systemNetworkMessage = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let result = await ThreadCredentialProvider.loadNetworks()
            self.systemNetworks = result.networks
            self.systemNetworkMessage = result.message
            self.isLoadingSystemNetworks = false
            LogStore.shared.log(
                category: .commissioning, level: .debug,
                message: "读取系统 Thread 凭证", detail: [
                    "网络数": "\(result.networks.count)",
                    "提示": result.message ?? "-",
                ]
            )
        }
    }

    /// 选中某个系统网络：回填 dataset 字段；若正暂停等待 Thread 凭证则直接提供。
    func selectSystemNetwork(_ network: SystemThreadNetwork) {
        guard let hex = network.activeOperationalDatasetHex, !hex.isEmpty else {
            systemNetworkMessage = "该凭证缺少 Active Operational Dataset，无法直接用于配网"
            return
        }
        threadDatasetHex = hex
        if case .thread = credentialRequest {
            provideThread(hex: hex)
        }
    }

    // MARK: - 附近待配网设备

    /// 开始 / 停止扫描附近的待配网设备（DNS-SD / 蓝牙广播）。
    func toggleBrowse() {
        if isBrowsing {
            DeviceService.shared.stopBrowse()
            isBrowsing = false
            discovered = []
            return
        }
        discovered = []
        browseMessage = nil
        isBrowsing = DeviceService.shared.startBrowse(
            onFound: { [weak self] device in
                Task { @MainActor in
                    guard let self else { return }
                    if let index = self.discovered.firstIndex(where: { $0.id == device.id }) {
                        self.discovered[index] = device
                    } else {
                        self.discovered.append(device)
                    }
                }
            },
            onLost: { [weak self] instanceName in
                Task { @MainActor in
                    self?.discovered.removeAll { $0.instanceName == instanceName }
                }
            }
        )
        if !isBrowsing {
            browseMessage = "无法开始扫描：Matter 控制器未就绪（请确认本地网络权限并查看设置页诊断）"
        }
    }

    /// 点选发现的设备，进入配对码输入。
    func selectDiscoveredDevice(_ device: DiscoveredDevice) {
        pendingDevice = device
        pairingCodeInput = ""
        pairingCodeError = nil
    }

    func cancelPendingDevice() {
        pendingDevice = nil
        pairingCodeInput = ""
        pairingCodeError = nil
    }

    /// 点「添加」：解析配对码后立即发起配网；所选网络凭证不完整时先弹凭证输入。
    func addDiscoveredDevice() {
        guard let device = pendingDevice else { return }
        let digits = pairingCodeDigits
        guard digits.count == 11 else {
            pairingCodeError = "配对码应为 11 位数字，例如 0203-013-5439"
            return
        }
        inputText = digits
        parsePayload()
        if let parseError {
            pairingCodeError = parseError
            return
        }
        LogStore.shared.log(
            category: .commissioning, level: .info,
            message: "由配对码添加设备",
            detail: ["设备": device.instanceName, "配对码": Self.groupedPairingCode(digits)]
        )
        cancelPendingDevice()
        // 凭证窗口始终弹出（默认「无」），由用户确认或补全后再开始配网。
        // 等配对码弹窗收起后再弹凭证窗口，避免两个 sheet 同时切换。
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            credentialRequest = selectedNetwork
            showCredentialSheet = true
        }
    }
}
