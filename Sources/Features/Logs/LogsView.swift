import SwiftUI

/// 日志模块：实时事件流（M1 起接入 LogStore）。
/// 采用 iOS 原生语汇：List 行 + 级别徽标 + 多维度筛选（级别 / 分类 / 节点，均可多选）。
struct LogsView: View {
    @State private var events: [MatterEvent] = []
    /// 筛选结果缓存：仅在事件到达 / 筛选变化时增量维护，避免每次 body 求值都全量过滤。
    @State private var filtered: [MatterEvent] = []
    @State private var selectedLevels: Set<MatterEvent.Level> = []
    @State private var selectedCategories: Set<MatterEvent.Category> = []
    @State private var selectedNodeIDs: Set<UInt64> = []
    @State private var autoScroll = true
    @State private var showFilters = false
    @State private var dictionaryEntry: MatterErrorDictionary.Entry?
    /// 已展开详情的日志行（仅带 detail 的行可展开）。
    @State private var expandedIDs: Set<UUID> = []

    /// 视图中保留的事件上限（与 LogStore 缓冲一致）：超出后丢弃最旧的，避免长时间运行时无限增长。
    private static let maxRendered = 2000

    /// 单条事件是否命中当前筛选条件。
    private func matchesFilter(_ event: MatterEvent) -> Bool {
        (selectedLevels.isEmpty || selectedLevels.contains(event.level))
            && (selectedCategories.isEmpty || selectedCategories.contains(event.category))
            && (selectedNodeIDs.isEmpty || event.nodeID.map(selectedNodeIDs.contains) == true)
    }

    /// 按当前筛选条件重建展示列表（筛选条件变化 / 清空时使用）。
    private func recomputeFiltered() {
        filtered = events.filter(matchesFilter)
    }

    /// 当前缓冲中出现过的节点（供筛选使用）。
    private var knownNodeIDs: [UInt64] {
        Array(Set(events.compactMap(\.nodeID))).sorted()
    }

    private var hasActiveFilter: Bool {
        !selectedLevels.isEmpty || !selectedCategories.isEmpty || !selectedNodeIDs.isEmpty
    }

    /// 活动筛选摘要（按枚举声明顺序、节点升序，便于扫读）。
    private var filterSummary: String {
        var parts: [String] = []
        if !selectedLevels.isEmpty {
            parts.append(MatterEvent.Level.allCases.filter(selectedLevels.contains).map(\.label).joined(separator: "/"))
        }
        if !selectedCategories.isEmpty {
            parts.append(
                MatterEvent.Category.allCases.filter(selectedCategories.contains).map(\.label).joined(separator: "/")
            )
        }
        if !selectedNodeIDs.isEmpty {
            parts.append(selectedNodeIDs.sorted().map { "节点 \($0)" }.joined(separator: "/"))
        }
        return parts.joined(separator: " · ")
    }

