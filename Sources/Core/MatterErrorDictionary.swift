import Foundation
import Matter

/// Matter 错误码词典：把框架抛出的 `NSError`（域 + 码值）映射为中文说明与排查建议。
///
/// 覆盖范围严格取自 iOS SDK 头文件，避免臆造：
/// - `MTRErrorDomain`：Matter.framework 自身的数据处理 / 映射错误（MTRError.h）
/// - `MTRInteractionErrorDomain`：对端返回的 Matter 状态（Interaction Model 通用状态码表）
///
/// 集群专属状态码（如 NetworkCommissioning / OperationalCredentials）在对应操作日志中以中文标注，
/// 不在此词典内，避免与规范版本产生偏差。
enum MatterErrorDictionary {

    // MARK: - 分组

    enum Scope: String, CaseIterable, Sendable {
        case matter
        case interaction

        var title: String {
            switch self {
            case .matter: "框架错误（MTRErrorDomain）"
            case .interaction: "交互状态（MTRInteractionErrorDomain）"
            }
        }

        var footnote: String {
            switch self {
            case .matter: "Matter.framework 自身在处理数据、参数或映射状态时产生的错误。"
            case .interaction: "设备端返回的 Matter 通用状态码（Interaction Model 状态表）。"
            }
        }

        /// 码值展示进制：框架错误用十进制（与 SDK 枚举一致），交互状态用十六进制。
        var codeIsHex: Bool { self == .interaction }
    }

    // MARK: - 条目

    struct Entry: Identifiable, Hashable, Sendable {
        let scope: Scope
        let code: Int
        /// 规范中的英文名（去掉 API 前缀，便于对照规范 / 固件日志）。
        let name: String
        /// 中文说明。
        let summary: String
        /// 排查建议（可为空）。
        let suggestion: String

        var id: String { "\(scope.rawValue)-\(code)" }

        var codeText: String {
            scope.codeIsHex ? MatterHex.hex(code, width: 2) : "\(code)"
        }

        /// 单行完整描述：中文说明 + 排查建议。
        var text: String {
            suggestion.isEmpty ? summary : "\(summary)（\(suggestion)）"
        }
    }

    // MARK: - 查表

    static func entry(scope: Scope, code: Int) -> Entry? {
        table.first { $0.scope == scope && $0.code == code }
    }

    /// 由 NSError 域字符串查条目（域不匹配时返回 nil）。
    static func entry(forDomain domain: String, code: Int) -> Entry? {
        switch domain {
        case MTRErrorDomain: return entry(scope: .matter, code: code)
        case MTRInteractionErrorDomain: return entry(scope: .interaction, code: code)
        default: return nil
        }
    }

    /// 中文单行描述；未知码值回退为「域 + 码值」。
    static func description(for error: Error) -> String {
        let ns = error as NSError
        if let entry = entry(forDomain: ns.domain, code: ns.code) {
            return entry.text
        }
        if ns.domain == MTRInteractionErrorDomain {
            return "交互状态 \(MatterHex.hex(ns.code, width: 2))（未收录）"
        }
        if ns.domain == MTRErrorDomain {
            return "Matter 框架错误 \(ns.code)（未收录）"
        }
        return ns.localizedDescription
    }

    /// 已收录条目的全部内容，按分组顺序排列。
    static func allEntries() -> [Entry] { table }

