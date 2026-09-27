import SwiftUI

/// 设备控制面板：按端点实际支持的集群（ServerList）自动生成控件。
/// 开关 / 识别闪烁 / 亮度 / 色温 / 开合位置，状态经订阅实时回填；原始值同区展示便于核对。
struct DeviceControlView: View {
    let nodeID: UInt64
    let deviceName: String

    @State private var viewModel = DeviceControlViewModel()

    var body: some View {
        List {
            statusSection

            if viewModel.isLoading && viewModel.detection.endpoints.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在探测可控能力（端点 → ServerList → 状态属性）…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(viewModel.detection.endpoints) { snapshot in
                Section {
                    ForEach(snapshot.capabilities) { capability in
                        control(capability, snapshot)
                    }
                } header: {
                    Text("端点 \(snapshot.endpointID) · \(snapshot.capabilities.map(\.title).joined(separator: " / "))")
                } footer: {
                    if !snapshot.notices.isEmpty {
                        Text(snapshot.notices.joined(separator: "\n"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !viewModel.isLoading && viewModel.detection.endpoints.isEmpty {
                Section {
                    ContentUnavailableView(
                        "无可控能力",
                        systemImage: "slider.horizontal.3",
                        description: Text(viewModel.message ?? "该设备未报告 On/Off、Level Control、Color Control、Window Covering 等可控集群。")
                    )
                    Button {
                        viewModel.load(nodeID: nodeID)
                    } label: {
                        Label("重新探测", systemImage: "arrow.clockwise")
                    }
                }
            }

            if let message = viewModel.message, !viewModel.detection.endpoints.isEmpty {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            ForEach(viewModel.detection.endpoints) { snapshot in
                if !snapshot.values.isEmpty {
                    rawValuesSection(snapshot)
                }
            }

            if let operation = viewModel.lastOperation {
                Section("最近一次操作") {
                    OperationResultCard(result: operation)
                }
            }
        }
        .secondaryPageTitle("控制 · \(deviceName)")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("刷新") { viewModel.refresh(nodeID: nodeID) }
                    .disabled(viewModel.isLoading)
            }
        }
        .task { viewModel.load(nodeID: nodeID) }
        .onDisappear { viewModel.stopMonitoring() }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            HStack {
                Text("在线状态").foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.deviceState)
            }
            HStack {
                Text("实时订阅").foregroundStyle(.secondary)
                Spacer()
                Label(
                    viewModel.isSubscribed ? "已订阅" : "未订阅",
                    systemImage: viewModel.isSubscribed ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash"
                )
                .font(.caption)
                .foregroundStyle(viewModel.isSubscribed ? .green : .secondary)
            }
            HStack {
                Text("可控端点").foregroundStyle(.secondary)
                Spacer()
                Text("\(viewModel.detection.endpoints.count)")
            }
        } header: {
            Text("节点 \(nodeID)")
        } footer: {
            Text("订阅期间设备端（物理开关 / 其它控制器）的变化会实时回填下方控件；离开本页自动取消订阅。")
        }
    }

    // MARK: - 控件

    @ViewBuilder
    private func control(_ capability: ControlCapability, _ snapshot: EndpointControlSnapshot) -> some View {
        TraitControlWidget(nodeID: nodeID, capability: capability, snapshot: snapshot, viewModel: viewModel)
    }

    // MARK: - 原始值 / 结果

    private func rawValuesSection(_ snapshot: EndpointControlSnapshot) -> some View {
        Section("端点 \(snapshot.endpointID) · 状态原始值") {
            ForEach(snapshot.values.keys.sorted(by: { ($0.clusterID, $0.attributeID) < ($1.clusterID, $1.attributeID) }), id: \.self) { key in
                HStack {
                    Text(DeviceControlCatalog.attributeName(key))
                        .font(.caption)
                    Spacer()
                    Text(rawText(snapshot.values[key]))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func rawText(_ scalar: MatterScalar?) -> String {
        guard let scalar else { return "—" }
        switch scalar {
        case .string(let value): return value.isEmpty ? "（空）" : value
        case .bool(let value): return value ? "true" : "false"
        case .number(let value):
            return value == value.rounded() ? String(Int(value)) : String(value)
        case .bytes(let value): return value
        case .null: return "null"
        case .array(let items): return "[\(items.count) 项]"
        case .structure(let fields): return "{结构体 \(fields.count) 字段}"
        case .unsupported(let type): return "不支持的类型 \(type)"
        }
    }
}

#Preview {
    NavigationStack {
        DeviceControlView(nodeID: 1, deviceName: "示例灯具")
    }
}