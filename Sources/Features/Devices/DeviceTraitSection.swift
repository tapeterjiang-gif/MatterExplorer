import SwiftUI

/// 设备详情页「设备特征」分区：读数卡片 + 可交互控件（开关 / 亮度 / 色温 / 开合位置）。
/// 多端点时按端点分段；读数由订阅实时更新。
struct DeviceTraitSection: View {
    let nodeID: UInt64
    @Bindable var viewModel: DeviceTraitViewModel

    var body: some View {
        Group {
            if let snapshot = viewModel.snapshot, !snapshot.endpoints.isEmpty {
                ForEach(snapshot.endpoints) { endpoint in
                    endpointSection(endpoint, multiple: snapshot.endpoints.count > 1)
                }
            } else {
                placeholderSection
            }
        }
    }

    // MARK: - 分段

    private func endpointSection(_ endpoint: EndpointTraitSnapshot, multiple: Bool) -> some View {
        Section {
            // 单元按顶部对齐：同一行里带控件的卡片更高，若保持默认居中，相邻卡片的标题行会错开。
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(endpoint.readings) { reading in
                    card(reading, endpoint: endpoint)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text(endpointHeader(endpoint, multiple: multiple))
        } footer: {
            if !endpoint.notices.isEmpty {
                Text(endpoint.notices.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 分段标题：多端点时附上设备类型名（DeviceTypeList），便于判断端点划分是否合理
    /// （同一逻辑设备被拆开，还是各自独立的子设备）。
    private func endpointHeader(_ endpoint: EndpointTraitSnapshot, multiple: Bool) -> String {
        guard multiple else { return "设备特征" }
        guard let deviceTypes = endpoint.deviceTypeText else { return "设备特征 · 端点 \(endpoint.endpointID)" }
        return "设备特征 · 端点 \(endpoint.endpointID) · \(deviceTypes)"
    }

    private var placeholderSection: some View {
        Section {
            if viewModel.isLoading {
                HStack {
                    ProgressView()
                    Text("正在读取设备特征（端点 → ServerList → 特征属性）…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("该设备未报告可展示的特征（温度 / 湿度 / 空气质量 / 开关 / 亮度 / 色温 / 开合位置）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.load(nodeID: nodeID)
            } label: {
                Label("重新读取特征", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoading)
        } header: {
            Text("设备特征")
        } footer: {
            if let message = viewModel.message {
                Text(message).foregroundStyle(.orange)
            }
        }
    }

    // MARK: - 卡片

    @ViewBuilder
    private func card(_ reading: TraitReading, endpoint: EndpointTraitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(reading.trait.title, systemImage: reading.trait.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(reading.text)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)

            if let capability = reading.trait.controlCapability,
               let controlSnapshot = viewModel.controlSnapshot(for: endpoint.endpointID) {
                Divider()
                control(capability, controlSnapshot)
            }
        }
        // 撑满网格行高：同行的读数卡片背景等高、内容统一贴顶，避免一行高一行矮显得参差。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 卡片内嵌控件：复用 `DeviceControlViewModel` 的草稿 / 进行中 / 失败回滚逻辑。
    @ViewBuilder
    private func control(_ capability: ControlCapability, _ snapshot: EndpointControlSnapshot) -> some View {
        let endpointID = snapshot.endpointID
        switch capability {
        case .onOff:
            Toggle("开关", isOn: Binding(
                get: { viewModel.control.onOffDraft[endpointID] ?? snapshot.isOn ?? false },
                set: { viewModel.control.toggleOnOff(nodeID: nodeID, endpointID: endpointID, isOn: $0) }
            ))
            .labelsHidden()
            .disabled(viewModel.control.isPending(.onOff, endpointID))

        case .brightness:
            slider(
                value: viewModel.control.brightnessDraft[endpointID] ?? snapshot.brightnessPercent ?? 0,
                range: 0...100,
                isPending: viewModel.control.isPending(.brightness, endpointID),
                set: { viewModel.control.brightnessDraft[endpointID] = $0 },
                commit: {
                    viewModel.control.setBrightness(
                        nodeID: nodeID, endpointID: endpointID,
                        percent: viewModel.control.brightnessDraft[endpointID] ?? 0
                    )
                }
            )

        case .colorTemperature:
            let range = snapshot.miredsRange
            slider(
                value: viewModel.control.miredsDraft[endpointID] ?? snapshot.colorTemperatureMireds ?? range.lowerBound,
                range: range,
                isPending: viewModel.control.isPending(.colorTemperature, endpointID),
                set: { viewModel.control.miredsDraft[endpointID] = $0 },
                commit: {
                    viewModel.control.setColorTemperature(
                        nodeID: nodeID, endpointID: endpointID,
                        mireds: viewModel.control.miredsDraft[endpointID] ?? range.lowerBound
                    )
                }
            )

        case .windowCovering:
            slider(
                value: viewModel.control.liftDraft[endpointID] ?? snapshot.liftPercent ?? 0,
                range: 0...100,
                isPending: viewModel.control.isPending(.windowCovering, endpointID),
                set: { viewModel.control.liftDraft[endpointID] = $0 },
                commit: {
                    viewModel.control.setLift(
                        nodeID: nodeID, endpointID: endpointID,
                        percent: viewModel.control.liftDraft[endpointID] ?? 0
                    )
                }
            )

        case .identify:
            Button {
                viewModel.control.identify(nodeID: nodeID, endpointID: endpointID)
            } label: {
                Label("识别闪烁", systemImage: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(viewModel.control.isPending(.identify, endpointID))
        }
    }

    private func slider(
        value: Double,
        range: ClosedRange<Double>,
        isPending: Bool,
        set: @escaping (Double) -> Void,
        commit: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(get: { value }, set: set),
                in: range,
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    commit()
                }
            )
            if isPending {
                ProgressView().controlSize(.mini)
            }
        }
        .disabled(isPending)
    }
}