    /// 关键字过滤（码值 / 英文名 / 中文说明）。
    static func search(_ keyword: String) -> [Entry] {
        let trimmed = keyword.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return table }
        let lower = trimmed.lowercased()
        let normalized = lower.hasPrefix("0x") ? String(lower.dropFirst(2)) : lower
        return table.filter { entry in
            entry.name.lowercased().contains(lower)
                || entry.summary.contains(trimmed)
                || entry.suggestion.contains(trimmed)
                || entry.codeText.lowercased().contains(lower)
                || entry.codeText.lowercased().contains(normalized)
        }
    }

    // MARK: - 表内容

    private static let table: [Entry] = matterEntries + interactionEntries

    private static let matterEntries: [Entry] = [
        Entry(scope: .matter, code: 1, name: "GeneralError", summary: "通用 Matter 错误", suggestion: "查看日志 detail 中的底层 Matter 错误码定位"),
        Entry(scope: .matter, code: 2, name: "InvalidStringLength", summary: "字符串长度无效", suggestion: "检查字符串参数长度是否符合规范（如 SSID、fabric 标签）"),
        Entry(scope: .matter, code: 3, name: "InvalidIntegerValue", summary: "整数值无效", suggestion: "检查取值范围（如 discriminator、nodeID 是否越界）"),
        Entry(scope: .matter, code: 4, name: "InvalidArgument", summary: "参数无效", suggestion: "检查 Setup Payload / 参数格式，重新扫码或手动输入"),
        Entry(scope: .matter, code: 5, name: "InvalidMessageLength", summary: "消息长度无效", suggestion: "多发生在解码阶段，确认设备固件与控制器版本兼容"),
        Entry(scope: .matter, code: 6, name: "InvalidState", summary: "状态无效", suggestion: "控制器可能未就绪，等待启动完成后重试"),
        Entry(scope: .matter, code: 7, name: "WrongAddressType", summary: "地址类型错误", suggestion: "DNS-SD 解析结果与预期不符，检查设备广播与网络环境"),
        Entry(scope: .matter, code: 8, name: "IntegrityCheckFailed", summary: "完整性校验失败", suggestion: "报文可能损坏，确认网络稳定后重试"),
        Entry(scope: .matter, code: 9, name: "Timeout", summary: "超时：设备未响应", suggestion: "确认设备处于配网/在线状态且信号良好，必要时重新上电"),
        Entry(scope: .matter, code: 10, name: "BufferTooSmall", summary: "缓冲区不足", suggestion: "内部错误，通常与报文过大有关，记录日志反馈"),
        Entry(scope: .matter, code: 11, name: "FabricExists", summary: "该设备已加入当前 fabric", suggestion: "无需重复配网；需重新配网请在设备端恢复出厂，或先移除设备上的本 fabric"),
        Entry(scope: .matter, code: 12, name: "UnknownSchema", summary: "未知的集群 / 属性 / 命令结构", suggestion: "确认路径 ID 与 SDK 版本是否支持该集群"),
        Entry(scope: .matter, code: 13, name: "SchemaMismatch", summary: "数据与预期结构不匹配", suggestion: "设备返回结构与规范不符，核对设备固件实现"),
        Entry(scope: .matter, code: 14, name: "TLVDecodeFailed", summary: "TLV 解码失败", suggestion: "报文格式异常，确认设备实现符合规范"),
        Entry(scope: .matter, code: 15, name: "DNSSDUnauthorized", summary: "DNS-SD 未授权", suggestion: "检查 Info.plist 的 NSBonjourServices 与本地网络权限"),
        Entry(scope: .matter, code: 16, name: "Cancelled", summary: "操作已取消", suggestion: "由调用方主动取消，通常无需处理"),
        Entry(scope: .matter, code: 17, name: "AccessDenied", summary: "访问被拒绝", suggestion: "检查本地网络 / 蓝牙权限是否已授予"),
        Entry(scope: .matter, code: 18, name: "Busy", summary: "设备忙", suggestion: "稍后重试"),
        Entry(scope: .matter, code: 19, name: "NotFound", summary: "找不到设备", suggestion: "确认设备在附近且处于配网模式；已配网设备确认在线"),
    ]

    private static let interactionEntries: [Entry] = [
        Entry(scope: .interaction, code: 0x00, name: "Success", summary: "成功", suggestion: ""),
        Entry(scope: .interaction, code: 0x01, name: "Failure", summary: "操作失败（通用）", suggestion: "设备端未给出更具体状态，结合设备日志排查"),
        Entry(scope: .interaction, code: 0x7D, name: "InvalidSubscription", summary: "订阅无效（已超时或被移除）", suggestion: "重新建立订阅并确认设备可达"),
        Entry(scope: .interaction, code: 0x7E, name: "UnsupportedAccess", summary: "权限不足", suggestion: "控制器未被 ACL 授权，检查设备端 ACL 条目"),
        Entry(scope: .interaction, code: 0x7F, name: "UnsupportedEndpoint", summary: "端点不存在", suggestion: "核对端点 ID 与 Descriptor.PartsList"),
        Entry(scope: .interaction, code: 0x80, name: "InvalidAction", summary: "无效操作", suggestion: "请求与集群当前状态不符（如未开 failsafe 即下发配网凭证）"),
        Entry(scope: .interaction, code: 0x81, name: "UnsupportedCommand", summary: "命令不存在", suggestion: "核对命令 ID 与设备 AcceptedCommandList"),
        Entry(scope: .interaction, code: 0x85, name: "InvalidCommand", summary: "无效命令", suggestion: "命令不在设备支持的命令列表中"),
        Entry(scope: .interaction, code: 0x86, name: "UnsupportedAttribute", summary: "属性不存在", suggestion: "核对属性 ID 与设备 AttributeList"),
        Entry(scope: .interaction, code: 0x87, name: "ConstraintError", summary: "约束错误：值超出允许范围", suggestion: "按规范取值范围调整写入值"),
        Entry(scope: .interaction, code: 0x88, name: "UnsupportedWrite", summary: "不支持写入", suggestion: "该属性为只读"),
        Entry(scope: .interaction, code: 0x89, name: "ResourceExhausted", summary: "资源耗尽", suggestion: "设备侧资源不足，稍后重试或清理设备侧资源"),
        Entry(scope: .interaction, code: 0x8B, name: "NotFound", summary: "未找到目标", suggestion: "核对端点 / 集群 / 属性路径是否存在"),
        Entry(scope: .interaction, code: 0x8C, name: "UnreportableAttribute", summary: "属性不可报告", suggestion: "该属性不支持订阅报告，改为读取"),
        Entry(scope: .interaction, code: 0x8D, name: "InvalidDataType", summary: "数据类型无效", suggestion: "写入值类型与属性定义不符"),
        Entry(scope: .interaction, code: 0x8F, name: "UnsupportedRead", summary: "不支持读取", suggestion: "该属性不可读"),
        Entry(scope: .interaction, code: 0x92, name: "DataVersionMismatch", summary: "数据版本不匹配", suggestion: "先重读属性值再写入"),
        Entry(scope: .interaction, code: 0x94, name: "Timeout", summary: "超时：设备未响应", suggestion: "确认设备在线且信号良好"),
        Entry(scope: .interaction, code: 0x9C, name: "Busy", summary: "设备忙", suggestion: "稍后重试"),
        Entry(scope: .interaction, code: 0x9D, name: "AccessRestricted", summary: "访问受限", suggestion: "设备处于受限状态（如配网窗口未开启），检查设备状态"),
        Entry(scope: .interaction, code: 0xC3, name: "UnsupportedCluster", summary: "集群不存在", suggestion: "核对集群 ID 与 Descriptor.ServerList"),
        Entry(scope: .interaction, code: 0xC5, name: "NoUpstreamSubscription", summary: "缺少上游订阅", suggestion: "设备端订阅链路异常，重新建立订阅"),
        Entry(scope: .interaction, code: 0xC6, name: "NeedsTimedInteraction", summary: "需要定时交互", suggestion: "先发 TimedRequest 再以 timed invoke 发送该命令"),
        Entry(scope: .interaction, code: 0xC7, name: "UnsupportedEvent", summary: "事件不存在", suggestion: "核对事件 ID 与设备 EventList"),
        Entry(scope: .interaction, code: 0xC8, name: "PathsExhausted", summary: "路径数超出设备上限", suggestion: "减少单次请求的路径数，分批读写"),
        Entry(scope: .interaction, code: 0xC9, name: "TimedRequestMismatch", summary: "TimedRequest 不匹配", suggestion: "定时交互已超时或状态不符，重新发起"),
        Entry(scope: .interaction, code: 0xCA, name: "FailsafeRequired", summary: "需要先开启 failsafe", suggestion: "先调用 ArmFailSafe 再执行该命令"),
        Entry(scope: .interaction, code: 0xCB, name: "InvalidInState", summary: "当前状态不允许该操作", suggestion: "按集群状态机顺序执行命令"),
        Entry(scope: .interaction, code: 0xCC, name: "NoCommandResponse", summary: "命令无响应", suggestion: "设备未返回响应，确认设备固件实现"),
        Entry(scope: .interaction, code: 0xCF, name: "DynamicConstraintError", summary: "动态约束错误", suggestion: "写入值不满足运行时约束条件"),
        Entry(scope: .interaction, code: 0xD1, name: "InvalidTransportType", summary: "传输类型无效", suggestion: "该集群不支持当前传输方式"),
    ]
}