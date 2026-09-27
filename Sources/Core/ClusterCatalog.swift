import Foundation

/// 常见 Matter 集群 / 属性目录（hex → 名称），供集群工具展示与解析。
/// 未收录的 ID 一律回退为格式化十六进制，避免误导。
enum ClusterCatalog {

    /// 集群 ID → 名称。
    static let clusters: [UInt32: String] = [
        // 核心 & 通用
        0x1D: "Descriptor",
        0x28: "Basic Information",
        0x30: "General Commissioning",
        0x31: "Network Commissioning",
        0x33: "General Diagnostics",
        0x35: "Thread Network Diagnostics",
        0x36: "Wi-Fi Network Diagnostics",
        0x3C: "Administrator Commissioning",
        0x3E: "Operational Credentials",
        0x39: "Bridged Device Basic",
        0x000F: "Time",
        0x29: "OTA Software Update Provider",
        0x2A: "OTA Software Update Requestor",
        0x2B: "Localization Configuration",
        // 功能
        0x04: "Groups",
        0x05: "Scenes",
        0x03: "Identify",
        0x06: "On/Off",
        0x08: "Level Control",
        0x0300: "Color Control",
        0x0102: "Window Covering",
        // 传感器
        0x0045: "Boolean State",
        0x005B: "Air Quality",
        0x0400: "Illuminance Measurement",
        0x0402: "Temperature Measurement",
        0x0405: "Relative Humidity",
        0x0406: "Occupancy Sensing",
        0x040D: "Carbon Dioxide Concentration Measurement",
        0x042A: "PM2.5 Concentration Measurement",
        // 电源
        0x002F: "Power Source",
    ]

    /// 全局属性（适用于所有集群）。
    static let globalAttributes: [UInt32: String] = [
        0xFFFD: "ClusterRevision",
        0xFFFC: "FeatureMap",
        0xFFFB: "AttributeList",
        0xFFFA: "EventList",
        0xFFF9: "AcceptedCommandList",
        0xFFF8: "GeneratedCommandList",
    ]

    /// 各集群常见属性（属性 ID → 名称）。
    static let clusterAttributes: [UInt32: [UInt32: String]] = [
        0x1D: [
            0: "DeviceTypeList",
            1: "ServerList",
            2: "ClientList",
            3: "PartsList",
        ],
        0x28: [
            0: "DataModelRevision",
            1: "VendorName",
            2: "VendorID",
            3: "ProductName",
            4: "ProductID",
            5: "NodeLabel",
            6: "Location",
            7: "HardwareVersion",
            8: "HardwareVersionString",
            9: "SoftwareVersion",
            10: "SoftwareVersionString",
            11: "ManufacturingDate",
            12: "PartNumber",
            13: "ProductURL",
            14: "ProductLabel",
            15: "SerialNumber",
            16: "LocalConfigDisabled",
            17: "Reachable",
            18: "UniqueID",
            19: "CapabilityMinima",
        ],
        0x2A: [
            0: "DefaultOTAProviders",
            1: "UpdatePossible",
            2: "UpdateState",
            3: "UpdateStateProgress",
        ],
        0x30: [
            0: "BasicCommissioningInfo",
            1: "RegulatoryConfig",
            2: "LocationCapability",
            3: "SupportsConcurrentConnection",
            4: "TLSVersion",
        ],
        0x31: [
            0: "MaxNetworks",
            1: "Networks",
            2: "ScanNetworks",
            3: "InterfaceEnabled",
            4: "LastNetworkingStatus",
            5: "LastNetworkID",
            6: "LastConnectErrorValue",
        ],
        0x3E: [
            0: "Fabrics",
        ],
        0x2F: [
            0: "Status",
            1: "Order",
            2: "Description",
            0x0B: "BatVoltage",
            0x0C: "BatPercentRemaining",
            0x0D: "BatTimeRemaining",
            0x0E: "BatChargeLevel",
            0x0F: "BatReplacementNeeded",
            0x10: "BatReplaceability",
            0x11: "BatPresent",
            0x12: "ActiveBatFaults",
            0x13: "BatReplacementDescription",
        ],
        0x06: [
            0: "OnOff",
            1: "GlobalSceneControl",
            2: "OnTime",
            3: "OffWaitTime",
            0x4000: "StartUpOnOff",
        ],
        0x08: [
            0: "CurrentLevel",
            1: "OnLevel",
            2: "Options",
            0x4000: "OnOffTransitionTime",
            0x4001: "OnTransitionTime",
            0x4002: "OffTransitionTime",
            0x4003: "DefaultMoveRate",
        ],
        0x0300: [
            0: "CurrentHue",
            1: "CurrentSaturation",
            2: "CurrentX",
            3: "CurrentY",
            4: "EnhancedCurrentHue",
            5: "EnhancedColorMode",
            6: "ColorLoopActive",
            7: "ColorTemperatureMireds",
            0x4000: "ColorCapabilities",
            0x4001: "ColorTempPhysicalMinMireds",
            0x4002: "ColorTempPhysicalMaxMireds",
        ],
        0x0402: [
            0: "MeasuredValue",
            1: "MinMeasuredValue",
            2: "MaxMeasuredValue",
            3: "Tolerance",
        ],
        0x0405: [
            0: "MeasuredValue",
            1: "MinMeasuredValue",
            2: "MaxMeasuredValue",
            3: "Tolerance",
        ],
        0x0406: [
            0: "Occupancy",
            1: "OccupancySensorType",
            2: "OccupancySensorTypeBitmap",
        ],
        0x0045: [
            0: "StateValue",
        ],
        0x005B: [
            0: "AirQuality",
        ],
        0x0400: [
            0: "MeasuredValue",
            1: "MinMeasuredValue",
            2: "MaxMeasuredValue",
            3: "Tolerance",
            4: "LightSensorType",
        ],
        0x040D: [
            0: "MeasuredValue",
            1: "MinMeasuredValue",
            2: "MaxMeasuredValue",
            3: "Tolerance",
        ],
        0x042A: [
            0: "MeasuredValue",
            1: "MinMeasuredValue",
            2: "MaxMeasuredValue",
            3: "Tolerance",
        ],
    ]

    /// 集群名称（未知回退十六进制）。
    static func clusterName(_ id: UInt32) -> String {
        clusters[id] ?? MatterHex.hex(id)
    }

    /// 属性名称：优先集群特有属性，其次全局属性，最后十六进制。
    static func attributeName(clusterID: UInt32, attributeID: UInt32) -> String {
        if let name = clusterAttributes[clusterID]?[attributeID] { return name }
        if let name = globalAttributes[attributeID] { return name }
        return MatterHex.hex(attributeID)
    }
}
