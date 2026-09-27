import Foundation

/// App 缓存目录解析（统一入口）。
///
/// 三个缓存型存储（OTA 镜像、PAA 证书、DCL 数据）此前各自抄了一份「优先 Library、
/// 取不到时退化到 temporaryDirectory」的逻辑。退化本身是必要兜底，但它此前是**静默**的：
/// 缓存随时可能被系统清理而无人察觉，故集中到此处并在退化时记一条 warning。
///
/// 注意：fabric 状态目录 `MatterStore`（见 `MatterManager`）**不走这里**。它不是缓存，
/// 退化到临时目录意味着 fabric 数据可能被系统清空，因此保持「只用 Library、不退化」的既有行为。
enum AppDirectories {

    /// Library 下的缓存子目录（不存在则创建）；取不到 Library 时退化到临时目录并记 warning。
    static func cacheSubdirectory(_ name: String) -> URL {
        if let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            let directory = library.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        LogStore.shared.log(
            category: .system,
            level: .warning,
            message: "取不到 Library 目录，缓存已退化到临时目录（可能被系统清理）",
            detail: ["目录": name]
        )
        return directory
    }

    /// 目录占用字节（递归累加常规文件；目录不存在或不可读时返回 0）。
    static func usageBytes(of directory: URL) -> Int {
        var total = 0
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize
            else { continue }
            total += size
        }
        return total
    }
}