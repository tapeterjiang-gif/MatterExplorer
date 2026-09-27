import Foundation
import Matter

/// OTA 固件镜像库：导入 `.ota` → `MTROTAHeader` 解析头部 → 存于 `Library/OTAImages/`。
///
/// 头部字段（VID / PID / 目标版本 / 载荷大小）随导入一并解析并写入清单；
/// `OTAProviderService` 据此应答设备的 QueryImage，并把镜像按 BDX 分块回传。
final class OTAImageStore: @unchecked Sendable {
    static let shared = OTAImageStore()

    /// Matter OTA 镜像文件标识（规范「OTA Software Update File Format」首个字段）。
    static let fileIdentifier: UInt32 = 0x1BEEF11E

    struct Item: Identifiable, Sendable, Hashable {
        let id: String
        var fileName: String
        var byteCount: Int
        var addedAt: Date
        var fileURL: URL

        /// 镜像头部字段（`MTROTAHeader`）。
        var vendorID: UInt32
        var productID: UInt32
        var softwareVersion: UInt32
        var softwareVersionString: String
        var payloadSize: Int
        var minApplicableVersion: UInt32?
        var maxApplicableVersion: UInt32?
        var releaseNotesURL: String?

        /// BDX file designator：`QueryImageResponse.imageURI` 与 BDX 会话回传的字符串一致。
        var designator: String { "ota-" + id }

        /// 更新令牌（16 字节）：取镜像 ID 前 16 个字节，设备在 ApplyUpdateRequest / NotifyUpdateApplied 原样回传。
        var updateToken: Data { Data(hexString: String(id.prefix(32))) ?? Data() }

        /// 目标版本号展示（十六进制与可读字符串并列）。
        var versionText: String {
            let hex = MatterHex.hex(softwareVersion, width: 8)
            return softwareVersionString.isEmpty ? hex : "\(softwareVersionString)（\(hex)）"
        }
    }

    enum StoreError: LocalizedError {
        case notOTAImage
        case unreadableHeader
        case duplicate

        var errorDescription: String? {
            switch self {
            case .notOTAImage: "不是有效的 Matter OTA 镜像（文件标识不匹配）"
            case .unreadableHeader: "OTA 镜像头部无法解析（文件可能被截断）"
            case .duplicate: "该镜像已存在"
            }
        }
    }

    private let lock = NSLock()
    private let directory: URL

    init() {
        directory = AppDirectories.cacheSubdirectory("OTAImages")
    }

    /// 存储目录（设置页统计缓存占用用）。
    var directoryURL: URL { directory }

    var directoryPath: String { directory.path }

    /// 已导入镜像（按导入时间正序）。
    func all() -> [Item] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// 从文件导入 `.ota`：校验文件标识 → 解析头部 → 落盘。
    @discardableResult
    func add(from url: URL) throws -> Item {
        let needsRelease = url.startAccessingSecurityScopedResource()
        defer { if needsRelease { url.stopAccessingSecurityScopedResource() } }

        let raw = try Data(contentsOf: url, options: .mappedIfSafe)
        guard Self.isOTAImage(raw) else { throw StoreError.notOTAImage }
        guard let header = Self.parseHeader(raw), !header.softwareVersionString.isEmpty else {
            throw StoreError.unreadableHeader
        }

        let id = raw.sha256Hex
        let item = Item(
            id: id,
            fileName: url.lastPathComponent,
            byteCount: raw.count,
            addedAt: Date(),
            fileURL: directory.appendingPathComponent(id + ".ota"),
            vendorID: header.vendorID.uint32Value,
            productID: header.productID.uint32Value,
            softwareVersion: header.softwareVersion.uint32Value,
            softwareVersionString: header.softwareVersionString,
            payloadSize: header.payloadSize.intValue,
            minApplicableVersion: header.minApplicableVersion?.uint32Value,
            maxApplicableVersion: header.maxApplicableVersion?.uint32Value,
            releaseNotesURL: header.releaseNotesURL
        )

        lock.lock(); defer { lock.unlock() }
        var items = loadLocked()
        if items.contains(where: { $0.id == id }) { throw StoreError.duplicate }
        try raw.write(to: item.fileURL, options: .atomic)
        items.append(item)
        persistLocked(items)
        LogStore.shared.log(
            category: .system, level: .info, message: "已导入 OTA 镜像",
            detail: [
                "文件": item.fileName,
                "VID / PID": "\(MatterHex.hex(item.vendorID, width: 4)) / \(MatterHex.hex(item.productID, width: 4))",
                "目标版本": item.versionText,
                "大小": "\(item.byteCount) 字节",
            ]
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
            category: .system, level: .warning, message: "已删除 OTA 镜像",
            detail: ["文件": item.fileName]
        )
    }

    /// 按 designator 取镜像（BDX 会话开始 / 结束时的定位依据）。
    func image(forDesignator designator: String) -> Item? {
        all().first { $0.designator == designator }
    }

