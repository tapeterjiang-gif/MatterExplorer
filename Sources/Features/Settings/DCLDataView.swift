import SwiftUI

/// DCL 数据：查看 CSA 分布式合规账本三张全量表的本地缓存状态，并手动更新。
///
/// 数据缓存在 `Library/DCLData/`，随包 JSON 为初始快照与兜底；
/// 更新逐表提交（按表原子），失败或取消时未改动的表保持原数据。
struct DCLDataView: View {
    @Bindable var viewModel: SettingsViewModel
    @State private var showRestoreConfirm = false

    var body: some View {
        List {
            statusSection
            actionSection
            noticeSections
            storageSection
        }
        .secondaryPageTitle("DCL 数据")
        .task { viewModel.refresh() }
        .alert("恢复为随包数据？", isPresented: $showRestoreConfirm) {
            Button("取消", role: .cancel) {}
            Button("恢复", role: .destructive) {
                viewModel.restoreBundledDCL()
            }
        } message: {
            Text("将删除本地缓存的 DCL 数据，改回 App 内置的初始快照。下次更新前，新认证的型号将查不到。")
        }
    }

    // MARK: - 状态

    private var statusSection: some View {
        Section {
            LabeledContent("数据来源", value: sourceText)
            if let updatedAt = viewModel.dclSnapshot?.updatedAt {
                LabeledContent("更新时间", value: updatedAt.formatted(date: .numeric, time: .standard))
            }
            ForEach(DCLTable.allCases, id: \.self) { table in
                LabeledContent(table.label, value: tableText(table))
            }
        } header: {
            Text("状态")
        } footer: {
            Text("数据来自 CSA 分布式合规账本（DCL）的公开只读接口，用于把设备的 VID / PID 翻译成厂商名与产品名。更新后立即生效，无需重启。")
        }
    }

    private var sourceText: String {
        switch viewModel.dclSnapshot?.source {
        case .cache: "已下载缓存"
        case .partialCache: "部分表已更新（其余为随包数据）"
        case .bundledAfterUpgrade: "缓存已过期（随包数据生效）"
        case .bundled, .none: "随包快照"
        }
    }

    private func tableText(_ table: DCLTable) -> String {
        guard let info = viewModel.dclSnapshot?.tables[table] else { return "-" }
        return "\(info.entryCount) 条 · \(info.byteCount.byteText)"
    }

    // MARK: - 操作

    private var actionSection: some View {
        Section {
            if viewModel.isDCLUpdating {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                    Text(viewModel.dclProgress?.text ?? "正在准备更新…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                Button(role: .destructive) {
                    viewModel.cancelDCLUpdate()
                } label: {
                    Label("取消更新", systemImage: "xmark.circle")
                }
            } else {
                Button {
                    viewModel.startDCLUpdate()
                } label: {
                    Label("立即更新", systemImage: "arrow.down.circle")
                }
            }

            Button(role: .destructive) {
                showRestoreConfirm = true
            } label: {
                Label("恢复为随包数据", systemImage: "arrow.counterclockwise")
            }
            .disabled(viewModel.isDCLUpdating)
        } header: {
            Text("操作")
        } footer: {
            Text("三张表依次下载，全部下载完成后逐表写入；某张表下载失败时该表保持原有数据。请保持网络连接，不要锁屏。")
        }
    }

    // MARK: - 结果与错误

    @ViewBuilder
    private var noticeSections: some View {
        if let notice = viewModel.dclNotice {
            Section("结果") {
                HStack(alignment: .top, spacing: 8) {
                    Text(notice)
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("知道了") { viewModel.dclNotice = nil }
                        .font(.callout)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
        }

        if let message = viewModel.dclErrorMessage {
            Section("错误") {
                Text(message).foregroundStyle(.red)
            }
        }
    }

    // MARK: - 存储

    private var storageSection: some View {
        Section {
            LabeledContent("随包构建号", value: viewModel.dclBundleVersionText)
            VStack(alignment: .leading, spacing: 3) {
                Text("缓存目录")
                    .font(.callout)
                Text(DCLCatalogStore.shared.directoryPath)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("存储")
        } footer: {
            Text("App 升级后（构建号变化）旧缓存自动失效，改用随包快照，需重新更新。")
        }
    }
}

#Preview {
    NavigationStack {
        DCLDataView(viewModel: SettingsViewModel())
    }
}