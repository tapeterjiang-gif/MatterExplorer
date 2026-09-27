import SwiftUI
import UniformTypeIdentifiers

/// 设备模块：已配网设备列表（在线状态）+ 设备详情。
struct DevicesView: View {
    @State private var viewModel = DevicesViewModel()
    @State private var path = NavigationPath()
    /// 配网页呈现状态（右上角按钮打开）。
    @State private var isPresentingCommission = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationDestination(for: DeviceRoute.self) { route in
                    switch route {
                    case .detail(let nodeID):
                        DeviceDetailView(viewModel: viewModel, nodeID: nodeID)
                    case .control(let nodeID):
                        DeviceControlView(
                            nodeID: nodeID,
                            deviceName: viewModel.record(for: nodeID)?.displayName ?? "节点 \(nodeID)"
                        )
                    case .admin(let nodeID):
                        DeviceAdminView(
                            nodeID: nodeID,
                            deviceName: viewModel.record(for: nodeID)?.displayName ?? "节点 \(nodeID)"
                        )
                    case .clusterIO(let nodeID):
                        ClusterIOView(
                            nodeID: nodeID,
                            deviceName: viewModel.record(for: nodeID)?.displayName ?? "节点 \(nodeID)"
                        )
                    }
                }
                .rootPageTitle("设备")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            isPresentingCommission = true
                        } label: {
                            // 仅图标：文字 + 图标的 Label 在工具栏会撑出一枚较长的玻璃胶囊，视觉偏重。
                            Image(systemName: "plus.circle")
                        }
                        .accessibilityLabel("打开配网")
                    }
                }
                .sheet(isPresented: $isPresentingCommission) {
                    CommissionView()
                }
                .onAppear {
                    viewModel.reload()
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.devices.isEmpty && viewModel.message == nil {
            ContentUnavailableView(
                "暂无设备",
                systemImage: "rectangle.grid.2x2",
                description: Text("已配网设备将显示在这里。\n点右上角「配网」按钮，扫描附近的待配网设备完成配网。")
            )
        } else {
            deviceList
        }
    }

    private var deviceList: some View {
        List {
            Section {
                if viewModel.devices.isEmpty {
                    Text("暂无设备。点右上角「配网」按钮完成配网。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(viewModel.devices) { record in
                    NavigationLink(value: DeviceRoute.detail(record.nodeID)) {
                        DeviceRow(
                            record: record,
                            status: viewModel.status(for: record.nodeID),
                            summary: viewModel.traitSummary(for: record.nodeID)
                        )
                    }
                }
            }

            if let message = viewModel.message {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

// MARK: - 列表行

private struct DeviceRow: View {
    let record: DeviceRecord
    let status: DeviceReachability
    /// 关键读数摘要（无缓存时为空，此时不显示占位以免闪烁）。
    let summary: [TraitReading]

    /// List 为 NavigationLink 的进入箭头预留的尾部宽度；右列回填该宽度后与箭头右边缘对齐。
    private static let accessoryAllowance: CGFloat = 10

    /// 读数行可额外借用的尾部宽度。读数靠左排布、离箭头尚有余量，而 `ViewThatFits` 的测量宽度
    /// 比实际可用宽度窄十余点：不补这段宽度，4 项读数会被判定放不下或末项被截断。
    private static let readingAllowance: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // 第一行：设备名称 + 右上角网络类型图标与在线状态
            HStack(spacing: 8) {
                Text(record.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
                statusCluster
                    .padding(.trailing, -Self.accessoryAllowance)
            }
            // 第二行：设备内容（读数，靠左）
            if !summary.isEmpty {
                ViewThatFits(in: .horizontal) {
                    // 4 项时收紧间距：4 项约等于行内可用宽度，用 12pt 间距会被判定放不下而回退成 3 项，
                    // 用 10pt 则虽被选中但末项文字被截断（List 行实际可用宽度比测量值窄十余点）。
                    summaryValues(count: 4, spacing: 8)
                    summaryValues(count: 3)
                    summaryValues(count: 2)
                    summaryValues(count: 1)
                }
                .padding(.trailing, -Self.readingAllowance)
            }
            // 第三行：左侧厂商，右侧端点信息
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let identity = record.catalogIdentityText {
                    Text(identity)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let endpointCount = record.endpointCount {
                    Text("端点 \(endpointCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.trailing, -Self.accessoryAllowance)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// 网络类型图标 + 在线状态圆点；状态以颜色区分，文本作为无障碍标签。
    private var statusCluster: some View {
        HStack(spacing: 5) {
            Image(systemName: record.networkKind.systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Circle()
                .fill(status.tint)
                .frame(width: 7, height: 7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(record.networkKind.label)，\(status.label)")
    }

    /// 读数：图标着色 + 数值加重，扁平排布（无背景容器），靠间距与字号形成层次。
    private func summaryValues(count: Int, spacing: CGFloat = 12) -> some View {
        HStack(spacing: spacing) {
            ForEach(Array(summary.prefix(count))) { reading in
                HStack(spacing: 4) {
                    Image(systemName: reading.trait.systemImage)
                        .font(.caption)
                        .foregroundStyle(reading.trait.tint)
                    Text(reading.text)
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                }
                .lineLimit(1)
            }
        }
    }
}

private extension DeviceReachability {
    /// 在线状态圆点颜色。
    var tint: Color {
        switch self {
        case .reachable: .green
        case .unreachable: .red
        case .unknown: .secondary
        }
    }
}

private extension DeviceTrait {
    /// 列表读数图标着色。
    var tint: Color {
        switch self {
        case .temperature: .orange
        case .humidity: .blue
        case .pm25: .green
        case .co2: .teal
        case .airQuality: .mint
        case .illuminance: .yellow
        case .occupancy: .indigo
        case .booleanState: .gray
        case .onOff: .orange
        case .brightness: .yellow
        case .colorTemperature: .pink
        case .windowCovering: .brown
        }
    }
}

// MARK: - 设备详情

private struct DeviceDetailView: View {
    @Bindable var viewModel: DevicesViewModel
    let nodeID: UInt64

    @State private var traitViewModel = DeviceTraitViewModel()
    /// OTA 镜像导入与下发确认状态。
    @State private var isImportingOTAImage = false
    @State private var isConfirmingOTAUpdate = false

    var body: some View {
        List {
            toolEntrySection
            DeviceTraitSection(nodeID: nodeID, viewModel: traitViewModel)
            identitySection
            basicInfoSection
            batterySection
            otaSection
            otaImageSection
            networkSection
            topologySection
            removalSection
        }
        .secondaryPageTitle(viewModel.record(for: nodeID)?.displayName ?? "节点 \(nodeID)")
        .task {
            viewModel.clearMessage()
            viewModel.loadDetail(nodeID: nodeID)
        }
        // 推入「设备控制」「集群工具」页会触发本页 onDisappear、返回时 onAppear，
        // 而 onDisappear 会取消订阅，故电池订阅必须与设备特征一样由 onAppear 重建
        // （放在 .task 里只会在首次出现时建立，返回本页后电池就再也不更新）。
        .onAppear {
            traitViewModel.activate(nodeID: nodeID)
            viewModel.loadBatteryStatus(nodeID: nodeID)
        }
        .onDisappear {
            traitViewModel.stopSubscription()
            viewModel.stopBatteryStatus()
        }
        .alert("操作失败", isPresented: Binding(
            get: { traitViewModel.controlFailure != nil },
            set: { if !$0 { traitViewModel.clearControlFailure() } }
        )) {
            Button("好", role: .cancel) { traitViewModel.clearControlFailure() }
        } message: {
            Text(traitViewModel.controlFailure ?? "")
        }
        .fileImporter(
            isPresented: $isImportingOTAImage,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                viewModel.importOTAImage(from: url)
            case .failure(let error):
                viewModel.otaActionMessage = "选择文件失败：\(error.localizedDescription)"
            }
        }
        .confirmationDialog("确认向设备下发 OTA 更新？", isPresented: $isConfirmingOTAUpdate, titleVisibility: .visible) {
            Button("下发") { viewModel.announceOTAUpdate(nodeID: nodeID) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("设备将下载并安装新固件，过程中可能短暂离线。")
        }
    }

    // MARK: 设备工具入口

    private var toolEntrySection: some View {
        Section {
            NavigationLink(value: DeviceRoute.control(nodeID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("完整控制面板", systemImage: "slider.horizontal.3")
                    Text("含识别闪烁、状态原始值与命令结果，供逐个端点核对；上方「设备特征」卡片已覆盖常用操作")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink(value: DeviceRoute.admin(nodeID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("设备管理", systemImage: "wrench.and.screwdriver")
                    Text("fabric 归属与移除、NodeLabel / Location 写入、网络凭证增删连")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            NavigationLink(value: DeviceRoute.clusterIO(nodeID)) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("集群工具", systemImage: "square.stack.3d.up")
                    Text("端点 / 集群 / 属性浏览，读 / 写 / 命令调用与订阅实时报告")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("设备工具")
        } footer: {
            Text("需要设备在线；控件按各端点 ServerList 中的可控集群生成。设备管理含破坏性操作（RemoveFabric），执行前会二次确认。")
        }
    }

    // MARK: 本地记录

    private var identitySection: some View {
        Section {
            row("nodeID", "\(nodeID)")
            row("在线状态", viewModel.status(for: nodeID).label)
            row("网络类型", viewModel.record(for: nodeID)?.networkKind.label ?? "未知")
            row("VID / PID", viewModel.record(for: nodeID)?.vendorProductText ?? "未知")
            row("配网时间", viewModel.record(for: nodeID)?.commissionedAt.formatted(date: .numeric, time: .shortened) ?? "—")
            HStack {
                TextField("设备名称", text: $viewModel.renameText)
                Button("保存") { viewModel.saveRename(nodeID: nodeID) }
                    .buttonStyle(.borderless)
            }
        } header: {
            Text("设备记录（本地）")
        } footer: {
            Text("名称仅保存在本机注册表；写入设备端的 NodeLabel 属性请使用「设备管理」。")
        }
    }

    // MARK: 基本信息

    private var basicInfoSection: some View {
        Section {
            if viewModel.isLoadingBasicInfo {
                HStack { ProgressView(); Text("正在读取 Basic Information…") }
            } else if let info = viewModel.basicInfo {
                row("厂商名称", info.vendorName)
                row("Vendor ID", info.vendorID.map { MatterHex.hex($0, width: 4) })
                row("产品名称", info.productName)
                row("Product ID", info.productID.map { MatterHex.hex($0, width: 4) })
                row("NodeLabel", info.nodeLabel)
                row("硬件版本", info.hardwareVersionString ?? info.hardwareVersion.map(String.init))
                row("软件版本", info.softwareVersionString ?? info.softwareVersion.map(String.init))
                row("序列号", info.serialNumber)
                row("UniqueID", info.uniqueID)
                row("数据模型版本", info.dataModelRevision.map(String.init))
            } else {
                Text("尚未读取。点击下方按钮从端点 0 / 集群 0x28 读取。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.loadBasicInfo(nodeID: nodeID)
            } label: {
                Label("读取基本信息", systemImage: "arrow.down.circle")
            }
            .disabled(viewModel.isLoadingBasicInfo)
        } header: {
            Text("设备信息（Basic Information 0x28）")
        } footer: {
            if let message = viewModel.detailMessage {
                Text(message).foregroundStyle(.orange)
            }
        }
    }

    // MARK: 电池 / 电源（只读）

    /// 只读诊断：各电源端点的 Power Source（0x2F）属性；只显示设备实际上报的字段。
    private var batterySection: some View {
        Section {
            if viewModel.isLoadingBattery {
                HStack { ProgressView(); Text("正在订阅电源 / 电池状态…") }
            } else if let status = viewModel.batteryStatus {
                if status.sources.isEmpty {
                    Text("设备未报告电源信息（可能为纯有线供电，或订阅的首次报告尚未到达）。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(status.sources) { source in
                    batteryRows(source: source, showEndpoint: status.sources.count > 1)
                }
                ForEach(status.notices, id: \.self) { notice in
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else if viewModel.isBatterySubscribed {
                // 订阅已建立但零报告：不能显示成「尚未订阅」，否则真实原因（订阅未生效 / 设备未上报 0x2F）被掩盖。
                Text("订阅已建立，但未收到 Power Source（0x2F）报告（本次订阅共收到 \(viewModel.batteryReportCount) 条属性报告）。若计数一直为 0，说明订阅未生效；若计数持续增长，说明设备未上报该集群。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("尚未订阅。数值来自 Power Source（0x2F）的订阅报告。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.loadBatteryStatus(nodeID: nodeID)
            } label: {
                Label("刷新电池状态（重新订阅）", systemImage: "arrow.clockwise")
            }
            .disabled(viewModel.isLoadingBattery)
        } header: {
            Text("电池 / 电源（Power Source 0x2F）")
        } footer: {
            Text("数值来自 Power Source（0x2F）的订阅报告（端点用通配——电源常挂在独立端点）：首次报告一次带回全部已实现属性，电量 / 充电状态变化会继续推送。电量规范单位为半个百分点（0–200），此处已换算为百分比。")
        }
    }

    /// 单个电源端点的属性行。
    @ViewBuilder
    private func batteryRows(source: DeviceBatteryStatus.Source, showEndpoint: Bool) -> some View {
        if showEndpoint {
            Text("端点 \(source.endpointID)\(source.isBattery ? "" : "（非电池电源）")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if !source.hasDetails {
            Text("该端点未上报电池属性。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        rowIfPresent("电源状态", source.powerSourceStatusLabel)
        rowIfPresent("电源描述", source.description)
        rowIfPresent("电池存在", source.present.map { $0 ? "是" : "否" })
        rowIfPresent("电量", source.percentText)
        rowIfPresent("电池状态", source.chargeLevelLabel)
        rowIfPresent("电压", source.voltageMilliVolts.map { "\($0) mV" })
        rowIfPresent("充电状态", source.chargeStateLabel)
        rowIfPresent("剩余时间", source.timeRemainingSeconds.map(DeviceBatteryStatus.Source.durationText))
        rowIfPresent("充满剩余时间", source.timeToFullChargeSeconds.map(DeviceBatteryStatus.Source.durationText))
        rowIfPresent("充电电流", source.chargingCurrentMilliAmps.map { "\($0) mA" })
        rowIfPresent("电池容量", source.capacityMilliAmpHours.map { "\($0) mAh" })
        rowIfPresent("数量", source.quantity.map(String.init))
        rowIfPresent("充电时可用", source.functionalWhileCharging.map { $0 ? "是" : "否" })
        rowIfPresent("需更换", source.replacementNeeded.map { $0 ? "是" : "否" })
        rowIfPresent("可更换性", source.replaceabilityLabel)
        rowIfPresent("电池型号", source.replacementDescription)
        rowIfPresent("ANSI 型号", source.ansiDesignation)
        rowIfPresent("IEC 型号", source.iecDesignation)
        rowIfPresent("电池故障", source.batFaultLabels.isEmpty ? nil : source.batFaultLabels.joined(separator: "、"))
        rowIfPresent("充电故障", source.batChargeFaultLabels.isEmpty ? nil : source.batChargeFaultLabels.joined(separator: "、"))
    }

    // MARK: 软件更新（OTA，只读）

    /// 只读诊断：设备是否实现 OTA Requestor 及其更新状态；不涉及固件下发。
    private var otaSection: some View {
        Section {
            row("当前软件版本", viewModel.basicInfo?.softwareVersionString
                ?? viewModel.basicInfo?.softwareVersion.map(String.init))

            if viewModel.isLoadingOTA {
                HStack { ProgressView(); Text("正在读取 OTA 状态…") }
            } else if let status = viewModel.otaStatus {
                row("支持 OTA", status.supportsRequestor ? "是" : "否")
                if status.supportsRequestor {
                    row("可更新", status.updatePossible.map { $0 ? "是" : "否" })
                    row("更新状态", status.updateStateLabel)
                    row("更新进度", status.updateStateProgress.map { "\($0)%" })
                    row("默认 Provider", status.defaultProviderCount.map { "\($0) 个" })
                }
                ForEach(status.notices, id: \.self) { notice in
                    Text(notice)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                Text("尚未读取。点击下方按钮从端点 0 读取 Descriptor 与 OTA Requestor 集群。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                viewModel.loadOTAStatus(nodeID: nodeID)
            } label: {
                Label("读取 OTA 状态", systemImage: "arrow.down.circle")
            }
            .disabled(viewModel.isLoadingOTA)
        } header: {
            Text("软件更新（OTA）")
        } footer: {
            Text("「支持 OTA」由端点 0 的 Descriptor.ServerList 是否含 0x2A 判定；「默认 Provider」为设备已配置的 OTA Provider 数量。固件下发在下方「OTA 镜像库」。")
        }
    }

    // MARK: OTA 镜像库（本机作为 Provider）

    private var otaImageSection: some View {
        Section {
            if viewModel.otaImages.isEmpty {
                Text("未导入镜像。模拟器无法完成端到端下发，需真机 + 厂商提供的 .ota 文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.otaImages) { item in
                    OTAImageRow(item: item, isMatch: viewModel.isOTAMatch(item))
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        viewModel.deleteOTAImage(id: viewModel.otaImages[index].id)
                    }
                }
            }

            Button {
                isImportingOTAImage = true
            } label: {
                Label("导入 OTA 镜像（.ota）", systemImage: "square.and.arrow.down")
            }

            if let image = viewModel.availableOTAImage {
                Button {
                    isConfirmingOTAUpdate = true
                } label: {
                    Label("向本设备下发 \(image.softwareVersionString)", systemImage: "arrow.up.circle")
                }
                .disabled(viewModel.isAnnouncingOTA)
                if viewModel.isAnnouncingOTA {
                    HStack { ProgressView(); Text("正在通告设备…") }
                }
            } else if let vendorID = viewModel.basicInfo?.vendorID,
                      let productID = viewModel.basicInfo?.productID {
                Text("镜像库中没有面向本设备（VID \(MatterHex.hex(vendorID)) / PID \(MatterHex.hex(productID))）且版本高于当前固件的镜像。")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let message = viewModel.otaActionMessage {
                HStack(alignment: .top, spacing: 8) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("知道了") { viewModel.clearOTAActionMessage() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                }
            }
        } header: {
            Text("OTA 镜像库（本机 Provider）")
        } footer: {
            Text("下发流程：本机作为 OTA Provider 向设备发送 AnnounceOTAProvider，设备随后主动连回本机查询并下载镜像（BDX）。需保持 App 在前台，且设备与本机处于同一 Thread / IP 网络。左滑镜像可删除。")
        }
    }

    // MARK: 网络信息

    private var networkSection: some View {
        Section {
            if viewModel.isLoadingNetwork {
                HStack { ProgressView(); Text("正在读取网络诊断…") }
            } else if let summary = viewModel.networkSummary {
                if summary.interfaces.isEmpty {
                    Text("设备未报告网络接口。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(summary.interfaces) { interface in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(interface.name) · \(interface.typeLabel)")
                            Spacer()
                            Label(
                                interface.isOperational ? "可用" : "不可用",
                                systemImage: interface.isOperational ? "checkmark.circle" : "slash.circle"
                            )
                            .font(.caption)
                            .foregroundStyle(interface.isOperational ? .green : .secondary)
                        }
                        if let hardwareAddress = interface.hardwareAddress {
                            Text(hardwareAddress)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let name = summary.threadNetworkName {
                    row("Thread 网络名", name)
                    row("Thread 信道", summary.threadChannel.map(String.init))
                    row("Thread ExtendedPANID", summary.threadExtendedPANID)
                }
                if summary.wifiChannel != nil || summary.wifiBSSID != nil {
                    row("Wi-Fi 信道", summary.wifiChannel.map(String.init))
                    row("Wi-Fi BSSID", summary.wifiBSSID)
                    row("Wi-Fi RSSI", summary.wifiRSSI.map { "\($0) dBm" })
                }
                if !summary.notices.isEmpty {
                    Text(summary.notices.joined(separator: "\n"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("尚未读取。将依次读取 General Diagnostics（0x33）与 Thread / Wi-Fi 诊断。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                viewModel.loadNetworkInfo(nodeID: nodeID)
            } label: {
                Label("读取网络信息", systemImage: "antenna.radiowaves.left.and.right")
            }
            .disabled(viewModel.isLoadingNetwork)
        } header: {
            Text("网络信息")
        } footer: {
            Text("Wi-Fi 诊断不含 SSID（规范未定义该属性），仅提供 BSSID / 信道 / RSSI。")
        }
    }

    // MARK: 拓扑

    private var topologySection: some View {
        Section {
            row("端点数", viewModel.record(for: nodeID)?.endpointCount.map(String.init) ?? "\(viewModel.endpoints.count)")
            if !viewModel.endpoints.isEmpty {
                Text("端点列表：" + viewModel.endpoints.map(String.init).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("拓扑（Descriptor 0x1D）")
        } footer: {
            Text("端点 / 集群 / 属性的读写与订阅请在「集群工具」页进行。")
        }
    }

    // MARK: 移除

    private var removalSection: some View {
        Section {
            Button("从本地列表移除", role: .destructive) {
                viewModel.removeRecord(nodeID: nodeID)
            }
        } header: {
            Text("移除")
        } footer: {
            Text("iOS 27 的 MTRDeviceController 不提供移除设备的 API，此处仅删除本机记录。设备退网请在「集群工具」向 Operational Credentials（0x3E）发送 RemoveFabric 命令，或在设备端恢复出厂设置。")
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value?.isEmpty == false ? value! : "—")
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }

    /// 仅在该字段有值时渲染行（供电池等属性稀疏的分区使用）。
    @ViewBuilder
    private func rowIfPresent(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            row(label, value)
        }
    }
}

// MARK: - OTA 镜像行

private struct OTAImageRow: View {
    let item: OTAImageStore.Item
    /// 头部 VID / PID 是否面向当前设备。
    let isMatch: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(item.fileName)
                    .font(.callout)
                    .lineLimit(1)
                if isMatch {
                    Label("匹配本设备", systemImage: "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(.green)
                }
            }
            Text("VID \(MatterHex.hex(item.vendorID, width: 4)) · PID \(MatterHex.hex(item.productID, width: 4)) · 版本 \(item.softwareVersionString)")
            .font(.caption)
            .foregroundStyle(.secondary)
            Text("载荷 \(item.payloadSize.byteText) · 文件 \(item.byteCount.byteText) · 导入 \(item.addedAt.formatted(date: .numeric, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    DevicesView()
}