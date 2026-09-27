import SwiftUI
import UniformTypeIdentifiers

/// PAA 证书管理：导入自定义 PAA（DER / PEM），随控制器工厂启动作为附加信任来源加载。
struct PAAManagementView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var isImporting = false

    var body: some View {
        List {
            Section {
                if viewModel.paaItems.isEmpty {
                    Text("未加载自定义 PAA 证书，使用系统默认 PAA 信任列表。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.paaItems) { item in
                        PAARow(item: item)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            viewModel.deletePAA(id: viewModel.paaItems[index].id)
                        }
                    }
                }
            } header: {
                Text("自定义 PAA（\(viewModel.paaItems.count)）")
            } footer: {
                Text("用于验证测试设备 / 非认证设备的 attestation 证书链。新增或删除后需重启 App，随控制器工厂参数生效。")
            }

            Section {
                Button {
                    isImporting = true
                } label: {
                    Label("导入证书（.der / .pem）", systemImage: "square.and.arrow.down")
                }
            }

            if let notice = viewModel.notice {
                Section("结果") {
                    HStack(alignment: .top, spacing: 8) {
                        Text(notice)
                            .font(.callout)
                        Spacer(minLength: 0)
                        Button("知道了") { viewModel.notice = nil }
                            .font(.callout)
                            .buttonStyle(.plain)
                            .foregroundStyle(.tint)
                    }
                }
            }

            if let message = viewModel.paaErrorMessage {
                Section("错误") {
                    Text(message).foregroundStyle(.red)
                }
            }
        }
        .secondaryPageTitle("PAA 证书管理")
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.x509Certificate, .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.importPAA(from: url)
            case .failure(let error):
                viewModel.paaErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct PAARow: View {
    let item: PAAStore.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.fileName)
                .font(.callout)
            Text("\(item.byteCount) 字节 · \(item.addedAt.formatted(date: .numeric, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("SHA-256: " + String(item.id.prefix(32)) + "…")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        PAAManagementView(viewModel: SettingsViewModel())
    }
}