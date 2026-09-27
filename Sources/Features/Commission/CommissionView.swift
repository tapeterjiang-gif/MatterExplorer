import SwiftUI
import VisionKit

/// 配网模块：附近待配网设备扫描 → payload 输入/解析 → 网络凭证选择 → 配网进度。
struct CommissionView: View {
    @State private var viewModel = CommissionViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var viewModel = viewModel
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    discoverySection(viewModel: viewModel)
                    // Onboarding Payload 输入区暂时移除（用户要求）；恢复时取消下一行注释。
                    // inputSection(viewModel: viewModel)
                    // 网络凭证选择只由「添加」后弹出的对话框承载，不再内嵌在本页（用户要求）；
                    // 解析结果同属已移除的 payload 输入流程，一并隐藏。恢复时取消以下注释。
                    // if viewModel.parsed != nil {
                    //     parseResultSection(viewModel: viewModel)
                    //     credentialSection(viewModel: viewModel)
                    // }
                }
                .padding()
            }
            .rootPageTitle("配网")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .sheet(isPresented: $viewModel.showScanner) {
                scannerSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showProgress) {
                ProgressSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.showCredentialSheet) {
                CredentialRequestSheet(viewModel: viewModel)
            }
            .sheet(item: $viewModel.pendingDevice) { device in
                pairingCodeSheet(viewModel: viewModel, device: device)
            }
        }
    }

    // MARK: - 附近待配网设备

    @ViewBuilder
    private func discoverySection(viewModel: CommissionViewModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("附近待配网设备", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button(viewModel.isBrowsing ? "停止扫描" : "扫描") {
                    viewModel.toggleBrowse()
                }
                .buttonStyle(.bordered)
            }

            if viewModel.isBrowsing && viewModel.discovered.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("正在扫描局域网 / 蓝牙中的待配网设备…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(viewModel.discovered) { device in
                Button {
                    viewModel.selectDiscoveredDevice(device)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.title)
                                .font(.callout)
                            Text(device.detailText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if let message = viewModel.browseMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("扫描结果来自 DNS-SD / 蓝牙广播。点选设备并输入标签上的 11 位配对码即可直接配网。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - 配对码输入

    /// 输入设备标签上的 11 位配对码，点「添加」填入并解析 payload。
    private func pairingCodeSheet(
        viewModel: CommissionViewModel,
        device: DiscoveredDevice
    ) -> some View {
        @Bindable var viewModel = viewModel
        return NavigationStack {
            Form {
                Section("设备") {
                    Text(device.title)
                    Text(device.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    TextField("0203-013-5439", text: $viewModel.pairingCodeInput)
                        .keyboardType(.numberPad)
                        .font(.system(.title2, design: .monospaced))
                        .onChange(of: viewModel.pairingCodeInput) {
                            viewModel.normalizePairingCode()
                        }
                    if let error = viewModel.pairingCodeError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("配对码")
                } footer: {
                    Text("即设备标签 / 二维码下方的 11 位数字配对码（4-3-4 分组），添加后会解析为 onboarding payload。")
                }
            }
            .navigationTitle("输入配对码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { viewModel.cancelPendingDevice() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") { viewModel.addDiscoveredDevice() }
                }
            }
        }
    }

    // MARK: - 输入

    @ViewBuilder
    private func inputSection(viewModel: CommissionViewModel) -> some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 12) {
            Label("Onboarding Payload", systemImage: "barcode.viewfinder")
                .font(.headline)

            if DataScannerViewController.isSupported {
                Button {
                    viewModel.showScanner = true
                } label: {
                    Label("扫描二维码", systemImage: "qrcode.viewfinder")
                }
                .buttonStyle(.bordered)
            } else {
                Text("当前设备不支持扫码（模拟器）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField(
                "粘贴 QR 字符串或 Manual Pairing Code",
                text: $viewModel.inputText,
                axis: .vertical
            )
            .font(.system(.body, design: .monospaced))
            .textFieldStyle(.roundedBorder)
            .lineLimit(2...4)

            HStack {
                Button("解析 Payload") { viewModel.parsePayload() }
                    .buttonStyle(.borderedProminent)
                Button("示例") {
                    viewModel.inputText = samplePayload
                    viewModel.parsePayload()
                }
                .buttonStyle(.bordered)
            }

            if let parseError = viewModel.parseError {
                Text(parseError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 解析结果

    @ViewBuilder
    private func parseResultSection(viewModel: CommissionViewModel) -> some View {
        let p = viewModel.parsed!
        GroupBox("解析结果") {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                resultRow("版本", p.version.map(String.init) ?? "-")
                resultRow("Vendor ID", p.vendorID.map(String.init) ?? "-")
                resultRow("Product ID", p.productID.map(String.init) ?? "-")
                resultRow("Discriminator", p.discriminator.map(String.init) ?? "-")
                resultRow("Short", p.hasShortDiscriminator ? "是" : "否")
                resultRow("Setup PIN", p.setupPasscode.map(String.init) ?? "-")
                resultRow("发现能力", p.capabilities.joined(separator: ", "))
                resultRow("配网模式", p.flow)
                resultRow("序列号", p.serialNumber ?? "-")
                resultRow("Manual Code", p.manualCode ?? "-")
            }
            .font(.system(.caption, design: .monospaced))
        }
    }

    private func resultRow(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .gridColumnAlignment(.leading)
        }
    }

    // MARK: - 凭证选择

    @ViewBuilder
    private func credentialSection(viewModel: CommissionViewModel) -> some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 12) {
            Label("网络凭证", systemImage: "wifi")
                .font(.headline)

            Picker("网络类型", selection: $viewModel.networkKind) {
                ForEach(NetworkKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            switch viewModel.networkKind {
            case .wifi:
                TextField("Wi-Fi SSID", text: $viewModel.wifiSSID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                SecureField("密码（开放网络可留空）", text: $viewModel.wifiPassword)
                    .textFieldStyle(.roundedBorder)
            case .thread:
                if !viewModel.threadScanResults.isEmpty {
                    scannedThreadNetworks(viewModel: viewModel)
                }
                TextField(
                    "Active Operational Dataset（十六进制）",
                    text: $viewModel.threadDatasetHex,
                    axis: .vertical
                )
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .lineLimit(2...4)
                threadHexHint(viewModel.threadDatasetHex)
                SystemThreadNetworkSection(viewModel: viewModel)
            case .none:
                Text("设备已在线时无需凭证；若设备要求将在此处暂停询问。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let formError = viewModel.formError {
                Text(formError)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            Button {
                viewModel.startCommissioning()
            } label: {
                Label("开始配网", systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isCommissioning)
        }
    }

    // MARK: - Thread 辅助视图

    /// 设备扫描到的 Thread 网络（信息性展示，不含 dataset）。
    @ViewBuilder
    private func scannedThreadNetworks(viewModel: CommissionViewModel) -> some View {
        GroupBox("设备扫描到的 Thread 网络") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(viewModel.threadScanResults) { result in
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                        Text(result.networkName)
                            .font(.callout)
                        Spacer()
                        Text("信道 \(result.channel) · RSSI \(result.rssi)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("以上为设备探测到的附近网络，仅作参考；凭证需使用其 Active Operational Dataset。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 扫码

    private func scannerSheet(viewModel: CommissionViewModel) -> some View {
        NavigationStack {
            QRScannerView { text in
                viewModel.handleScanned(text)
            }
            .navigationTitle("扫描 Matter 二维码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { viewModel.showScanner = false }
                }
            }
        }
    }
}

// MARK: - 配网进度页

/// 配网进度：状态机阶段列表 + 每阶段耗时 + MTRMetrics 指标 + 结果。
struct ProgressSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: CommissionViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    resultHeader
                    stagesSection
                    if !viewModel.progress.metrics.isEmpty {
                        metricsSection
                    }
                }
                .padding()
            }
            .navigationTitle("配网进度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if viewModel.isCommissioning {
                        Button("停止", role: .destructive) {
                            viewModel.stopCommissioning()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var resultHeader: some View {
        if let nodeID = viewModel.progress.succeededNodeID {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                VStack(alignment: .leading) {
                    Text("配网成功").font(.title2).bold()
                    Text("Node ID: \(nodeID)")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        } else if let failure = viewModel.progress.failureMessage {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                    Text("配网失败").font(.title2).bold()
                }
                Text(failure)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                Text("排查提示：设备仍处于配网模式吗？是否已加入其它 fabric？PASE 重试次数是否耗尽？")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text(viewModel.isCommissioning ? "正在配网…" : "配网已停止")
                    .font(.title3)
            }
        }
    }

    @ViewBuilder
    private var stagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("状态机", systemImage: "arrow.triangle.branch")
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(viewModel.progress.stages) { stage in
                    stageRow(stage)
                    if stage.phase != .done {
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.2), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func stageRow(_ stage: CommissioningStageState) -> some View {
        HStack(spacing: 10) {
            stageIcon(stage.status)
            Text(stage.phase.rawValue)
                .font(.callout)
            Spacer()
            if let duration = stage.duration {
                Text(String(format: "%.2fs", duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let note = stage.note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func stageIcon(_ status: CommissioningStageState.Status) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle").foregroundStyle(.secondary)
        case .active:
            Image(systemName: "circle.dotted").foregroundStyle(.blue)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("MTRMetrics 指标", systemImage: "gauge")
                .font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("指标").foregroundStyle(.secondary)
                    Text("值").foregroundStyle(.secondary)
                    Text("耗时").foregroundStyle(.secondary)
                    Text("错误码").foregroundStyle(.secondary)
                }
                .font(.caption)
                Divider()
                ForEach(viewModel.progress.metrics) { metric in
                    GridRow {
                        Text(metric.key)
                        Text(metric.value.map { String(format: "%.3f", $0) } ?? "-")
                        Text(metric.duration.map { String(format: "%.3fs", $0) } ?? "-")
                        Text(metric.errorCode.map { MatterHex.hex($0, width: 2) } ?? "-")
                    }
                    .font(.system(.caption, design: .monospaced))
                }
            }
        }
    }
}

// MARK: - 凭证请求弹窗

/// 从系统读取已保存的 Thread 凭证（THClient）的入口与列表。
/// 选中后回填 dataset；若正暂停等待 Thread 凭证则直接提供。
struct SystemThreadNetworkSection: View {
    let viewModel: CommissionViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                viewModel.loadSystemNetworks()
            } label: {
                if viewModel.isLoadingSystemNetworks {
                    Label("正在读取…", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label("从系统读取已保存的 Thread 凭证", systemImage: "network")
                }
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.isLoadingSystemNetworks)

            if !viewModel.systemNetworks.isEmpty {
                ForEach(viewModel.systemNetworks) { network in
                    Button {
                        viewModel.selectSystemNetwork(network)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(network.networkName)
                                    .font(.callout)
                                Text(
                                    "信道 \(network.channel)"
                                        + (network.isDatasetComplete ? " · 含完整 dataset" : " · 缺少 dataset")
                                )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let message = viewModel.systemNetworkMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 凭证窗口：「添加」后由用户选择网络类型（Wi-Fi / Thread / 无），或配网中途由框架回调 needsWiFi / needsThread 触发输入。
struct CredentialRequestSheet: View {
    @Environment(\.dismiss) private var dismiss
    let viewModel: CommissionViewModel

    var body: some View {
        NavigationStack {
            Form {
                if !viewModel.isCommissioning {
                    networkKindSection
                }

                switch effectiveKind {
                case .wifi:
                    wifiCredentialSection
                case .thread:
                    threadCredentialSection
                case .none:
                    EmptyView()
                }
            }
            .navigationTitle("网络凭证")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        viewModel.credentialRequest = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { confirm() }
                        .disabled(!canConfirm)
                }
            }
        }
    }

    // MARK: - 表单分区

    /// 由「添加」发起时先选网络类型；配网中途由设备请求决定，故不再展示选择器。
    @ViewBuilder
    private var networkKindSection: some View {
        @Bindable var viewModel = viewModel
        Section {
            Picker("网络类型", selection: $viewModel.networkKind) {
                ForEach(NetworkKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("网络凭证")
        } footer: {
            Text("默认「无」：设备已在线时可直接完成配网；若设备要求凭证，会在此再次询问。")
        }
    }

    @ViewBuilder
    private var wifiCredentialSection: some View {
        @Bindable var viewModel = viewModel
        Section("Wi-Fi 凭证") {
            TextField("SSID", text: $viewModel.wifiSSID)
                .autocorrectionDisabled()
            SecureField("密码（开放网络可留空）", text: $viewModel.wifiPassword)
        }
    }

    @ViewBuilder
    private var threadCredentialSection: some View {
        @Bindable var viewModel = viewModel
        Section("Thread 凭证") {
            if !viewModel.threadScanResults.isEmpty {
                ForEach(viewModel.threadScanResults) { result in
                    Label(
                        "\(result.networkName) · 信道 \(result.channel) · RSSI \(result.rssi)",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
                    .font(.callout)
                }
                Text("以上为设备探测到的附近网络，凭证需使用其 Active Operational Dataset。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            TextField(
                "Active Operational Dataset（十六进制）",
                text: $viewModel.threadDatasetHex,
                axis: .vertical
            )
            .font(.system(.body, design: .monospaced))
            .lineLimit(2...4)
            threadHexHint(viewModel.threadDatasetHex)
            SystemThreadNetworkSection(viewModel: viewModel)
        }
    }

    /// 有效网络类型：配网中途由设备请求决定，否则取用户选择。
    private var effectiveKind: NetworkKind {
        guard viewModel.isCommissioning, let request = viewModel.credentialRequest else {
            return viewModel.networkKind
        }
        switch request {
        case .wifi: return .wifi
        case .thread: return .thread
        case .none: return .none
        }
    }

    /// 配网中途由设备请求凭证时是「提供」；由「添加」发起的凭证选择则是开始配网。
    private var confirmTitle: String {
        viewModel.isCommissioning ? "提供" : "开始配网"
    }

    /// 开始配网前所选凭证需已填全（配网中途由设备指定，无需校验）。
    private var canConfirm: Bool {
        guard !viewModel.isCommissioning else { return true }
        switch viewModel.networkKind {
        case .wifi: return !viewModel.wifiSSID.trimmingCharacters(in: .whitespaces).isEmpty
        case .thread: return Data(hexString: viewModel.threadDatasetHex) != nil
        case .none: return true
        }
    }

    private func confirm() {
        guard viewModel.isCommissioning else {
            // 由「添加」发起：表单值即 selectedNetwork 的来源；收起窗口后再启动，避免与进度窗口争抢呈现。
            viewModel.credentialRequest = nil
            dismiss()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                viewModel.startCommissioning()
            }
            return
        }
        switch effectiveKind {
        case .wifi:
            viewModel.provideWiFi(ssid: viewModel.wifiSSID, password: viewModel.wifiPassword)
        case .thread:
            viewModel.provideThread(hex: viewModel.threadDatasetHex)
        case .none:
            viewModel.credentialRequest = nil
        }
        dismiss()
    }
}

/// dataset 输入的实时校验提示（有效字节数 / 格式错误）。
@ViewBuilder
private func threadHexHint(_ hex: String) -> some View {
    if hex.isEmpty {
        Text("粘贴设备 / 系统的 Active Operational Dataset（通常 16-32 字节的十六进制）")
            .font(.caption)
            .foregroundStyle(.secondary)
    } else if let data = Data(hexString: hex) {
        Text("已识别：\(data.count) 字节，格式有效")
            .font(.caption)
            .foregroundStyle(.green)
    } else {
        Text("无效：需为偶数位十六进制字符（可含空白）")
            .font(.caption)
            .foregroundStyle(.red)
    }
}

/// 示例 onboarding payload（Matter SDK / chip-tool 常用测试二维码内容）。
private let samplePayload = "MT:-24J0AFN00KA0648G00"

#Preview {
    CommissionView()
}
