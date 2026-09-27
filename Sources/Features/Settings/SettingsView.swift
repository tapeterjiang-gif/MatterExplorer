import SwiftUI

/// 设置模块：fabric / controller 状态、日志级别、PAA 管理、错误码词典、重置、关于。
struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var showResetConfirm = false
    @State private var resetSummary: String?

    var body: some View {
        NavigationStack {
            List {
                controllerSection
                networkSection
                logSection
                dclSection
                developerSection
                aboutSection
            }
            .rootPageTitle("设置")
            .refreshable { viewModel.refresh() }
            .task { viewModel.refresh() }
            .alert("确认重置本机 Matter 状态？", isPresented: $showResetConfirm) {
                Button("取消", role: .cancel) {}
                Button("重置", role: .destructive) {
                    resetSummary = viewModel.reset()
                }
            } message: {
                // 作用域说明只出现在这里：用户读到它的时机正是需要判断的那一刻，不必在列表里常驻。
                Text("将清除控制器这条链上的数据：MatterStore、IPK、根密钥对与设备注册表。不会向设备下发指令，也不影响 DCL / OTA / PAA 缓存与日志；重置后需重启 App 生效。如需让设备退网，请在设备详情中使用「设备管理 → RemoveFabric」。此操作不可撤销。")
            }
        }
    }

    // MARK: - 控制器

    /// 控制器状态摘要（唯一位置）；节点 ID、存储目录与 fabric 明细收在「控制器诊断」子页（下拉可刷新状态）。
    /// 「重置」并入本分区：它清空的就是控制器这条链上的状态（MatterStore / IPK / 根密钥对 / 设备注册表），
    /// 与 DCL、OTA、PAA、日志缓存无关——单独成区容易被读成「清空 App 数据」。
    /// 重置的作用域说明只放在确认弹窗里（见 `body` 的 alert）：那是用户需要判断的时机，不必在列表里常驻。
    private var controllerSection: some View {
        Section {
            LabeledContent("控制器工厂", value: viewModel.status.isFactoryRunning ? "运行中" : "未启动")
            LabeledContent("控制器", value: viewModel.status.isControllerReady ? "就绪" : "未初始化")
            LabeledContent("已配网设备", value: "\(viewModel.status.commissionedDeviceCount)")
            NavigationLink {
                ControllerDiagnosticsView(viewModel: viewModel)
            } label: {
                LabeledContent("控制器诊断", value: "\(viewModel.status.fabrics.count) 个 fabric")
            }
            Button(role: .destructive) {
                showResetConfirm = true
            } label: {
                Label("重置本机 Matter 状态", systemImage: "arrow.counterclockwise")
            }
            if let resetSummary {
                VStack(alignment: .leading, spacing: 6) {
                    Text("重置完成（重启 App 后生效）")
                        .font(.callout.weight(.semibold))
                    Text(resetSummary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("控制器")
        } footer: {
            Text(viewModel.status.isControllerReady
                 ? "控制器已就绪，可执行配网与集群操作。"
                 : "控制器尚未就绪；若持续未就绪请查看日志。")
        }
    }

    // MARK: - 网络

    /// 承载网络相关：目前只有 Thread（系统凭证读取，用于配网与排查）。
    private var networkSection: some View {
        Section {
            NavigationLink {
                ThreadNetworkView()
            } label: {
                Label("Thread 网络", systemImage: "point.3.connected.trianglepath.dotted")
            }
        } header: {
            Text("网络")
        } footer: {
            // 只在不支持时给降级结论：真机缺 entitlement 时同样读不到，写「可用」是假承诺。
            Text(ThreadCapability.isSupported
                 ? "Thread 网络凭证来自系统已保存的网络（仅当前 Team ID 保存的网络），用于 Thread 设备配网与排查。"
                 : ThreadCapability.unavailableMessage)
        }
    }

    // MARK: - 日志

    private var logSection: some View {
        Section {
            Picker("最低收录级别", selection: minimumLevelBinding) {
                ForEach(MatterEvent.Level.allCases, id: \.self) { level in
                    Text(level.rawValue.uppercased()).tag(level)
                }
            }
            Picker("Matter 栈日志", selection: stackThresholdBinding) {
                ForEach(MatterStackLogBridge.Threshold.allCases) { threshold in
                    Text(threshold.label).tag(threshold)
                }
            }
            Button(role: .destructive) {
                viewModel.clearLogs()
            } label: {
                Label("清空日志", systemImage: "trash")
            }
        } header: {
            Text("日志")
        } footer: {
            Text("最低收录级别：低于该级别的事件不进入日志缓冲，只作用于此后产生的事件。默认「INFO」；「DEBUG」含高频的订阅属性报告与在线状态变化，量很大、可能影响性能。Matter 栈日志：转发 Matter.framework 内部日志，「全部（含详情）」级量最大。两项均立即生效，无需重启。清空日志仅移除内存中的日志缓冲，已导出的文件不受影响。")
        }
    }

    private var minimumLevelBinding: Binding<MatterEvent.Level> {
        Binding(
            get: { viewModel.minimumLevel },
            set: { viewModel.applyMinimumLevel($0) }
        )
    }

    private var stackThresholdBinding: Binding<MatterStackLogBridge.Threshold> {
        Binding(
            get: { viewModel.stackLogThreshold },
            set: { viewModel.applyStackLogThreshold($0) }
        )
    }

    // MARK: - DCL 数据

    /// CSA DCL 参考数据（厂商表 / 产品表 / 认证表）的本地缓存与手动更新入口。
    private var dclSection: some View {
        Section {
            NavigationLink {
                DCLDataView(viewModel: viewModel)
            } label: {
                LabeledContent("DCL 数据", value: viewModel.dclSummaryText)
            }
            LabeledContent("缓存占用", value: viewModel.cacheUsageText)
        } header: {
            Text("参考数据")
        } footer: {
            Text("厂商与产品名称来自 CSA 分布式合规账本（DCL）。可在此手动更新到最新版本，无需等待 App 升级。缓存占用为 DCL 数据、OTA 镜像库与 PAA 证书三个目录的合计；不做自动淘汰，可在各自页面删除。")
        }
    }

    // MARK: - 开发者选项

    private var developerSection: some View {
        Section("开发者选项") {
            NavigationLink {
                PAAManagementView(viewModel: viewModel)
            } label: {
                LabeledContent("PAA 证书管理", value: "\(viewModel.paaItems.count)")
            }
            NavigationLink {
                ErrorDictionaryView()
            } label: {
                Text("Matter 错误码词典")
            }
        }
    }

    // MARK: - 关于

    private var aboutSection: some View {
        Section("关于") {
            LabeledContent("版本", value: viewModel.versionText)
            LabeledContent("最低系统", value: "iOS 27.0")
        }
    }
}

#Preview {
    SettingsView()
}