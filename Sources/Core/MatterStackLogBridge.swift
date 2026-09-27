import Foundation
import Matter

/// Matter 栈日志桥接：把 Matter.framework 内部日志（`MTRSetLogCallback`）转发到 LogStore。
///
/// 注意：框架要求回调内不得直接/间接调用 Matter API、不得长时间阻塞线程。
/// 此处只做内存写入与 AsyncStream yield，满足约束。
enum MatterStackLogBridge {

    /// 栈日志阈值（与 `MTRLogType` 数值一致）。
    enum Threshold: Int, CaseIterable, Identifiable, Sendable {
        case off = 0
        case error = 1
        case progress = 2
        case detail = 3

        var id: Int { rawValue }

        var label: String {
            switch self {
            case .off: "关闭"
            case .error: "仅错误"
            case .progress: "错误 + 进度"
            case .detail: "全部（含详情）"
            }
        }
    }

    private static let defaultsKey = "com.example.MatterExplorer.matterStackLogThreshold"

    /// 当前阈值（持久化；未设置过时默认「仅错误」）。
    static var current: Threshold {
        guard let raw = UserDefaults.standard.object(forKey: defaultsKey) as? Int,
              let threshold = Threshold(rawValue: raw) else {
            return .error
        }
        return threshold
    }

    /// 应用阈值（关闭时移除回调）；可重复调用。
    static func apply(_ threshold: Threshold) {
        UserDefaults.standard.set(threshold.rawValue, forKey: defaultsKey)
        guard threshold != .off, let type = MTRLogType(rawValue: threshold.rawValue) else {
            MTRSetLogCallback(.error, nil)
            LogStore.shared.log(category: .system, level: .info, message: "Matter 栈日志已关闭")
            return
        }
        MTRSetLogCallback(type) { type, module, message in
            let level = level(for: type)
            // 该级别不会入缓冲时直接返回：省下为每条框架日志构造事件与 detail 字典的开销。
            guard level.rank >= LogStore.shared.minimumLevel.rank else { return }
            LogStore.shared.log(
                category: .protocolSession,
                level: level,
                message: message,
                detail: ["模块": module]
            )
        }
        LogStore.shared.log(
            category: .system, level: .info,
            message: "Matter 栈日志已开启", detail: ["阈值": threshold.label]
        )
    }

    /// 启动时按已保存设置恢复（默认「仅错误」）。
    static func restore() {
        apply(current)
    }

    private static func level(for type: MTRLogType) -> MatterEvent.Level {
        switch type {
        case .error: .error
        case .progress: .info
        default: .debug
        }
    }
}