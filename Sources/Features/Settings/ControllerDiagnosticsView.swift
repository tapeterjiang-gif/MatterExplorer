import SwiftUI

/// 控制器诊断子页：控制器节点 ID、Matter 存储目录与已识别 fabric 明细。
/// 这些长值（节点 ID、存储路径、根公钥）主要供排查问题时拷贝带走，故每项都带一键拷贝。
struct ControllerDiagnosticsView: View {
    let viewModel: SettingsViewModel

    var body: some View {
        List {
            controllerSection
            storageSection
            fabricSection
        }
        .secondaryPageTitle("控制器诊断")
        .refreshable { viewModel.refresh() }
    }

    // MARK: - 控制器

    private var controllerSection: some View {
        Section {
            if let nodeID = viewModel.status.controllerNodeID {
                copyRow("控制器节点 ID", value: "\(nodeID)", monospaced: true)
            } else {
                Text("控制器节点 ID 未知")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("控制器")
        } footer: {
            Text("节点 ID 为本机控制器在此 fabric 中的 operational node ID。")
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            if let path = viewModel.status.storagePath {
                copyRow("存储目录", value: path, monospaced: true)
            } else {
                Text("存储目录未知")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("存储")
        } footer: {
            Text("Matter 持久化数据（fabric、IPK、根密钥对）所在目录；「重置本机 Matter 状态」会清空其中内容。")
        }
    }

    // MARK: - 已识别 fabric

    private var fabricSection: some View {
        Section {
            if viewModel.status.fabrics.isEmpty {
                Text("尚未建立 fabric（首次配网成功后创建）")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.status.fabrics) { fabric in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Fabric 索引 \(fabric.fabricIndex)")
                                .font(.callout)
                            if fabric.hasRootCertificate {
                                Text("有根证书")
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(.quaternary.opacity(0.5), in: Capsule())
                            }
                            Spacer(minLength: 4)
                            CopyButton(value: copyText(fabric))
                        }
                        DetailLine("Fabric ID", MatterHex.hex(fabric.fabricID, width: 16))
                        DetailLine("Node ID", MatterHex.hex(fabric.nodeID, width: 16))
                        // 厂商名放在独立行：挤在标题行会被截断到只剩「VID 0xF…」，VID 值丢失。
                        DetailLine("厂商", fabric.vendorText)
                        DetailLine("根公钥", fabric.rootPublicKeyHex)
                        DetailLine("标签", fabric.label.isEmpty ? "（空）" : fabric.label)
                    }
                    .padding(.vertical, 3)
                }
            }
        } header: {
            Text("已识别 fabric（\(viewModel.status.fabrics.count)）")
        } footer: {
            Text("来源 MTRDeviceControllerFactory.knownFabrics，即本机控制器可操作的 fabric 集合。")
        }
    }

    // MARK: - 行

    /// 一行可拷贝的信息：标题、值、拷贝按钮。
    private func copyRow(_ title: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(monospaced ? 3 : nil)
                .truncationMode(.middle)
                .textSelection(.enabled)
            CopyButton(value: value)
        }
    }

    /// 单条 fabric 的完整字段文本（供一键拷贝）。
    private func copyText(_ fabric: MatterManager.Status.FabricEntry) -> String {
        var lines = [
            "Fabric 索引：\(fabric.fabricIndex)",
            "Fabric ID：\(MatterHex.hex(fabric.fabricID, width: 16))",
            "Node ID：\(MatterHex.hex(fabric.nodeID, width: 16))",
            "厂商：\(fabric.vendorText)",
            "根公钥：\(fabric.rootPublicKeyHex)",
            "标签：\(fabric.label.isEmpty ? "（空）" : fabric.label)",
        ]
        if fabric.hasRootCertificate { lines.append("根证书：已缓存") }
        return lines.joined(separator: "\n")
    }
}

#Preview {
    NavigationStack {
        ControllerDiagnosticsView(viewModel: SettingsViewModel())
    }
}