    /// 按（VID, PID）与当前版本挑选可下发镜像：版本更高且落在 min / max 适用区间内。
    /// VID / PID 为 0 视为通配（规范允许镜像面向多厂商 / 多型号）。
    func image(vendorID: UInt32, productID: UInt32, newerThan version: UInt32) -> Item? {
        all()
            .filter { item in
                (item.vendorID == vendorID || item.vendorID == 0)
                    && (item.productID == productID || item.productID == 0)
                    && item.softwareVersion > version
                    && item.minApplicableVersion.map { version >= $0 } ?? true
                    && item.maxApplicableVersion.map { version <= $0 } ?? true
            }
            .max { $0.softwareVersion < $1.softwareVersion }
    }

    /// 读取镜像内容（供 BDX 分块回传；内存映射避免整文件复制）。
    func contents(of item: Item) -> Data? {
        try? Data(contentsOf: item.fileURL, options: .mappedIfSafe)
    }

    // MARK: - 内部

    private static let manifestName = "manifest.json"

    private var manifestURL: URL { directory.appendingPathComponent(Self.manifestName) }

    private struct ManifestEntry: Codable {
        let id: String
        let fileName: String
        let byteCount: Int
        let addedAt: Date
        let vendorID: UInt32
        let productID: UInt32
        let softwareVersion: UInt32
        let softwareVersionString: String
        let payloadSize: Int
        let minApplicableVersion: UInt32?
        let maxApplicableVersion: UInt32?
        let releaseNotesURL: String?
    }

    /// 读取仓库内容（调用方持锁）。以磁盘实际文件为准；清单缺失的镜像重新解析头部。
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
            .filter { $0.pathExtension == "ota" }
            .compactMap { url -> Item? in
                let id = url.deletingPathExtension().lastPathComponent
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if let entry = origin[id] {
                    return Item(
                        id: entry.id, fileName: entry.fileName, byteCount: entry.byteCount,
                        addedAt: entry.addedAt, fileURL: url,
                        vendorID: entry.vendorID, productID: entry.productID,
                        softwareVersion: entry.softwareVersion,
                        softwareVersionString: entry.softwareVersionString,
                        payloadSize: entry.payloadSize,
                        minApplicableVersion: entry.minApplicableVersion,
                        maxApplicableVersion: entry.maxApplicableVersion,
                        releaseNotesURL: entry.releaseNotesURL
                    )
                }
                // 清单缺失（手工放入的文件）：重新解析头部。
                guard let raw = try? Data(contentsOf: url, options: .mappedIfSafe),
                      let header = Self.parseHeader(raw) else { return nil }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date()
                return Item(
                    id: id, fileName: id + ".ota", byteCount: size, addedAt: modified, fileURL: url,
                    vendorID: header.vendorID.uint32Value, productID: header.productID.uint32Value,
                    softwareVersion: header.softwareVersion.uint32Value,
                    softwareVersionString: header.softwareVersionString,
                    payloadSize: header.payloadSize.intValue,
                    minApplicableVersion: header.minApplicableVersion?.uint32Value,
                    maxApplicableVersion: header.maxApplicableVersion?.uint32Value,
                    releaseNotesURL: header.releaseNotesURL
                )
            }
            .sorted { $0.addedAt < $1.addedAt }
    }

    /// 写入清单（调用方持锁）。
    private func persistLocked(_ items: [Item]) {
        let entries = items.map {
            ManifestEntry(
                id: $0.id, fileName: $0.fileName, byteCount: $0.byteCount, addedAt: $0.addedAt,
                vendorID: $0.vendorID, productID: $0.productID, softwareVersion: $0.softwareVersion,
                softwareVersionString: $0.softwareVersionString, payloadSize: $0.payloadSize,
                minApplicableVersion: $0.minApplicableVersion, maxApplicableVersion: $0.maxApplicableVersion,
                releaseNotesURL: $0.releaseNotesURL
            )
        }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: manifestURL, options: .atomic)
    }

    /// 前 4 字节（小端）是否为 Matter OTA 文件标识。
    private static func isOTAImage(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let bytes = [UInt8](data.prefix(4))
        let magic = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        return magic == fileIdentifier
    }

    /// 解析 OTA 头部。先按「文件标识 + 头部长度」做廉价前置校验，
    /// 避免把非镜像 / 截断数据交给 `MTROTAHeader`（其初始化器为非可失败签名）。
    private static func parseHeader(_ data: Data) -> MTROTAHeader? {
        guard isOTAImage(data), data.count >= 32 else { return nil }
        let sizeBytes = [UInt8](data[8 ..< 12])
        let headerSize = UInt32(sizeBytes[0]) | UInt32(sizeBytes[1]) << 8
            | UInt32(sizeBytes[2]) << 16 | UInt32(sizeBytes[3]) << 24
        guard headerSize >= 16, Int(headerSize) <= data.count else { return nil }
        return MTROTAHeader(data: data)
    }
}