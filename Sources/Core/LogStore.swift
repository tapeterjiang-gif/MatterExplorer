import Foundation

/// 事件总线：内存环形缓冲（默认 2000 条）+ 多订阅者 AsyncStream 实时流。
/// 线程安全：任何线程可调用 `log`。
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    /// 缓冲被清空通知：日志页据此清掉本地已渲染的条目（缓冲清空本身不影响已订阅的 UI 数组）。
    static let didClearNotification = Notification.Name("com.example.MatterExplorer.logStoreDidClear")

    private let lock = NSLock()
    private var events: [MatterEvent] = []
    private var continuations: [UUID: AsyncStream<MatterEvent>.Continuation] = [:]
    private let maxBuffered = 2000

    private let defaults: UserDefaults
    private static let minimumLevelKey = "com.example.MatterExplorer.logMinimumLevel"

    /// 最低收录级别：低于该级别的事件不入缓冲、不推送（设置页可调，持久化）。
    private var _minimumLevel: MatterEvent.Level

    /// 未设置过时的默认级别：info。
    /// debug 级多是高频的订阅属性报告 / 在线状态变化，默认不收录以免日志刷屏并拖慢 UI；需要时可在设置页切到 DEBUG。
    static let defaultMinimumLevel: MatterEvent.Level = .info

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let raw = defaults.string(forKey: Self.minimumLevelKey) ?? ""
        self._minimumLevel = MatterEvent.Level(rawValue: raw) ?? Self.defaultMinimumLevel
    }

    var minimumLevel: MatterEvent.Level {
        lock.lock(); defer { lock.unlock() }
        return _minimumLevel
    }

    func setMinimumLevel(_ level: MatterEvent.Level) {
        lock.lock()
        _minimumLevel = level
        lock.unlock()
        defaults.set(level.rawValue, forKey: Self.minimumLevelKey)
    }

    /// 当前缓冲快照（供订阅前初始渲染，理论上不必需——事件流会重放快照）。
    var snapshot: [MatterEvent] {
        lock.lock(); defer { lock.unlock() }
        return events
    }

    /// 订阅事件流：先重放当前缓冲，再实时推送。
    func eventStream() -> AsyncStream<MatterEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<MatterEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(4096)
        )
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.continuations[id] = nil
            self.lock.unlock()
        }
        let replay: [MatterEvent]
        lock.lock()
        continuations[id] = continuation
        replay = events
        lock.unlock()
        for event in replay {
            continuation.yield(event)
        }
        return stream
    }

    /// 清空缓冲（不影响已订阅的 UI 侧本地数组），并广播通知让界面同步清空。
    func clear() {
        lock.lock()
        events.removeAll()
        lock.unlock()
        NotificationCenter.default.post(name: Self.didClearNotification, object: nil)
    }

    // MARK: - 写入

    func log(_ event: MatterEvent) {
        let targets: [AsyncStream<MatterEvent>.Continuation]
        lock.lock()
        guard event.level.rank >= _minimumLevel.rank else {
            lock.unlock()
            return
        }
        events.append(event)
        if events.count > maxBuffered {
            events.removeFirst(events.count - maxBuffered)
        }
        targets = Array(continuations.values)
        lock.unlock()
        for target in targets {
            target.yield(event)
        }
    }

    func log(
        category: MatterEvent.Category,
        level: MatterEvent.Level,
        message: String,
        detail: [String: String]? = nil,
        errorCode: Int? = nil,
        nodeID: UInt64? = nil,
        endpointID: UInt16? = nil
    ) {
        log(MatterEvent(
            category: category,
            level: level,
            nodeID: nodeID,
            endpointID: endpointID,
            message: message,
            detail: detail,
            errorCode: errorCode
        ))
    }

    // MARK: - 便捷方法（M1 阶段主要用于 system 事件）

    func system(_ message: String, detail: [String: String]? = nil, errorCode: Int? = nil) {
        log(category: .system, level: .info, message: message, detail: detail, errorCode: errorCode)
    }

    func warning(_ message: String, detail: [String: String]? = nil) {
        log(category: .system, level: .warning, message: message, detail: detail)
    }

    func error(_ message: String, error: Error?, detail: [String: String]? = nil) {
        var merged = detail ?? [:]
        if let error {
            merged["错误"] = String(describing: error)
        }
        log(category: .system, level: .error, message: message, detail: merged.isEmpty ? nil : merged)
    }
}
