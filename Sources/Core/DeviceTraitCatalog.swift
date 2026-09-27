import Foundation

// MARK: - 特征模型

/// 特征类别：只读读数 或 可控状态。
enum DeviceTraitKind: String, Sendable {
    case reading
    case control
}

/// 设备特征：面向展示的单元，与 Matter 属性为一对多关系。
/// 与 `ControlCapability` 分离——后者语义为「可控能力」，驱动控制命令与控件；特征只描述「这是什么、现在读数是多少」，
/// 并可选携带一个可交互能力（`controlCapability`）。传感器不可控，混入 `ControlCapability` 会污染控制页能力判定。
enum DeviceTrait: String, CaseIterable, Identifiable, Sendable {
    case temperature
    case humidity
    case pm25
    case co2
    case airQuality
    case illuminance
    case occupancy
    case booleanState
    case onOff
    case brightness
    case colorTemperature
    case windowCovering

    var id: String { rawValue }

    /// 特征对应的服务器集群 ID。
    var clusterID: UInt32 {
        switch self {
        case .temperature: 0x0402
        case .humidity: 0x0405
        case .pm25: 0x042A
        case .co2: 0x040D
        case .airQuality: 0x005B
        case .illuminance: 0x0400
        case .occupancy: 0x0406
        case .booleanState: 0x0045
        case .onOff: 0x06
        case .brightness: 0x08
        case .colorTemperature: 0x0300
        case .windowCovering: 0x0102
        }
    }

    /// 需要读取的属性（主属性在前）。
    var attributeKeys: [ControlAttributeKey] {
        switch self {
        case .brightness:
            [
                ControlAttributeKey(clusterID: 0x08, attributeID: 0x0000),
                ControlAttributeKey(clusterID: 0x08, attributeID: 0x0002),
                ControlAttributeKey(clusterID: 0x08, attributeID: 0x0003),
            ]
        case .colorTemperature:
            [
                ControlAttributeKey(clusterID: 0x0300, attributeID: 0x0007),
                ControlAttributeKey(clusterID: 0x0300, attributeID: 0x4001),
                ControlAttributeKey(clusterID: 0x0300, attributeID: 0x4002),
            ]
        case .windowCovering:
            [
                ControlAttributeKey(clusterID: 0x0102, attributeID: 0x000E),
                ControlAttributeKey(clusterID: 0x0102, attributeID: 0x000A),
            ]
        default:
            [ControlAttributeKey(clusterID: clusterID, attributeID: 0x0000)]
        }
    }

    /// 主属性（决定展示读数）。
    var primaryKey: ControlAttributeKey { attributeKeys[0] }

    /// 可交互能力（非 nil 即详情页卡片内嵌控件）。
    var controlCapability: ControlCapability? {
        switch self {
        case .onOff: .onOff
        case .brightness: .brightness
        case .colorTemperature: .colorTemperature
        case .windowCovering: .windowCovering
        case .temperature, .humidity, .pm25, .co2, .airQuality, .illuminance, .occupancy, .booleanState: nil
        }
    }

    var kind: DeviceTraitKind {
        controlCapability == nil ? .reading : .control
    }

    var title: String {
        switch self {
        case .temperature: "温度"
        case .humidity: "湿度"
        case .pm25: "PM2.5"
        case .co2: "CO₂"
        case .airQuality: "空气质量"
        case .illuminance: "照度"
        case .occupancy: "占用"
        case .booleanState: "状态"
        case .onOff: "开关"
        case .brightness: "亮度"
        case .colorTemperature: "色温"
        case .windowCovering: "开合位置"
        }
    }

    var systemImage: String {
        switch self {
        case .temperature: "thermometer.medium"
        case .humidity: "humidity"
        case .pm25: "smoke.fill"
        case .co2: "carbon.dioxide.cloud.fill"
        case .airQuality: "wind"
        case .illuminance: "sun.max"
        case .occupancy: "person.fill"
        case .booleanState: "sensor.tag"
        case .onOff: "power"
        case .brightness: "sun.max"
        case .colorTemperature: "thermometer.sun"
        case .windowCovering: "blinds.horizontal"
        }
    }

    /// 展示优先级：读数在控制状态之前，数值越小越靠前。
    var listPriority: Int {
        switch self {
        case .temperature: 0
        case .humidity: 1
        case .pm25: 2
        case .co2: 3
        case .airQuality: 4
        case .illuminance: 5
        case .occupancy: 6
        case .booleanState: 7
        case .onOff: 8
        case .brightness: 9
        case .colorTemperature: 10
        case .windowCovering: 11
        }
    }
}

