import Foundation

// MARK: - DCL 数据表

/// CSA DCL 中值得缓存在本地的高价值全量表。
enum DCLTable: String, CaseIterable, Sendable {
    /// 厂商表：VID → 厂商名。
    case vendors
    /// 产品表：(VID, PID) → 商业产品名 + 设备类型 ID。
    case products
    /// 认证表：(VID, PID, 软件版本) → 认证类型与认证值。
    case certifiedModels

    /// 缓存文件名（`Library/DCLData/` 下）。
    var fileName: String {
        switch self {
        case .vendors: "vendors.json"
        case .products: "products.json"
        case .certifiedModels: "certified-models.json"
        }
    }

    /// 随包初始快照的资源名（`Sources/Resources/`）。
    var bundleResourceName: String {
        switch self {
        case .vendors: "matter-vendors"
        case .products: "matter-products"
        case .certifiedModels: "matter-certified-models"
        }
    }

    /// 界面展示名。
    var label: String {
        switch self {
        case .vendors: "厂商表"
        case .products: "产品表"
        case .certifiedModels: "认证表"
        }
    }

    /// 提交时的防御性下限：低于此条目数视为异常（服务端静默截断），拒绝覆盖已有数据。
    var minimumEntryCount: Int {
        switch self {
        case .vendors: 100
        case .products: 1000
        case .certifiedModels: 1000
        }
    }
}

// MARK: - 缓存仓库

/// DCL 数据本地缓存：运行时从 DCL 下载的三张全量表存于 `Library/DCLData/`，
/// 随包 JSON 作为初始快照与兜底。
///
/// 读取路径统一为 `data(for:)`：缓存有效则用缓存，否则回落随包资源。
/// 线程安全：全部读写经 NSLock；对外只暴露 Sendable 值类型。
final class DCLCatalogStore: @unchecked Sendable {
    static let shared = DCLCatalogStore()

    /// 数据变更通知：缓存提交或恢复随包数据后发出，界面订阅后即时刷新。
    static let didChangeNotification = Notification.Name("com.example.MatterExplorer.dclCatalogDidChange")

    /// 缓存有效性 / 来源判定。
    enum Source: Sendable {
        /// 三张表都来自已下载的缓存。
        case cache
        /// 部分表来自缓存，其余回落随包快照（上次更新只成功了一部分）。
        case partialCache
        /// 无缓存，全部来自随包快照。
        case bundled
        /// 磁盘上有缓存，但随包版本已变化（App 升级），已整体回落随包快照。
        case bundledAfterUpgrade
    }

    /// 单表状态（供设置页展示）。
    struct TableInfo: Codable, Sendable {
        var entryCount: Int
        var byteCount: Int
        var fetchedAt: Date
    }

    /// 各表状态 + 来源（对外快照）。
    struct Snapshot: Sendable {
        var source: Source
        var updatedAt: Date?
        var tables: [DCLTable: TableInfo]

        /// 各表条目数摘要（如「858 / 5282 / 5412」）。
        var countsText: String {
            DCLTable.allCases.map { "\(tables[$0]?.entryCount ?? 0)" }.joined(separator: " / ")
        }

        /// 设置页入口行的摘要文案。只到日：行内宽度有限，具体时刻在 DCL 数据页的「更新时间」看。
        var summaryText: String {
            switch source {
            case .cache:
                guard let updatedAt else { return "已下载缓存" }
                return "已下载缓存 · \(updatedAt.formatted(date: .numeric, time: .omitted))"
            case .partialCache:
                return "部分表已更新 · \(countsText) 条"
            case .bundled, .bundledAfterUpgrade:
                return "随包数据 · \(countsText) 条"
            }
        }
    }

    enum StoreError: LocalizedError {
        case belowMinimum(DCLTable, Int)
        case malformedTable(DCLTable)

        var errorDescription: String? {
            switch self {
            case let .belowMinimum(table, count):
                "\(table.label)仅 \(count) 条，低于安全下限（疑似下载被截断），已拒绝覆盖"
            case let .malformedTable(table):
                "\(table.label)内容无法解析，已拒绝覆盖"
            }
        }
    }

