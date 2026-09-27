import Foundation
import Matter

/// `MTRStorage` 协议适配器：以 Library/MatterStore/ 下的文件（每 key 一个文件）持久化
/// Matter 框架内部状态。框架可能从任意线程调用，但不并发调用；此处仍用锁保护以保险。
final class MTRStorageAdapter: NSObject, MTRStorage {
    private let directory: URL
    private let lock = NSLock()

    init(directory: URL) {
        self.directory = directory
        super.init()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for key: String) -> URL {
        let hex = key.data(using: .utf8)?.hexString ?? ""
        return directory.appendingPathComponent(hex + ".data")
    }

    func storageData(forKey key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        return try? Data(contentsOf: fileURL(for: key))
    }

    func setStorageData(_ value: Data, forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            try value.write(to: fileURL(for: key), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func removeStorageData(forKey key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let url = fileURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        try? FileManager.default.removeItem(at: url)
        return true
    }
}
