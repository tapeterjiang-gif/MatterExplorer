import SwiftUI

/// 集群工具：从设备详情进入，浏览 端点 → 集群 → 属性 → 读 / 写 / 命令 / 订阅操作页。
/// 挂在设备 Tab 的 NavigationStack 内，不自建 NavigationStack。
struct ClusterIOView: View {
    let nodeID: UInt64
    let deviceName: String

    @State private var viewModel = ClusterToolViewModel()

    var body: some View {
        endpointList
            .navigationDestination(for: ClusterRoute.self) { route in
                destination(for: route)
            }
            .secondaryPageTitle("集群工具 · \(deviceName)")
    }

    // MARK: - 路由分发

    @ViewBuilder
    private func destination(for route: ClusterRoute) -> some View {
        switch route {
        case .clusters(let nodeID, let endpointID):
            clusterList(nodeID: nodeID, endpointID: endpointID)
        case .attributes(let nodeID, let endpointID, let clusterID):
            attributeList(nodeID: nodeID, endpointID: endpointID, clusterID: clusterID)
        case .operation(let nodeID, let endpointID, let clusterID, let attributeID):
            operationView(nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, attributeID: attributeID)
        }
    }

    // MARK: - 端点

    private var endpointList: some View {
        List {
            Section {
                if let message = viewModel.endpointMessage {
                    Label(message, systemImage: viewModel.endpoints.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(viewModel.endpoints.isEmpty ? .orange : .secondary)
                }
                Button(viewModel.isLoadingEndpoints ? "正在发现…" : "发现端点") {
                    viewModel.discoverEndpoints(nodeID: nodeID)
                }
                .disabled(viewModel.isLoadingEndpoints)
            }
            Section("端点（\(viewModel.endpoints.count)）") {
                if viewModel.endpoints.isEmpty {
                    Text("未发现端点。点击上方「发现端点」读取 Descriptor.PartsList。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.endpoints) { endpoint in
                    NavigationLink(value: ClusterRoute.clusters(nodeID, endpoint.endpointID)) {
                        HStack {
                            Text(endpoint.title)
                            Spacer()
                            if let clusters = viewModel.clustersByEndpoint[endpoint.endpointID] {
                                Text("\(clusters.count) 集群").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if viewModel.endpoints.isEmpty {
                viewModel.discoverEndpoints(nodeID: nodeID)
            }
        }
    }

    // MARK: - 集群

    private func clusterList(nodeID: UInt64, endpointID: UInt16) -> some View {
        let clusters = viewModel.clustersByEndpoint[endpointID] ?? []
        return List {
            Section("服务器集群（\(clusters.count)）") {
                if viewModel.isLoadingClusters.contains(endpointID) {
                    ProgressView("正在读取 Descriptor.ServerList…")
                } else if clusters.isEmpty {
                    Text("该端点未发现服务器集群。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(clusters) { cluster in
                    NavigationLink(value: ClusterRoute.attributes(nodeID, endpointID, cluster.clusterID)) {
                        HStack {
                            Text(cluster.title)
                            Spacer()
                            Text(cluster.detailText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .secondaryPageTitle("端点 \(endpointID)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("重新发现") { viewModel.discoverClusters(nodeID: nodeID, endpointID: endpointID) }
                    .disabled(viewModel.isLoadingClusters.contains(endpointID))
            }
        }
        .onAppear {
            if viewModel.clustersByEndpoint[endpointID] == nil {
                viewModel.discoverClusters(nodeID: nodeID, endpointID: endpointID)
            }
        }
    }

    // MARK: - 属性

    private func attributeList(nodeID: UInt64, endpointID: UInt16, clusterID: UInt32) -> some View {
        let attributes = viewModel.attributes(for: clusterID)
        return List {
            Section("属性（\(attributes.count)）") {
                ForEach(attributes) { attribute in
                    NavigationLink(value: ClusterRoute.operation(nodeID, endpointID, clusterID, attribute.attributeID)) {
                        HStack {
                            Text(attribute.title)
                            Spacer()
                            Text(attribute.detailText).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("手动添加属性") {
                TextField("属性 ID（十进制或 0x 十六进制）", text: $viewModel.manualAttributeText)
                    .keyboardType(.numbersAndPunctuation)
                Button("添加") { viewModel.addManualAttribute(clusterID: clusterID) }
                if let inputError = viewModel.inputError {
                    Text(inputError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .secondaryPageTitle("\(ClusterCatalog.clusterName(clusterID)) · 端点 \(endpointID)")
    }

    // MARK: - 操作页

    private func operationView(nodeID: UInt64, endpointID: UInt16, clusterID: UInt32, attributeID: UInt32) -> some View {
        ClusterOperationView(
            viewModel: viewModel,
            nodeID: nodeID,
            endpointID: endpointID,
            clusterID: clusterID,
            attributeID: attributeID
        )
    }
}

// MARK: - 属性操作页（读 / 写 / 命令 / 订阅）

private struct ClusterOperationView: View {
    @Bindable var viewModel: ClusterToolViewModel
    let nodeID: UInt64
    let endpointID: UInt16
    let clusterID: UInt32
    let attributeID: UInt32

    var body: some View {
        List {
            readSection
            writeSection
            commandSection
            subscriptionSection
            errorSection
        }
        .secondaryPageTitle(ClusterCatalog.attributeName(clusterID: clusterID, attributeID: attributeID))
        .onDisappear {
            viewModel.unsubscribe()
        }
    }

    // MARK: 读

    private var readSection: some View {
        Section("读属性") {
            Button {
                viewModel.read(nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, attributeID: attributeID)
            } label: {
                if viewModel.isReading {
                    HStack { ProgressView(); Text("读取中…") }
                } else {
                    Label("读取 \(ClusterCatalog.attributeName(clusterID: clusterID, attributeID: attributeID))", systemImage: "arrow.down.circle")
                }
            }
            .disabled(viewModel.isReading)
            if let result = viewModel.lastResult {
                OperationResultCard(result: result)
            }
        }
    }

    // MARK: 写

    private var writeSection: some View {
        Section {
            TextEditor(text: $viewModel.writeJSON)
                .font(.caption.monospaced())
                .frame(minHeight: 60)
                .autocorrectionDisabled()
        } header: {
            Text("写属性（JSON 值：true / 42 / \"文本\" / null / [1,2] / {\"0\": …}）")
        } footer: {
            Button("写入") {
                viewModel.write(nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, attributeID: attributeID)
            }
        }
    }

    // MARK: 命令

    private var commandSection: some View {
        Section {
            TextEditor(text: $viewModel.commandJSON)
                .font(.caption.monospaced())
                .frame(minHeight: 60)
                .autocorrectionDisabled()
        } header: {
            Text("调用命令（JSON 对象 {\"字段标签\": 值}）")
        } footer: {
            Button("调用") {
                viewModel.invoke(nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, commandID: attributeID)
            }
        }
    }

    // MARK: 订阅

    private var subscriptionSection: some View {
        Section {
            HStack {
                Label("设备状态：\(viewModel.deviceState)", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.subheadline)
                Spacer()
                Button(viewModel.isSubscribed ? "取消订阅" : "订阅") {
                    viewModel.toggleSubscription(nodeID: nodeID, endpointID: endpointID, clusterID: clusterID, attributeID: attributeID)
                }
            }
            if viewModel.isSubscribed {
                Button("清空流") { viewModel.clearSubscriptionReports() }
                ForEach(viewModel.subscriptionReports) { report in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(report.timestamp.formatted(date: .omitted, time: .standard))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(report.valueJSON)
                            .font(.caption.monospaced())
                    }
                }
            }
        } header: {
            Text("订阅实时报告")
        } footer: {
            Text("订阅期间收到的属性报告将实时显示，退出本页自动取消。")
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let error = viewModel.operationError {
            Section {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    NavigationStack {
        ClusterIOView(nodeID: 1, deviceName: "示例设备")
    }
}
