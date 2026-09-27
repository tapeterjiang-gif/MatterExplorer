import Foundation
import Matter

// MARK: - 类型化值

/// Matter 属性值的类型化快照（跨线程安全，替代原始字典传递）。
/// 用于需要按属性 ID 取值（而非仅展示 JSON）的场景，如设备基本信息读取。
enum MatterScalar: Sendable, Equatable {
    case string(String)
    case bool(Bool)
    case number(Double)
    /// 字节串（十六进制字符串表示）。
    case bytes(String)
    case null
    case array([MatterScalar])
    /// 结构体：上下文标签 → 值（标签即字段顺序）。
    case structure([UInt32: MatterScalar])
    case unsupported(String)

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    /// 数值属性转 UInt32（VID / PID / 版本号等）。
    var uintValue: UInt32? {
        guard let value = numberValue, value >= 0, value <= Double(UInt32.max) else { return nil }
        return UInt32(value)
    }

    var bytesValue: String? {
        if case .bytes(let value) = self { return value }
        return nil
    }

    var arrayValue: [MatterScalar]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var structureValue: [UInt32: MatterScalar]? {
        if case .structure(let value) = self { return value }
        return nil
    }
}

// MARK: - 编解码

/// Matter 属性值编解码：读结果 JSON → MatterScalar、用户输入 JSON → Matter 数据值、响应值 → 可读 JSON。
/// 全部为纯函数、无实例状态，与 ClusterToolService 的读 / 写 / 订阅编排无关，
/// 故独立成层，供集群工具、设备控制、设备管理共用。
enum MatterValueCodec {
    // MARK: - 值解析

    /// 读结果 → 「属性 ID → 类型化值」。
    static func scalars(from values: [[String: Any]]) -> [UInt32: MatterScalar] {
        var result: [UInt32: MatterScalar] = [:]
        for dict in values {
            guard let path = dict[MTRAttributePathKey] as? MTRAttributePath,
                  let dataValue = dict[MTRDataKey] as? [String: Any] else { continue }
            result[path.attribute.uint32Value] = scalar(from: dataValue)
        }
        return result
    }

    /// 单个数据值字典 → MatterScalar。
    static func scalar(from dataValue: [String: Any]) -> MatterScalar {
        guard let type = dataValue[MTRTypeKey] as? String else { return .unsupported("缺少类型") }
        let raw = dataValue[MTRValueKey]
        switch type {
        case MTRBooleanValueType:
            return .bool((raw as? NSNumber)?.boolValue ?? false)
        case MTRUnsignedIntegerValueType, MTRSignedIntegerValueType, MTRFloatValueType, MTRDoubleValueType:
            return .number((raw as? NSNumber)?.doubleValue ?? 0)
        case MTRUTF8StringValueType:
            return .string(raw as? String ?? "")
        case MTROctetStringValueType:
            return .bytes((raw as? Data)?.hexString ?? "")
        case MTRNullValueType:
            return .null
        case MTRArrayValueType:
            let elements = (raw as? [Any]) ?? []
            return .array(elements.compactMap { element in
                guard let inner = element as? [String: Any],
                      let value = inner[MTRDataKey] as? [String: Any] else { return nil }
                return scalar(from: value)
            })
        case MTRStructureValueType:
            var fields: [UInt32: MatterScalar] = [:]
            for element in (raw as? [Any]) ?? [] {
                guard let inner = element as? [String: Any],
                      let tag = inner[MTRContextTagKey] as? NSNumber,
                      let value = inner[MTRDataKey] as? [String: Any] else { continue }
                fields[tag.uint32Value] = scalar(from: value)
            }
            return .structure(fields)
        default:
            return .unsupported(type)
        }
    }

    // MARK: - 数据值构造（写 / 命令输入）

    /// 将用户输入的 JSON 值转换为 Matter 数据值字典（{MTRTypeKey, MTRValueKey}）。
    /// 字符串优先按偶数位 hex 解析为 octet string，否则按 UTF-8 字符串处理。
    static func makeDataValue(from json: Any) -> [String: Any]? {
        switch json {
        case let bool as Bool:
            return [MTRTypeKey: MTRBooleanValueType, MTRValueKey: bool]
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return [MTRTypeKey: MTRBooleanValueType, MTRValueKey: number.boolValue]
        case let number as NSNumber where number.doubleValue != number.doubleValue.rounded():
            return [MTRTypeKey: MTRDoubleValueType, MTRValueKey: number]
        case let number as NSNumber:
            if number.int64Value < 0 {
                return [MTRTypeKey: MTRSignedIntegerValueType, MTRValueKey: number]
            }
            return [MTRTypeKey: MTRUnsignedIntegerValueType, MTRValueKey: number]
        case let string as String:
            if let octets = Data(hexString: string) {
                return [MTRTypeKey: MTROctetStringValueType, MTRValueKey: octets]
            }
            return [MTRTypeKey: MTRUTF8StringValueType, MTRValueKey: string]
        case is NSNull:
            return [MTRTypeKey: MTRNullValueType]
        case let array as [Any]:
            let elements = array.compactMap { makeDataValue(from: $0) }
            guard elements.count == array.count else { return nil }
            return [MTRTypeKey: MTRArrayValueType, MTRValueKey: elements]
        case let dict as [String: Any]:
            return makeStructureDataValue(from: dict)
        default:
            return nil
        }
    }

