import Foundation
import Network

/// 待配网设备的 DNS-SD TXT 记录浏览。
///
/// Matter.framework 的 `MTRCommissionableBrowserResult` 只暴露 instanceName / vendorID /
/// productID / discriminator / commissioningMode，不转发 TXT 记录。这里自行浏览
/// `_matterc._udp` 取其中的 `DT`（设备类型 ID），按 instanceName 与框架的扫描结果合并。
/// 仅覆盖局域网广告：蓝牙广播不含 TXT 记录，故 BLE 设备拿不到设备类型。
final class CommissionableTXTBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.example.MatterExplorer.commissionable-txt")
    private let lock = NSLock()
    private var browser: NWBrowser?

    /// 设备类型变化回调：(instanceName, 设备类型 ID)。未提供 DT 字段时为 nil。
    /// TXT 记录可能先于框架的扫描结果到达，由调用方自行缓存。
    var onDeviceType: (@Sendable (String, UInt32?) -> Void)?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return browser != nil
    }

    func start() {
        lock.lock()
        guard browser == nil else { lock.unlock(); return }
        lock.unlock()

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: "_matterc._udp", domain: nil),
            using: .tcp
        )
        browser.stateUpdateHandler = { state in
            guard case .failed(let error) = state else { return }
            LogStore.shared.log(
                category: .network, level: .warning,
                message: "TXT 记录浏览失败，设备类型将缺失",
                detail: ["错误": error.localizedDescription]
            )
        }
        browser.browseResultsChangedHandler = { [weak self] _, changes in
            guard let self else { return }
            for change in changes {
                switch change {
                case .added(let result), .changed(_, let result, _):
                    self.report(result)
                case .removed, .identical:
                    break
                @unknown default:
                    break
                }
            }
        }

        lock.lock()
        self.browser = browser
        lock.unlock()
        browser.start(queue: queue)
    }

    func stop() {
        lock.lock()
        let browser = self.browser
        self.browser = nil
        lock.unlock()
        browser?.cancel()
    }

    /// 从浏览结果中取出实例名与 DT 字段。
    private func report(_ result: NWBrowser.Result) {
        guard case .service(let instanceName, _, _, _) = result.endpoint,
              case .bonjour(let txtRecord) = result.metadata
        else { return }
        onDeviceType?(instanceName, Self.deviceTypeID(from: txtRecord["DT"]))
    }

    /// TXT 的 DT 为十六进制字符串（如 "0100"），容错处理 "0x" 前缀与空白。
    static func deviceTypeID(from raw: String?) -> UInt32? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("0x") { text.removeFirst(2) }
        guard !text.isEmpty, text.allSatisfy(\.isHexDigit) else { return nil }
        return UInt32(text, radix: 16)
    }
}