import Foundation

/// Matter 事件模型：所有框架回调、网络事件、操作结果统一转为该结构进入 LogStore。
struct MatterEvent: Identifiable, Hashable, Sendable {
    /// 事件分类
    enum Category: String, CaseIterable, Sendable {
        case commissioning       // 配网
        case dataModel           // 数据模型（属性/命令/事件）
        case protocolSession = "protocol"   // 协议会话
        case network             // 网络/发现
        case system              // 系统/生命周期
    }

    /// 事件级别
    enum Level: String, CaseIterable, Sendable {
        case debug
        case info
        case warning
        case error

        /// 严重度排序（用于「最低级别」过滤：debug < info < warning < error）。
        var rank: Int {
            switch self {
            case .debug: 0
            case .info: 1
            case .warning: 2
            case .error: 3
            }
        }
    }

    let id: UUID
    let timestamp: Date
    let category: Category
    let level: Level
    let nodeID: UInt64?
    let endpointID: UInt16?
    let message: String
    let detail: [String: String]?
    let errorCode: Int?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        category: Category,
        level: Level,
        nodeID: UInt64? = nil,
        endpointID: UInt16? = nil,
        message: String,
        detail: [String: String]? = nil,
        errorCode: Int? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.level = level
        self.nodeID = nodeID
        self.endpointID = endpointID
        self.message = message
        self.detail = detail
        self.errorCode = errorCode
    }
}

extension MatterEvent.Category {
    /// 界面展示用的中文名（原始值仍是英文，导出时保持原样）。
    var label: String {
        switch self {
        case .commissioning: "配网"
        case .dataModel: "数据模型"
        case .protocolSession: "协议会话"
        case .network: "网络"
        case .system: "系统"
        }
    }
}

extension MatterEvent.Level {
    /// 界面展示用的中文名。
    var label: String {
        switch self {
        case .debug: "调试"
        case .info: "信息"
        case .warning: "警告"
        case .error: "错误"
        }
    }
}