    /// 结构体数据值：{"标签或上下文标签": 值} → {MTRTypeKey: MTRStructureValueType, MTRValueKey: [{MTRContextTagKey, MTRDataKey}]}。
    private static func makeStructureDataValue(from dict: [String: Any]) -> [String: Any]? {
        var fields: [[String: Any]] = []
        for (key, value) in dict {
            let tag: UInt32
            if key.lowercased().hasPrefix("0x"), let parsed = UInt32(key.dropFirst(2), radix: 16) {
                tag = parsed
            } else if let parsed = UInt32(key) {
                tag = parsed
            } else {
                return nil
            }
            guard let dataValue = makeDataValue(from: value) else { return nil }
            fields.append([MTRContextTagKey: NSNumber(value: tag), MTRDataKey: dataValue])
        }
        return [MTRTypeKey: MTRStructureValueType, MTRValueKey: fields]
    }

    // MARK: - JSON 处理

    /// 将响应值数组序列化为可读 JSON（NSData → hex，字典键排序）。
    static func prettyJSON(from values: [[String: Any]]) -> String {
        let converted = values.map { jsonCompatible($0) }
        guard let data = try? JSONSerialization.data(withJSONObject: converted, options: [.prettyPrinted, .sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "（无法序列化）"
        }
        return string
    }

    /// 递归转换非 JSON 类型：NSData → hex、NSDate → 时间戳、MTR 路径对象 → 可读字符串，其余原样。
    static func jsonCompatible(_ value: Any) -> Any {
        switch value {
        case let data as Data:
            return data.hexString
        case let dict as NSDictionary:
            var result: [String: Any] = [:]
            for (key, element) in dict {
                result[String(describing: key)] = jsonCompatible(element)
            }
            return result
        case let array as NSArray:
            return array.map { jsonCompatible($0) }
        case let date as Date:
            return date.timeIntervalSince1970
        case let attributePath as MTRAttributePath:
            return "端点 \(attributePath.endpoint.uint16Value) / 集群 \(MatterHex.hex(attributePath.cluster.uint32Value)) / 属性 \(MatterHex.hex(attributePath.attribute.uint32Value))"
        case let eventPath as MTREventPath:
            return "端点 \(eventPath.endpoint.uint16Value) / 集群 \(MatterHex.hex(eventPath.cluster.uint32Value)) / 事件 \(MatterHex.hex(eventPath.event.uint32Value))"
        case let commandPath as MTRCommandPath:
            return "端点 \(commandPath.endpoint.uint16Value) / 集群 \(MatterHex.hex(commandPath.cluster.uint32Value)) / 命令 \(MatterHex.hex(commandPath.command.uint32Value))"
        case let error as NSError:
            return "错误：\(MatterErrorDictionary.description(for: error))"
        case is NSNull:
            return NSNull()
        default:
            return value
        }
    }

    // MARK: - 数组提取

    /// 从读结果 JSON 中提取数值数组（MTRArrayValueType 的元素或单个数值）。
    static func extractNumberArray(from json: String?) -> [NSNumber] {
        guard let json,
              let data = json.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data),
              let responses = top as? [[String: Any]] else {
            return []
        }
        var numbers: [NSNumber] = []
        for dict in responses {
            guard let dataValue = dict[MTRDataKey] as? [String: Any] else { continue }
            guard let type = dataValue[MTRTypeKey] as? String else { continue }
            if type == MTRArrayValueType,
               let elements = dataValue[MTRValueKey] as? [Any] {
                for element in elements {
                    if let inner = element as? [String: Any],
                       let value = inner[MTRDataKey] as? [String: Any],
                       let number = value[MTRValueKey] as? NSNumber {
                        numbers.append(number)
                    }
                }
            } else if let number = dataValue[MTRValueKey] as? NSNumber {
                numbers.append(number)
            }
        }
        return numbers
    }

    /// 从 `Descriptor.DeviceTypeList`（0x1D / 属性 0）的读结果中提取设备类型 ID。
    /// 该属性是**结构体数组**（每个结构体的上下文标签 0 为 deviceType、1 为 revision），
    /// 所以不能用 `extractNumberArray`（那是给纯数值数组用的）。
    static func deviceTypeIDs(from scalar: MatterScalar?) -> [UInt32] {
        guard let elements = scalar?.arrayValue else { return [] }
        return elements.compactMap { $0.structureValue?[0]?.uintValue }
    }
}