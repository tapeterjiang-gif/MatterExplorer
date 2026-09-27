import SwiftUI

/// 可交互控件（开关 / 识别闪烁 / 亮度 / 色温 / 开合位置）。
/// 从「设备控制」页提取，供控制页与设备详情页「设备特征」卡片共用同一份逻辑。
struct TraitControlWidget: View {
    let nodeID: UInt64
    let capability: ControlCapability
    let snapshot: EndpointControlSnapshot
    @Bindable var viewModel: DeviceControlViewModel

    var body: some View {
        switch capability {
        case .onOff:
            onOffControl
        case .identify:
            identifyControl
        case .brightness:
            brightnessControl
        case .colorTemperature:
            colorTemperatureControl
        case .windowCovering:
            liftControl
        }
    }

    // MARK: - 控件

    private var onOffControl: some View {
        let endpointID = snapshot.endpointID
        let isOn = viewModel.onOffDraft[endpointID] ?? snapshot.isOn ?? false
        return Toggle(isOn: Binding(
            get: { isOn },
            set: { viewModel.toggleOnOff(nodeID: nodeID, endpointID: endpointID, isOn: $0) }
        )) {
            HStack {
                Label(capability.title, systemImage: capability.systemImage)
                if viewModel.isPending(.onOff, endpointID) {
                    ProgressView().controlSize(.mini)
                }
            }
        }
        .disabled(viewModel.isPending(.onOff, endpointID))
    }

    private var identifyControl: some View {
        let endpointID = snapshot.endpointID
        return Group {
            HStack {
                Label(capability.title, systemImage: capability.systemImage)
                Spacer()
                Stepper(
                    "\(viewModel.identifySeconds) 秒",
                    value: Binding(
                        get: { viewModel.identifySeconds },
                        set: { viewModel.identifySeconds = $0 }
                    ),
                    in: 1...60
                )
                .fixedSize()
            }
            Button {
                viewModel.identify(nodeID: nodeID, endpointID: endpointID)
            } label: {
                HStack {
                    Label("开始识别", systemImage: "play.circle")
                    if viewModel.isPending(.identify, endpointID) {
                        Spacer()
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .disabled(viewModel.isPending(.identify, endpointID))
        }
    }

    private var brightnessControl: some View {
        let endpointID = snapshot.endpointID
        let percent = viewModel.brightnessDraft[endpointID] ?? snapshot.brightnessPercent ?? 0
        let range = snapshot.levelRange
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(capability.title, systemImage: capability.systemImage)
                Spacer()
                if viewModel.isPending(.brightness, endpointID) {
                    ProgressView().controlSize(.mini)
                }
                Text("\(Int(percent.rounded()))% · 等级 \(DeviceControlCatalog.level(fromPercent: percent))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { percent },
                    set: { viewModel.brightnessDraft[endpointID] = $0 }
                ),
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    viewModel.setBrightness(
                        nodeID: nodeID, endpointID: endpointID,
                        percent: viewModel.brightnessDraft[endpointID] ?? percent
                    )
                }
            )
            .disabled(viewModel.isPending(.brightness, endpointID))
            Text("设备等级范围 \(Int(range.lowerBound))–\(Int(range.upperBound))（0–254 规范值）")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var colorTemperatureControl: some View {
        let endpointID = snapshot.endpointID
        let range = snapshot.miredsRange
        let mireds = viewModel.miredsDraft[endpointID] ?? snapshot.colorTemperatureMireds ?? range.lowerBound
        let kelvin = DeviceControlCatalog.kelvin(fromMireds: mireds).map { "\($0) K" } ?? "—"
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(capability.title, systemImage: capability.systemImage)
                Spacer()
                if viewModel.isPending(.colorTemperature, endpointID) {
                    ProgressView().controlSize(.mini)
                }
                Text("\(Int(mireds.rounded())) mireds · \(kelvin)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { mireds },
                    set: { viewModel.miredsDraft[endpointID] = $0 }
                ),
                in: range,
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    viewModel.setColorTemperature(
                        nodeID: nodeID, endpointID: endpointID,
                        mireds: viewModel.miredsDraft[endpointID] ?? mireds
                    )
                }
            )
            .disabled(viewModel.isPending(.colorTemperature, endpointID))
            HStack {
                Text("暖（\(Int(range.lowerBound))）").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("冷（\(Int(range.upperBound))）").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var liftControl: some View {
        let endpointID = snapshot.endpointID
        let percent = viewModel.liftDraft[endpointID] ?? snapshot.liftPercent ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(capability.title, systemImage: capability.systemImage)
                Spacer()
                if viewModel.isPending(.windowCovering, endpointID) {
                    ProgressView().controlSize(.mini)
                }
                Text("\(Int(percent.rounded()))%")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { percent },
                    set: { viewModel.liftDraft[endpointID] = $0 }
                ),
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    guard !editing else { return }
                    viewModel.setLift(
                        nodeID: nodeID, endpointID: endpointID,
                        percent: viewModel.liftDraft[endpointID] ?? percent
                    )
                }
            )
            .disabled(viewModel.isPending(.windowCovering, endpointID))
            if let status = snapshot.coveringStatusText {
                Text("OperationalStatus \(status)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}