    private let lock = NSLock()
    private let directory: URL

    /// 当前 Bundle 版本（随包快照的版本标识）；缓存登记的是另一版本时视为过期。
    private let bundleVersion: String

    /// 更新互斥标志。
    private var _isUpdating = false

    /// 随包快照的条目数记忆化。随包资源在本次启动内不变，故解析一次即可复用
    /// （缓存表不必走这里：manifest 的 `TableInfo.entryCount` 已记录条目数）。
    private var bundledEntryCounts: [DCLTable: Int] = [:]

    init(bundle: Bundle = .main) {
        directory = AppDirectories.cacheSubdirectory("DCLData")
        bundleVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    /// 存储目录（设置页统计缓存占用用）。
    var directoryURL: URL { directory }

    var directoryPath: String { directory.path }

    // MARK: - 读取

    /// 某表的有效数据：缓存优先，缓存缺失 / 过期 / 损坏时回落随包快照。
    /// 返回 nil 表示缓存与随包资源都不可用。
    func data(for table: DCLTable) -> Data? {
        lock.lock()
        let manifest = loadManifestLocked()
        let useCache = manifest.map { isValidLocked($0, for: table) } ?? false
        let cached = useCache ? try? Data(contentsOf: fileURL(for: table)) : nil
        lock.unlock()
        if let cached, !cached.isEmpty { return cached }
        return bundledData(for: table)
    }

    /// 随包初始快照（不读缓存）。
    func bundledData(for table: DCLTable) -> Data? {
        guard let url = Bundle.main.url(forResource: table.bundleResourceName, withExtension: "json") else {
            return nil
        }
        return try? Data(contentsOf: url)
    }

    /// 设置页展示用的状态快照。
    func snapshot() -> Snapshot {
        lock.lock()
        let manifest = loadManifestLocked()
        let cachedTables = manifest.map { stored in
            DCLTable.allCases.reduce(into: [DCLTable: TableInfo]()) { result, table in
                guard isValidLocked(stored, for: table), let info = stored.tables[table.rawValue] else { return }
                result[table] = info
            }
        } ?? [:]
        lock.unlock()

        var tables: [DCLTable: TableInfo] = [:]
        for table in DCLTable.allCases {
            if let info = cachedTables[table] {
                tables[table] = info
            } else {
                let bytes = bundledData(for: table)?.count ?? 0
                tables[table] = TableInfo(entryCount: bundledEntryCount(for: table), byteCount: bytes, fetchedAt: Date())
            }
        }

        let source: Source
        if cachedTables.count == DCLTable.allCases.count {
            source = .cache
        } else if !cachedTables.isEmpty {
            source = .partialCache
        } else if manifest != nil {
            source = .bundledAfterUpgrade
        } else {
            source = .bundled
        }
        return Snapshot(source: source, updatedAt: manifest?.updatedAt, tables: tables)
    }

    /// 随包快照的条目数，解析一次后记忆化。
    ///
    /// 设置页每次出现（`.task`）与下拉刷新都会取一次 `snapshot()`，若每次都重新解析
    /// 三张表约 380 KB 的 JSON，纯属在主线程白做工。随包内容本次启动内不变，故记住即可；
    /// 无需随 `replace` / `restoreBundled` 失效——那时该表要么改用 manifest 的记录，
    /// 要么回落的仍是同一份随包资源。
    private func bundledEntryCount(for table: DCLTable) -> Int {
        lock.lock()
        let cached = bundledEntryCounts[table]
        lock.unlock()
        if let cached { return cached }

        let count = parseEntryCount(for: table)

        // 解析失败（返回 0）时不记忆化，避免把一次瞬时失败固化下来。
        if count > 0 {
            lock.lock()
            bundledEntryCounts[table] = count
            lock.unlock()
        }
        return count
    }

    /// 解析数据算出条目数（仅随包快照路径需要）。
    private func parseEntryCount(for table: DCLTable) -> Int {
        guard let data = data(for: table) else { return 0 }
        switch table {
        case .vendors:
            return (try? JSONDecoder().decode([String: String].self, from: data))?.count ?? 0
        case .products, .certifiedModels:
            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return 0 }
            return rows.count
        }
    }

