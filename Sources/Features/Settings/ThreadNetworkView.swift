import SwiftUI

/// Thread 网络子页：读取并展示系统已保存 / 附近的 Thread 网络凭证（THClient）。
///
/// 「已保存」为当前 Team ID 保存的凭证，进入页面时静默读取、下拉可刷新；
/// 「附近」为系统发现的活跃网络，需用户授权，故只在点按按钮时读取。
/// 模拟器构建不含 ThreadNetwork.framework，此时只展示降级说明。
struct ThreadNetworkView: View {
    @State private var networks: [SystemThreadNetwork] = []
    @State private var message: String?
    @State private var isLoadingSaved = false
    @State private var isLoadingNearby = false

    private var isBusy: Bool { isLoadingSaved || isLoadingNearby }

    var body: some View {
        List {
            if ThreadCapability.isSupported {
                actionsSection
            } else {
                unavailableSection
            }
            networksSection
        }
        .secondaryPageTitle("Thread 网络")
        .task { await loadSaved() }
        .refreshable { await loadSaved() }
    }

    // MARK: - 系统凭证

    private var actionsSection: some View {
        Section {
            Button {
                Task { await loadNearby() }
            } label: {
                Label(
                    isLoadingNearby ? "正在读取…" : "读取附近网络",
                    systemImage: "dot.radiowaves.left.and.right"
                )
            }
            .disabled(isBusy)

            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("系统凭证")
        } footer: {
            Text("已保存网络在进入本页时静默读取、下拉可刷新；「读取附近网络」会弹出系统授权提示。")
        }
    }

    private var unavailableSection: some View {
        Section {
            Text(ThreadCapability.unavailableMessage)
                .font(.callout)
        } header: {
            Text("系统凭证")
        } footer: {
            Text("需真机运行，且应用具备 com.apple.developer.networking.manage-thread-network-credentials 权限；该权限由 Apple 单独授予，当前工程未配置。")
        }
    }

    // MARK: - 网络列表

    private var networksSection: some View {
        Section {
            if networks.isEmpty {
                Text(isBusy ? "正在读取…" : "暂无 Thread 网络")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(networks) { network in
                    networkRow(network)
                }
            }
        } header: {
            Text("已读取网络（\(networks.count)）")
        } footer: {
            Text("来源：THClient 读取的系统凭证。dataset 即 Active Operational Dataset，可直接用于 Thread 设备配网。")
        }
    }

    /// 单个网络：名称与 dataset 拷贝入口，其余字段为明细行。
    private func networkRow(_ network: SystemThreadNetwork) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(network.networkName)
                    .font(.callout)
                if !network.isDatasetComplete {
                    Text("缺少 dataset")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.5), in: Capsule())
                }
                Spacer(minLength: 4)
                if let hex = network.activeOperationalDatasetHex, !hex.isEmpty {
                    CopyButton(value: hex)
                }
            }
            DetailLine("信道", "\(network.channel)")
            DetailLine("Extended PAN ID", network.extendedPANID ?? "—")
            DetailLine("PAN ID", network.panID ?? "—")
            DetailLine("Dataset", datasetSummary(network))
            if let borderAgentID = network.borderAgentID, !borderAgentID.isEmpty {
                DetailLine("Border Agent", borderAgentID)
            }
        }
        .padding(.vertical, 3)
    }

    /// dataset 摘要：只给存在性与字节数，完整取值由拷贝按钮带走。
    private func datasetSummary(_ network: SystemThreadNetwork) -> String {
        guard let hex = network.activeOperationalDatasetHex, !hex.isEmpty else { return "无" }
        return "已包含 · \(hex.count / 2) 字节"
    }

    // MARK: - 读取

    private func loadSaved() async {
        guard !isLoadingSaved else { return }
        isLoadingSaved = true
        let result = await ThreadCredentialProvider.loadSavedNetworks()
        networks = result.networks
        message = result.message
        isLoadingSaved = false
        log("读取系统已保存的 Thread 网络", count: result.networks.count, message: result.message)
    }

    private func loadNearby() async {
        guard !isLoadingNearby else { return }
        isLoadingNearby = true
        let result = await ThreadCredentialProvider.loadNearbyNetworks()
        merge(result.networks)
        message = result.message
        isLoadingNearby = false
        log("读取附近 Thread 网络", count: result.networks.count, message: result.message)
    }

    /// 并入新结果（按 id 去重，同名网络只保留一份）。
    private func merge(_ incoming: [SystemThreadNetwork]) {
        var byID: [String: SystemThreadNetwork] = [:]
        for network in networks { byID[network.id] = network }
        for network in incoming { byID[network.id] = network }
        networks = byID.values.sorted { $0.networkName < $1.networkName }
    }

    private func log(_ what: String, count: Int, message: String?) {
        var detail = ["数量": "\(count)"]
        if let message { detail["说明"] = message }
        LogStore.shared.log(category: .commissioning, level: .debug, message: what, detail: detail)
    }
}

#Preview {
    NavigationStack {
        ThreadNetworkView()
    }
}