    private func clearFilters() {
        selectedLevels.removeAll()
        selectedCategories.removeAll()
        selectedNodeIDs.removeAll()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if hasActiveFilter {
                    activeFilterBar
                }
                if filtered.isEmpty {
                    emptyState
                } else {
                    eventList
                }
            }
            .rootPageTitle("日志")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    moreMenu
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showFilters = true
                    } label: {
                        Label(
                            "筛选",
                            systemImage: hasActiveFilter
                                ? "line.3.horizontal.decrease.circle.fill"
                                : "line.3.horizontal.decrease.circle"
                        )
                    }
                }
            }
            .sheet(isPresented: $showFilters) {
                LogFilterSheet(
                    levels: $selectedLevels,
                    categories: $selectedCategories,
                    nodeIDs: $selectedNodeIDs,
                    availableNodeIDs: knownNodeIDs
                )
            }
            .sheet(item: $dictionaryEntry) { entry in
                NavigationStack {
                    ErrorDictionaryView(highlighted: entry)
                }
            }
        }
        .task {
            for await event in LogStore.shared.eventStream() {
                events.append(event)
                if events.count > Self.maxRendered {
                    // 事件逐条追加，故一次最多淘汰一条；最旧的若在展示列表中必然位于队首。
                    let dropped = events.removeFirst()
                    if filtered.first?.id == dropped.id { filtered.removeFirst() }
                }
                if matchesFilter(event) { filtered.append(event) }
            }
        }
        .onChange(of: selectedLevels) { recomputeFiltered() }
        .onChange(of: selectedCategories) { recomputeFiltered() }
        .onChange(of: selectedNodeIDs) { recomputeFiltered() }
        // 清空可能来自本页或设置页；统一由通知驱动，避免两处各自维护本地数组。
        .onReceive(NotificationCenter.default.publisher(for: LogStore.didClearNotification)) { _ in
            events.removeAll()
            filtered.removeAll()
        }
    }

    // MARK: - 工具栏

    /// 导出（JSON / 纯文本）、自动滚动开关与清空日志。
    private var moreMenu: some View {
        Menu {
            ShareLink(
                "导出 JSON",
                item: LogExportJSON(events: filtered),
                preview: SharePreview("MatterExplorer 日志.json", image: Image(systemName: "doc.text"))
            )
            .disabled(filtered.isEmpty)
            ShareLink(
                "导出纯文本",
                item: LogExportText(events: filtered),
                preview: SharePreview("MatterExplorer 日志.txt", image: Image(systemName: "doc.plaintext"))
            )
            .disabled(filtered.isEmpty)
            Divider()
            Button {
                autoScroll.toggle()
            } label: {
                Label(
                    autoScroll ? "自动滚动：开" : "自动滚动：关",
                    systemImage: autoScroll ? "arrow.down.to.line" : "arrow.down.to.line.compact"
                )
            }
            Divider()
            Button(role: .destructive) {
                LogStore.shared.clear()
            } label: {
                Label("清空日志", systemImage: "trash")
            }
        } label: {
            Label("更多", systemImage: "ellipsis.circle")
        }
    }

    // MARK: - 列表

    private var eventList: some View {
        ScrollViewReader { proxy in
            List(filtered) { event in
                EventRowView(
                    event: event,
                    isExpanded: expandedIDs.contains(event.id),
                    onSelectErrorCode: { dictionaryEntry = $0 },
                    onToggleDetail: { toggleDetail(for: event) }
                )
            }
            .listStyle(.plain)
            .onChange(of: filtered.last?.id) {
                guard autoScroll, let last = filtered.last else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 展开 / 收起某一行的 detail。
    private func toggleDetail(for event: MatterEvent) {
        withAnimation(.snappy(duration: 0.2)) {
            if expandedIDs.contains(event.id) {
                expandedIDs.remove(event.id)
            } else {
                expandedIDs.insert(event.id)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView(
            "暂无日志",
            systemImage: "text.alignleft",
            description: Text(events.isEmpty ? "Matter 事件会实时显示在这里" : "当前筛选条件下没有事件")
        )
    }

    /// 活动筛选摘要条：显示筛选维度与命中条数，可一键清除。
    private var activeFilterBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(filterSummary)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(filtered.count) 条")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("清除") { clearFilters() }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// 单行日志：级别徽标 + 消息，次要信息（时间 / 分类 / 节点）另起一行。
private struct EventRowView: View {
    let event: MatterEvent
    let isExpanded: Bool
    var onSelectErrorCode: (MatterErrorDictionary.Entry) -> Void
    var onToggleDetail: () -> Void

    /// 是否有可展开的补充上下文。
    private var hasDetail: Bool {
        !(event.detail ?? [:]).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(event.level.label)
                    .font(.system(.caption2, design: .rounded).weight(.semibold))
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(levelColor.opacity(0.14), in: Capsule())

                Text(event.message)
                    .font(.subheadline)
                    .textSelection(.enabled)

                Spacer(minLength: 0)

                if let code = event.errorCode {
                    Button {
                        onSelectErrorCode(entry(for: code))
                    } label: {
                        HStack(spacing: 3) {
                            Text(MatterHex.hex(code, width: 2))
                                .font(.system(.caption2, design: .monospaced))
                            Image(systemName: "info.circle")
                                .font(.caption2)
                        }
                        .foregroundStyle(levelColor)
                    }
                    .buttonStyle(.plain)
                }

                if hasDetail {
                    // 展开箭头同时也是显式的点击目标（整行也可点）。
                    Button {
                        onToggleDetail()
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 24, height: 24, alignment: .trailing)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Text(metadataText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            if isExpanded, let detail = event.detail {
                detailView(detail)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if hasDetail { onToggleDetail() }
        }
    }

    /// 展开的补充上下文：键值对逐行缩进，值用等宽字体便于核对报文/错误串。
    private func detailView(_ detail: [String: String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(detail.keys.sorted(), id: \.self) { key in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(key)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(detail[key] ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.top, 4)
        .padding(.leading, 10)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.quaternary)
                .frame(width: 2)
        }
        .transition(.opacity)
    }

    /// 次要元数据：时间 · 分类 · 节点 / 端点。
    private var metadataText: String {
        var parts = [
            event.timestamp.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            ),
            event.category.label,
        ]
        if let nodeID = event.nodeID { parts.append("节点 \(nodeID)") }
        if let endpointID = event.endpointID { parts.append("端点 \(endpointID)") }
        return parts.joined(separator: " · ")
    }

    /// 依据事件分类推断错误域（系统类事件来自框架错误回调，其余按交互状态解释）。
    private func entry(for code: Int) -> MatterErrorDictionary.Entry {
        let scope = event.category == .system ? MatterErrorDictionary.Scope.matter : .interaction
        if let match = MatterErrorDictionary.entry(scope: scope, code: code) {
            return match
        }
        return MatterErrorDictionary.Entry(
            scope: scope, code: code, name: "未收录",
            summary: "词典中未收录的错误码", suggestion: "请对照 Matter 规范或 SDK 头文件确认"
        )
    }

    private var levelColor: Color {
        switch event.level {
        case .debug: return .secondary
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// 筛选面板：级别 / 分类 / 节点三个维度，各维度均可多选，点选即生效。
private struct LogFilterSheet: View {
    @Binding var levels: Set<MatterEvent.Level>
    @Binding var categories: Set<MatterEvent.Category>
    @Binding var nodeIDs: Set<UInt64>
    let availableNodeIDs: [UInt64]

    @Environment(\.dismiss) private var dismiss

    private var hasActiveFilter: Bool {
        !levels.isEmpty || !categories.isEmpty || !nodeIDs.isEmpty
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    checkRow("全部级别", isSelected: levels.isEmpty) { levels.removeAll() }
                    ForEach(MatterEvent.Level.allCases, id: \.self) { item in
                        checkRow(item.label, isSelected: levels.contains(item)) {
                            if levels.contains(item) { levels.remove(item) } else { levels.insert(item) }
                        }
                    }
                } header: {
                    Text("级别")
                } footer: {
                    Text("可多选；未选中任何级别时显示全部。")
                }

                Section("分类") {
                    checkRow("全部分类", isSelected: categories.isEmpty) { categories.removeAll() }
                    ForEach(MatterEvent.Category.allCases, id: \.self) { item in
                        checkRow(item.label, isSelected: categories.contains(item)) {
                            if categories.contains(item) { categories.remove(item) } else { categories.insert(item) }
                        }
                    }
                }

                if !availableNodeIDs.isEmpty {
                    Section("节点") {
                        checkRow("全部节点", isSelected: nodeIDs.isEmpty) { nodeIDs.removeAll() }
                        ForEach(availableNodeIDs, id: \.self) { item in
                            checkRow("节点 \(item)", isSelected: nodeIDs.contains(item)) {
                                if nodeIDs.contains(item) { nodeIDs.remove(item) } else { nodeIDs.insert(item) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("筛选")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
                if hasActiveFilter {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("重置") {
                            levels.removeAll()
                            categories.removeAll()
                            nodeIDs.removeAll()
                        }
                    }
                }
            }
        }
    }

    /// 可勾选行：标题靠左，选中时右侧显示勾选标记。
    private func checkRow(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    LogsView()
}