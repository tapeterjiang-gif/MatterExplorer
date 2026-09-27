import Foundation
import Observation

/// 设置页视图模型：controller / fabric 状态、日志级别、PAA 证书、DCL 数据、重置。
@MainActor
@Observable
final class SettingsViewModel {
    private(set) var status: MatterManager.Status
    var minimumLevel: MatterEvent.Level
    var stackLogThreshold: MatterStackLogBridge.Threshold
    private(set) var paaItems: [PAAStore.Item] = []

    /// 操作反馈（导入 / 删除 / 重置结果）。
    var notice: String?
    var paaErrorMessage: String?

    /// DCL 数据缓存状态（首次 `refresh()` 后填充）。
    private(set) var dclSnapshot: DCLCatalogStore.Snapshot?
    private(set) var isDCLUpdating = false
    private(set) var dclProgress: DCLProgress?
    var dclNotice: String?
    var dclErrorMessage: String?

    private var dclTask: Task<Void, Never>?

    /// 更新进度（不显示百分比：DCL 的 `pagination.total` 不可信）。
    struct DCLProgress: Sendable {
        var table: DCLTable
        var tableIndex: Int
        var tableCount: Int
        var completedPages: Int

        var text: String {
            "正在拉取\(table.label)，已完成 \(completedPages) 页（第 \(tableIndex)/\(tableCount) 张表）"
        }
    }

    /// 设置页入口行摘要。
    var dclSummaryText: String { dclSnapshot?.summaryText ?? "" }

    /// 三个缓存目录（DCL 数据 / OTA 镜像 / PAA 证书）的合计占用字节。
    /// 目录遍历有开销，故只在 `init()` / `refresh()` 时统计，不在 body 里算。
    private(set) var cacheUsageBytes = 0

    /// 缓存占用文案（复用 `Int.byteText`）。
    var cacheUsageText: String { cacheUsageBytes.byteText }

    /// 当前随包构建号：与缓存里登记的版本不一致时缓存视为过期。
    var dclBundleVersionText: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
    }

    var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(version) (\(build))"
    }

    init() {
        status = MatterManager.shared.status()
        minimumLevel = LogStore.shared.minimumLevel
        stackLogThreshold = MatterStackLogBridge.current
        paaItems = PAAStore.shared.all()
        cacheUsageBytes = Self.cacheUsage()
    }

    func refresh() {
        status = MatterManager.shared.status()
        paaItems = PAAStore.shared.all()
        dclSnapshot = DCLCatalogStore.shared.snapshot()
        cacheUsageBytes = Self.cacheUsage()
    }

    /// 三个缓存目录的合计占用字节。
    private static func cacheUsage() -> Int {
        AppDirectories.usageBytes(of: DCLCatalogStore.shared.directoryURL)
            + AppDirectories.usageBytes(of: OTAImageStore.shared.directoryURL)
            + AppDirectories.usageBytes(of: PAAStore.shared.directoryURL)
    }

    // MARK: - 日志

    func applyMinimumLevel(_ level: MatterEvent.Level) {
        minimumLevel = level
        LogStore.shared.setMinimumLevel(level)
        LogStore.shared.log(
            category: .system, level: .info,
            message: "日志最低收录级别已设为 \(level.rawValue.uppercased())"
        )
    }

    func applyStackLogThreshold(_ threshold: MatterStackLogBridge.Threshold) {
        stackLogThreshold = threshold
        MatterStackLogBridge.apply(threshold)
    }

    /// 清空内存日志缓冲（日志页经通知同步清空）。
    func clearLogs() {
        LogStore.shared.clear()
    }

    // MARK: - PAA 证书

    func importPAA(from url: URL) {
        do {
            let item = try PAAStore.shared.add(from: url)
            paaErrorMessage = nil
            notice = "已导入 \(item.fileName)；重启 App 后随控制器工厂加载。"
        } catch {
            paaErrorMessage = error.localizedDescription
        }
        refresh()
    }

    func deletePAA(id: String) {
        PAAStore.shared.remove(id: id)
        notice = "已删除该证书；重启 App 后生效。"
        refresh()
    }

    // MARK: - DCL 数据

    /// 手动更新 DCL 三张全量表：逐表下载 → 校验 → 提交（按表原子）。
    /// 失败或取消时未改动的表保留原数据。
    func startDCLUpdate() {
        guard !isDCLUpdating, dclTask == nil else { return }
        guard DCLCatalogStore.shared.beginUpdate() else { return }
        isDCLUpdating = true
        dclNotice = nil
        dclErrorMessage = nil
        dclProgress = nil
        dclTask = Task { await runDCLUpdate() }
    }

    /// 取消正在进行的更新。
    func cancelDCLUpdate() {
        dclTask?.cancel()
    }

    /// 清空本地缓存，回到随包快照。
    func restoreBundledDCL() {
        DCLCatalogStore.shared.restoreBundled()
        dclNotice = "已恢复为随包数据。"
        dclErrorMessage = nil
        refresh()
    }

    private func runDCLUpdate() async {
        defer {
            DCLCatalogStore.shared.endUpdate()
            isDCLUpdating = false
            dclProgress = nil
            dclTask = nil
            refresh()
        }

        let tables = DCLTable.allCases
        var succeeded: [String] = []
        var failures: [String] = []
        var cancelled = false

        for (index, table) in tables.enumerated() {
            if Task.isCancelled { cancelled = true; break }
            let tableIndex = index + 1
            let tableCount = tables.count
            dclProgress = DCLProgress(table: table, tableIndex: tableIndex, tableCount: tableCount, completedPages: 0)
            do {
                let outcome = try await DCLClient.fetch(table: table) { [weak self] pages in
                    await self?.setProgress(
                        table: table, tableIndex: tableIndex, tableCount: tableCount, completedPages: pages
                    )
                }
                try DCLCatalogStore.shared.replace(table: table, count: outcome.count, data: outcome.data)
                succeeded.append("\(table.label) \(outcome.count) 条")
            } catch is CancellationError {
                cancelled = true
                break
            } catch {
                if Task.isCancelled { cancelled = true; break }
                failures.append(error.localizedDescription)
            }
        }

        DCLCatalogStore.shared.finishUpdate()

        var lines: [String] = []
        if !succeeded.isEmpty {
            lines.append("已更新：" + succeeded.joined(separator: "、") + "。")
        }
        if cancelled {
            lines.append("已取消，本次未改动的表保持原数据。")
        }
        dclNotice = lines.isEmpty ? nil : lines.joined(separator: "\n")
        dclErrorMessage = failures.isEmpty
            ? nil
            : "以下表未更新，已保持原数据：\n" + failures.joined(separator: "\n")
    }

    private func setProgress(table: DCLTable, tableIndex: Int, tableCount: Int, completedPages: Int) {
        dclProgress = DCLProgress(
            table: table, tableIndex: tableIndex, tableCount: tableCount, completedPages: completedPages
        )
    }

    // MARK: - 重置

    /// 清空本机 Matter 状态；返回给用户展示的结果明细。
    func reset() -> String {
        let detail = MatterManager.shared.resetPersistentState()
        refresh()
        let lines = detail.sorted { $0.key < $1.key }.map { "\($0.key)：\($0.value)" }
        return lines.joined(separator: "\n")
    }
}