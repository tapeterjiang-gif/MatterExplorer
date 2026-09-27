import SwiftUI

/// 设备管理页：fabric 归属（查看 / 移除本 fabric）+ 设备标识写入（NodeLabel / Location）
/// + 网络凭证管理（Wi-Fi / Thread 增删连）。破坏性操作均需二次确认。
struct DeviceAdminView: View {
    let nodeID: UInt64
    let deviceName: String

    @State private var viewModel = DeviceAdminViewModel()
    @State private var isConfirmingRemoveFabric = false
    @State private var networkToRemove: ConfiguredNetworkInfo?

    var body: some View {
        List {
            fabricSection
            identitySection
            networkSection

            if let message = viewModel.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let operation = viewModel.lastOperation {
                Section("最近一次操作") {
                    OperationResultCard(result: operation)
                }
            }
        }
        .secondaryPageTitle("设备管理 · \(deviceName)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") { viewModel.refresh(nodeID: nodeID) }
            }
        }
        .task {
            viewModel.load(nodeID: nodeID)
        }
        .confirmationDialog(
            "移除本 fabric（设备退网）？",
            isPresented: $isConfirmingRemoveFabric,
            titleVisibility: .visible
        ) {
            Button("移除 fabric \(viewModel.localFabricIndex.map(String.init) ?? "")", role: .destructive) {
                viewModel.removeLocalFabric(nodeID: nodeID)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将向设备的 Operational Credentials 集群发送 RemoveFabric。设备会解除与本 App 的配网关系，"
                + "已保存的 ACL / 订阅随之失效；若设备仍有其它 fabric 则不会被恢复出厂。此操作不可撤销。")
        }
        .confirmationDialog(
            "移除该网络凭证？",
            isPresented: Binding(
                get: { networkToRemove != nil },
                set: { if !$0 { networkToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: networkToRemove
        ) { network in
            Button("移除 networkID \(network.shortID)…", role: .destructive) {
                viewModel.removeNetwork(nodeID: nodeID, networkIDHex: network.networkIDHex)
                networkToRemove = nil
            }
            Button("取消", role: .cancel) { networkToRemove = nil }
        } message: { _ in
            Text("将向 Network Commissioning 集群发送 RemoveNetwork。若设备当前仅依赖该网络在线，移除后可能失联。")
        }
    }

    // MARK: - Fabric 归属

    private var fabricSection: some View {
        Section {
            if viewModel.isLoadingFabrics {
                HStack { ProgressView(); Text("正在读取 Fabrics 属性…") }
            } else if viewModel.fabrics.isEmpty {
                Text("尚未读取。Fabrics 属性列出了设备当前加入的所有 fabric。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.fabrics) { fabric in
                    fabricRow(fabric)
                }
            }

            Button {
                viewModel.loadFabrics(nodeID: nodeID)
            } label: {
                Label("读取 fabric 列表", systemImage: "arrow.down.circle")
            }
            .disabled(viewModel.isLoadingFabrics)

            if let localIndex = viewModel.localFabricIndex {
                Button(role: .destructive) {
                    isConfirmingRemoveFabric = true
                } label: {
                    HStack {
                        Label("移除本 fabric（设备退网）", systemImage: "minus.circle")
                        if viewModel.isRemovingFabric {
                            Spacer()
                            ProgressView().controlSize(.mini)
                        }
                    }
                }
                .disabled(viewModel.isRemovingFabric)
                .accessibilityHint("fabric 索引 \(localIndex)")
            }
        } header: {
            Text("Fabric 归属（Operational Credentials 0x3E）")
        } footer: {
            if viewModel.localFabricIndex == nil && !viewModel.fabrics.isEmpty {
                Text("未在本机控制器已知 fabric 中匹配到设备上的条目，无法执行移除。")
            } else {
                Text("标记「本 fabric」的条目属于本机控制器；移除后设备退网并自动从本地设备列表删除。")
            }
        }
    }

    private func fabricRow(_ fabric: FabricEntryInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("fabric 索引 \(fabric.fabricIndex)")
                if fabric.isLocal {
                    Text("本 fabric")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
            }
            Text("fabricID \(fabric.fabricID) · nodeID \(fabric.nodeID)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("VendorID \(fabric.vendorText) · 标签 \(fabric.labelText)")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("根公钥 \(String(fabric.rootPublicKeyHex.prefix(24)))…")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    // MARK: - 设备标识

    private var identitySection: some View {
        Section {
            if viewModel.isLoadingIdentity {
                HStack { ProgressView(); Text("正在读取 NodeLabel / Location…") }
            }

            HStack {
                TextField("NodeLabel（≤32 字符）", text: $viewModel.nodeLabelDraft)
                Button("保存") { viewModel.saveNodeLabel(nodeID: nodeID) }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.isNodeLabelDirty || !viewModel.isNodeLabelValid || viewModel.isSavingNodeLabel)
            }
            if !viewModel.isNodeLabelValid {
                Text("NodeLabel 超出 32 字符上限")
                    .font(.caption2).foregroundStyle(.red)
            }

            HStack {
                TextField("Location（ISO 3166-1，如 CN）", text: $viewModel.locationDraft)
                Button("保存") { viewModel.saveLocation(nodeID: nodeID) }
                    .buttonStyle(.borderless)
                    .disabled(!viewModel.isLocationDirty || !viewModel.isLocationValid || viewModel.isSavingLocation)
            }
            if !viewModel.isLocationValid {
                Text("Location 只允许最多 2 个字符")
                    .font(.caption2).foregroundStyle(.red)
            }
        } header: {
            Text("设备标识（Basic Information 0x28）")
        } footer: {
            Text("写入设备自身的 NodeLabel（0x0005）/ Location（0x0006）属性，可用于核对设备端写入能力；清空内容后保存等于写空串。")
        }
    }

    // MARK: - 网络凭证

    private var networkSection: some View {
        Section {
            if viewModel.isLoadingInterfaces {
                HStack { ProgressView(); Text("正在发现 Network Commissioning 实例…") }
            } else if viewModel.interfaces.isEmpty {
                Text("设备未报告 Network Commissioning 集群（0x31）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if viewModel.interfaces.count > 1 {
                    Picker("端点", selection: $viewModel.selectedEndpointID) {
                        ForEach(viewModel.interfaces) { interface in
                            Text("端点 \(interface.endpointID) · \(interface.kindsText)")
                                .tag(Optional(interface.endpointID))
                        }
                    }
                }

                if let selected = viewModel.selectedInterface {
                    configuredNetworks(selected)

                    if selected.supportsWiFi {
                        wifiForm
                    }
                    if selected.supportsThread {
                        threadForm
                    }
                    if !selected.supportsWiFi && !selected.supportsThread {
                        Text("该接口为以太网：无需网络凭证，可用下方命令仅做网络列表维护。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                viewModel.loadInterfaces(nodeID: nodeID)
            } label: {
                Label("重新发现网络接口", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingInterfaces)
        } header: {
            Text("网络凭证（Network Commissioning 0x31）")
        } footer: {
            Text("凭证写入后需再发送 ConnectNetwork 才会真正切换网络；设备切换网络期间可能短暂离线。")
        }
    }

    @ViewBuilder
    private func configuredNetworks(_ interface: NetworkInterfaceInfo) -> some View {
        if interface.networks.isEmpty {
            Text("端点 \(interface.endpointID) 尚未配置任何网络。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        ForEach(interface.networks) { network in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text("networkID \(network.shortID)…")
                        .font(.caption.monospaced())
                    if network.connected {
                        Text("已连接")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                HStack {
                    Button {
                        viewModel.connectNetwork(nodeID: nodeID, networkIDHex: network.networkIDHex)
                    } label: {
                        pendingLabel(
                            "连接", systemImage: "link",
                            key: "connect-\(interface.endpointID)-\(network.networkIDHex)"
                        )
                    }
                    .buttonStyle(.borderless)
                    .disabled(viewModel.isPending("connect-\(interface.endpointID)-\(network.networkIDHex)"))

                    Spacer()

                    Button(role: .destructive) {
                        networkToRemove = network
                    } label: {
                        Label("移除", systemImage: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var wifiForm: some View {
        Group {
            TextField("Wi-Fi SSID（≤32 字节）", text: $viewModel.wifiSSID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Wi-Fi 密码（WPA2 PSK，8–63 字节）", text: $viewModel.wifiPassword)
            Button {
                viewModel.addOrUpdateWiFi(nodeID: nodeID)
            } label: {
                pendingLabel(
                    "添加 / 更新 Wi-Fi 网络", systemImage: "wifi",
                    key: "wifi-\(viewModel.selectedEndpointID ?? 0)"
                )
            }
            .disabled(
                !viewModel.isSSIDValid || !viewModel.isPasswordValid
                    || viewModel.isPending("wifi-\(viewModel.selectedEndpointID ?? 0)")
            )
        }
    }

    private var threadForm: some View {
        Group {
            TextField("Thread operational dataset（十六进制）", text: $viewModel.threadDatasetHex)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.caption.monospaced())
            if !viewModel.threadDatasetHex.isEmpty && !viewModel.isThreadDatasetValid {
                Text("dataset 需为合法十六进制（至少 4 字节）")
                    .font(.caption2).foregroundStyle(.red)
            }
            Button {
                viewModel.addOrUpdateThread(nodeID: nodeID)
            } label: {
                pendingLabel(
                    "添加 / 更新 Thread 网络", systemImage: "point.3.connected.trianglepath.dotted",
                    key: "thread-\(viewModel.selectedEndpointID ?? 0)"
                )
            }
            .disabled(!viewModel.isThreadDatasetValid || viewModel.isPending("thread-\(viewModel.selectedEndpointID ?? 0)"))
        }
    }

    private func pendingLabel(_ title: String, systemImage: String, key: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            if viewModel.isPending(key) {
                Spacer()
                ProgressView().controlSize(.mini)
            }
        }
    }
}

#Preview {
    NavigationStack {
        DeviceAdminView(nodeID: 1, deviceName: "示例设备")
    }
}