// MARK: - 目录

/// 设备特征目录：集群 ↔ 特征映射与读数格式化。
/// `reading(_:values:endpointID:)` 为纯函数，便于用 `#Preview` 覆盖哨兵值 / null 等边界。
enum DeviceTraitCatalog {

    /// 集群 ID → 特征。
    static let traitForCluster: [UInt32: DeviceTrait] = Dictionary(
        uniqueKeysWithValues: DeviceTrait.allCases.map { ($0.clusterID, $0) }
    )

    /// 由端点 ServerList 推导特征列表（读数在前，其次按展示优先级）。
    static func traits(from clusterIDs: [UInt32]) -> [DeviceTrait] {
        let found = Set(clusterIDs.compactMap { traitForCluster[$0] })
        return DeviceTrait.allCases
            .filter { found.contains($0) }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind == .reading }
                return lhs.listPriority < rhs.listPriority
            }
    }

    /// 把原始属性值转成展示读数。
    /// 降级规则：`.null` / `.unsupported` / 数值哨兵（温度 0x8000、PM2.5 与 CO₂ 0xFFFF、照度 0、占用 0xFF）→ 无有效读数。
    static func reading(
        _ trait: DeviceTrait,
        values: [ControlAttributeKey: MatterScalar],
        endpointID: UInt16
    ) -> TraitReading {
        let scalar = values[trait.primaryKey]
        let number = scalar?.numberValue
        let raw = rawText(scalar)

        func make(_ text: String, available: Bool = true) -> TraitReading {
            TraitReading(
                trait: trait, endpointID: endpointID,
                text: text, rawText: raw, isAvailable: available
            )
        }
        func missing() -> TraitReading { make("—", available: false) }

        switch trait {
        case .temperature:
            guard let value = number, value != -32768 else { return missing() }
            return make(String(format: "%.1f ℃", value / 100))

        case .humidity:
            guard let value = number, value != -32768 else { return missing() }
            return make(String(format: "%.0f%%", value / 100))

        case .pm25:
            guard let value = number, value != 65535 else { return missing() }
            return make(String(format: "%.0f µg/m³", value))

        case .co2:
            guard let value = number, value != 65535 else { return missing() }
            return make(String(format: "%.0f ppm", value))

        case .airQuality:
            let names = ["未知", "优", "良", "中", "差", "很差", "极差"]
            guard let value = number else { return missing() }
            let index = Int(value)
            guard index >= 0, index < names.count else { return missing() }
            return make(names[index], available: index != 0)

        case .illuminance:
            guard let value = number, value > 0 else {
                // MeasuredValue == 0 为规范定义「过暗无法测量」，非有效读数但不显示「—」。
                return number == 0 ? make("过暗", available: false) : missing()
            }
            let lux = pow(10, value / 10_000)
            let text = lux > 1000
                ? String(format: "%.1f klx", lux / 1000)
                : String(format: "%.0f lx", lux)
            return make(text)

        case .occupancy:
            guard let value = number, value != 255 else { return missing() }
            return make(Int(value) & 0x01 == 1 ? "有人" : "无人")

        case .booleanState, .onOff:
            guard let flag = scalar?.boolValue ?? number.map({ $0 != 0 }) else { return missing() }
            return make(flag ? "开" : "关")

        case .brightness:
            guard let level = number else { return missing() }
            return make(String(format: "%.0f%%", DeviceControlCatalog.percent(fromLevel: level)))

        case .colorTemperature:
            guard let mireds = number, let kelvin = DeviceControlCatalog.kelvin(fromMireds: mireds) else {
                return missing()
            }
            return make(String(format: "%d K", kelvin))

        case .windowCovering:
            guard let value = number else { return missing() }
            return make(String(format: "%.0f%%", value / 100))
        }
    }

    /// 原始值文本（调试 / 详情页原始值展示用）。
    static func rawText(_ scalar: MatterScalar?) -> String {
        guard let scalar else { return "" }
        switch scalar {
        case .number(let value):
            return value == value.rounded()
                ? String(format: "%.0f", value)
                : String(format: "%g", value)
        case .bool(let value): return value ? "true" : "false"
        case .string(let value): return value
        case .bytes(let value): return value
        case .null: return "null"
        case .array, .structure, .unsupported: return ""
        }
    }
}