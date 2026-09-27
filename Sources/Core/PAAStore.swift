import Foundation

/// 自定义 PAA（Product Attestation Authority）证书仓库。
///
/// 证书以 DER 文件保存在 `Library/PAACerts/`，由 MatterManager 启动时载入控制器工厂参数
/// （作为系统默认 PAA 列表之外的附加信任来源）。因此新增 / 删除证书需重启 App 生效。
final class PAAStore: @unchecked Sendable {
    static let shared = PAAStore()

    struct Item: Identifiable, Sendable, Hashable {
        let id: String
        var fileName: String
        var byteCount: Int
        var addedAt: Date
        var fileURL: URL
    }

    enum StoreError: LocalizedError {
        case invalidCertificate
        case duplicate

        var errorDescription: String? {
            switch self {
            case .invalidCertificate: "不是有效的 DER / PEM 证书文件"
            case .duplicate: "该证书已存在"
            }
        }
    }

    private let lock = NSLock()
    private let directory: URL

    init() {
        directory = AppDirectories.cacheSubdirectory("PAACerts")
    }

    /// 存储目录（设置页统计缓存占用用）。
    var directoryURL: URL { directory }

    var directoryPath: String { directory.path }

    /// 已加载的自定义 PAA 证书（按添加时间正序）。
    func all() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// 从文件导入（支持 DER 与 PEM 编码）。
    @discardableResult
    func add(from url: URL) throws -> Item {
        let needsRelease = url.startAccessingSecurityScopedResource()
        defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }

        let raw = try Data(contentsOf: url)
        guard let der = Self.derBytes(from: raw) else { throw StoreError.invalidCertificate }
        let id = Self.fingerprint(of: der)
        let item = Item(
            id: id,
            fileName: url.lastPathComponent,
            byteCount: der.count,
            addedAt: Date(),
            fileURL: directory.appendingPathComponent(id + ".der")
        )

        lock.lock(); defer { lock.unlock() }
        var items = loadLocked()
        if let existing = items.first(where: { $0.id == id }) {
            if existing.fileName == item.fileName { throw StoreError.duplicate }
            items.removeAll { $0.id == id }
        }
        try der.write(to: item.fileURL, options: .atomic)
        items.append(item)
        persistLocked(items)
        LogStore.shared.log(
            category: .system, level: .info, message: "已导入自定义 PAA 证书",
            detail: ["文件": item.fileName, "长度": "\(item.byteCount) 字节", "指纹": String(id.prefix(16))]
        )
        return item
    }

    func remove(id: String) {
        lock.lock(); defer { lock.unlock() }
        var items = loadLocked()
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        try? FileManager.default.removeItem(at: item.fileURL)
        persistLocked(items)
        LogStore.shared.log(
            category: .system, level: .warning, message: "已删除自定义 PAA 证书",
            detail: ["文件": item.fileName]
        )
    }

    /// 供 `MTRDeviceControllerFactoryParams.productAttestationAuthorityCertificates` 使用。
    func certificateData() -> [Data] {
        all().compactMap { try? Data(contentsOf: $0.fileURL) }
    }

    // MARK: - 内部

    private static let manifestName = "manifest.json"

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }

    private struct ManifestEntry: Codable {
        let id: String
        let fileName: String
        let byteCount: Int
        let addedAt: Date
    }

    /// 读取仓库内容（调用方持锁）。以磁盘实际文件为准，清单仅记录来源信息。
    private func loadLocked() -> [Item] {
        var origin: [String: ManifestEntry] = [:]
        if let data = try? Data(contentsOf: manifestURL),
           let decoded = try? JSONDecoder().decode([ManifestEntry].self, from: data) {
            // 逐个写入而非 Dictionary(uniqueKeysWithValues:)：清单里出现重复 id 时会直接 trap。
            for entry in decoded { origin[entry.id] = entry }
        }
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return files
            .filter { $0.pathExtension == "der" }
            .compactMap { url -> Item? in
                let id = url.deletingPathExtension().lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                let entry = origin[id]
                return Item(
                    id: id,
                    fileName: entry?.fileName ?? id + ".der",
                    byteCount: entry?.byteCount ?? size,
                    addedAt: entry?.addedAt ?? modified,
                    fileURL: url
                )
            }
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// 写入清单（调用方持锁）。
    private func persistLocked(_ items: [Item]) {
        let entries = items.map {
            ManifestEntry(id: $0.id, fileName: $0.fileName, byteCount: $0.byteCount, addedAt: $0.addedAt)
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// DER / PEM → DER 字节；格式非法返回 nil。
    private static func derBytes(from raw: Data) -> Data? {
        if raw.starts(with: [0x30]) { return raw }
        guard let text = String(data: raw, encoding: .utf8) else { return nil }
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        guard let beginRange = text.range(of: begin),
              let endRange = text.range(of: end, range: beginRange.upperBound ..< text.endIndex) else {
            return nil
        }
        let base64 = text[beginRange.upperBound ..< endRange.lowerBound]
            .components(separatedBy: .whitespacesAndNewlines)
            .joined()
        guard let der = Data(base64Encoded: base64), der.starts(with: [0x30]) else { return nil }
        return der
    }

    /// 证书内容指纹（SHA-256 十六进制），用作存储 ID。
    private static func fingerprint(of der: Data) -> String {
        der.sha256Hex
    }
}