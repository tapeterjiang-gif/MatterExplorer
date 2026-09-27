import Foundation

// MARK: - 可控能力

/// 可控能力：由设备端点实际支持的服务器集群决定，控制面板据此自动生成控件。
enum ControlCapability: String, CaseIterable, Identifiable, Sendable {
    case onOff
    case identify
    case brightness
    case colorTemperature
    case windowCovering

    var id: String { rawValue }

    /// 能力对应的服务器集群 ID。
    var clusterID: UInt32 {
        switch self {
        case .onOff: 0x06
        case .identify: 0x03
        case .brightness: 0x08
        case .colorTemperature: 0x0300
        case .windowCovering: 0x0102
        }
    }

    var title: String {
        switch self {
        case .onOff: "开关"
        case .identify: "识别闪烁"
        case .brightness: "亮度"
        case .colorTemperature: "色温"
        case .windowCovering: "开合位置"
        }
    }

    var systemImage: String {
        switch self {
        case .onOff: "power"
        case .identify: "light.beacon.max"
        case .brightness: "sun.max"
        case .colorTemperature: "thermometer.medium"
        case .windowCovering: "rectangle.split.3x1"
        }
    }
}

/// 控制状态属性定位（集群 + 属性），控制面板按此读取与订阅。
struct ControlAttributeKey: Hashable, Sendable {
    let clusterID: UInt32
    let attributeID: UInt32
}

/// 端点 + 属性定位（订阅兴趣路径需要端点信息）。
struct ControlAttributePath: Hashable, Sendable {
    let endpointID: UInt16
    let key: ControlAttributeKey
}

// MARK: - 目录

/// 设备控制目录：能力 ↔ 集群映射、状态属性、命令 ID 与取值换算。
/// 未收录的集群不生成控件，避免给出误导性的操作入口。
enum DeviceControlCatalog {

    /// 集群 ID → 能力（判定依据：端点 ServerList 是否包含该集群）。
    static let capabilityForCluster: [UInt32: ControlCapability] = [
        0x03: .identify,
        0x06: .onOff,
        0x08: .brightness,
        0x0300: .colorTemperature,
        0x0102: .windowCovering,
    ]

    /// 能力 → 需要读取的状态属性（顺序即展示顺序）。
    static let stateAttributes: [ControlCapability: [ControlAttributeKey]] = [
        .onOff: [
            ControlAttributeKey(clusterID: 0x06, attributeID: 0x0000),
        ],
        .identify: [
            ControlAttributeKey(clusterID: 0x03, attributeID: 0x0000),
        ],
        .brightness: [
            ControlAttributeKey(clusterID: 0x08, attributeID: 0x0000),
            ControlAttributeKey(clusterID: 0x08, attributeID: 0x0002),
            ControlAttributeKey(clusterID: 0x08, attributeID: 0x0003),
        ],
        .colorTemperature: [
            ControlAttributeKey(clusterID: 0x0300, attributeID: 0x0007),
            ControlAttributeKey(clusterID: 0x0300, attributeID: 0x4001),
            ControlAttributeKey(clusterID: 0x0300, attributeID: 0x4002),
        ],
        .windowCovering: [
            ControlAttributeKey(clusterID: 0x0102, attributeID: 0x000E),
            ControlAttributeKey(clusterID: 0x0102, attributeID: 0x000A),
        ],
    ]

    /// 控制面板按能力顺序展示。
    static func capabilities(from clusterIDs: [UInt32]) -> [ControlCapability] {
        let found = Set(clusterIDs.compactMap { capabilityForCluster[$0] })
        return ControlCapability.allCases.filter { found.contains($0) }
    }

    /// 属性名称（用于状态原始值展示）。
    static func attributeName(_ key: ControlAttributeKey) -> String {
        switch (key.clusterID, key.attributeID) {
        case (0x03, 0x0000): "IdentifyTime"
        case (0x06, 0x0000): "OnOff"
        case (0x08, 0x0000): "CurrentLevel"
        case (0x08, 0x0002): "MinLevel"
        case (0x08, 0x0003): "MaxLevel"
        case (0x0300, 0x0007): "ColorTemperatureMireds"
        case (0x0102, 0x000A): "OperationalStatus"
        case (0x0102, 0x000E): "CurrentPositionLiftPercent100ths"
        default: ClusterCatalog.attributeName(clusterID: key.clusterID, attributeID: key.attributeID)
        }
    }

    // MARK: - 命令 ID

    /// On/Off 集群命令（Off / On / Toggle，均无字段）。
    static let commandOff: UInt32 = 0x00
    static let commandOn: UInt32 = 0x01
    static let commandToggle: UInt32 = 0x02
    /// Identify 集群 Identify 命令（字段 0：identifyTime 秒）。
    static let commandIdentify: UInt32 = 0x00
    /// Level Control MoveToLevelWithOnOff（字段 0：level、1：transitionTime、2/3：optionsMask/Override）。
    static let commandMoveToLevelWithOnOff: UInt32 = 0x04
    /// Color Control MoveToColorTemperature（字段同 MoveToLevelWithOnOff）。
    static let commandMoveToColorTemperature: UInt32 = 0x0A
    /// Window Covering GoToLiftPercentage（字段 0：liftPercent100ths）。
    static let commandGoToLiftPercentage: UInt32 = 0x05

    // MARK: - 取值换算与默认区间

    /// 亮度默认区间（MinLevel / MaxLevel 读取失败时的兜底）。
    static let defaultLevelRange: ClosedRange<Double> = 0...254
    /// 色温默认区间（mireds，读取失败时的兜底）。
    static let defaultMiredsRange: ClosedRange<Double> = 153...500

    /// 亮度百分比（0–100）→ Matter 等级（0–254）。
    static func level(fromPercent percent: Double) -> UInt8 {
        let raw = (percent / 100 * 254).rounded()
        return UInt8(min(max(raw, 0), 254))
    }

    /// Matter 等级（0–254）→ 亮度百分比（0–100）。
    static func percent(fromLevel level: Double) -> Double {
        (min(max(level, 0), 254) / 254 * 100).rounded()
    }

    /// 位置百分比（0–100）→ Percent100ths（0–10000）。
    static func percent100ths(fromPercent percent: Double) -> UInt16 {
        UInt16(min(max((percent * 100).rounded(), 0), 10000))
    }

    /// mireds → 开尔文（信息性展示）。
    static func kelvin(fromMireds mireds: Double) -> Int? {
        guard mireds > 0 else { return nil }
        return Int((1_000_000 / mireds).rounded())
    }
}