    // MARK: - 写入

    /// 提交一张表：校验 → 写盘 → 更新 manifest 中该表的条目与时间戳。
    /// 按表原子：失败或校验不通过时该表原数据保持不变，直接抛出。
    func replace(table: DCLTable, count: Int, data: Data) throws {
        guard count >= table.minimumEntryCount else {
            throw StoreError.belowMinimum(table, count)
        }
        guard isParsable(data, for: table) else {
            throw StoreError.malformedTable(table)
        }

        lock.lock()
        var manifest = loadManifestLocked() ?? Manifest(bundleVersion: bundleVersion, updatedAt: Date(), tables: [:])
        do {
            try data.write(to: fileURL(for: table), options: .atomic)
        } catch {
            lock.unlock()
            throw error
        }
        manifest.bundleVersion = bundleVersion
        manifest.updatedAt = Date()
        manifest.tables[table.rawValue] = TableInfo(entryCount: count, byteCount: data.count, fetchedAt: Date())
        persistManifestLocked(manifest)
        lock.unlock()
        LogStore.shared.log(
            category: .system, level: .info, message: "已更新 DCL 数据表",
            detail: ["表": table.label, "条目": "\(count)", "字节": "\(data.count)"]
        )
    }

    /// 清空本地缓存，回到随包快照。
    func restoreBundled() {
        lock.lock()
        for table in DCLTable.allCases {
            try? FileManager.default.removeItem(at: fileURL(for: table))
        }
        try? FileManager.default.removeItem(at: manifestURL)
        lock.unlock()
        LogStore.shared.log(category: .system, level: .warning, message: "已恢复 DCL 随包数据")
        reloadCatalogs()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - 更新互斥

    /// 尝试开始一次更新；已有更新在跑时返回 false。
    func beginUpdate() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !_isUpdating else { return false }
        _isUpdating = true
        return true
    }

    /// 结束一次更新（须与 `beginUpdate()` 配对，放在 defer 中）。
    func endUpdate() {
        lock.lock(); defer { lock.unlock() }
        _isUpdating = false
    }

    /// 提交完成后重载各 Catalog 并发通知。
    func finishUpdate() {
        reloadCatalogs()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 重载依赖本仓库的查询枚举。
    private func reloadCatalogs() {
        MatterVendorCatalog.reload()
        MatterProductCatalog.reload()
        MatterCertifiedModelCatalog.reload()
    }

    // MARK: - 内部

    private static let manifestName = "manifest.json"

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }

    private func fileURL(for table: DCLTable) -> URL {
        directory.appendingPathComponent(table.fileName)
    }

    /// 缓存清单。
    private struct Manifest: Codable {
        var bundleVersion: String
        var updatedAt: Date
        var tables: [String: TableInfo]
    }

    private func loadManifestLocked() -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    private func persistManifestLocked(_ manifest: Manifest) {
        guard let data = try? JSONEncoder().encode(manifest) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// 某表的缓存有效性：随包版本匹配、文件存在且登记条目数大于 0。
    /// 逐表判定：上次更新只成功了一部分时，成功的表照样生效。
    private func isValidLocked(_ manifest: Manifest, for table: DCLTable) -> Bool {
        guard manifest.bundleVersion == bundleVersion,
              let info = manifest.tables[table.rawValue], info.entryCount > 0
        else { return false }
        return FileManager.default.fileExists(atPath: fileURL(for: table).path)
    }

    /// 内容可解析性校验（顶层结构与预期一致）。
    private func isParsable(_ data: Data, for table: DCLTable) -> Bool {
        switch table {
        case .vendors:
            return (try? JSONDecoder().decode([String: String].self, from: data)) != nil
        case .products, .certifiedModels:
            guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return false }
            return rows.allSatisfy { $0.count >= 4 }
        }
    }
}

