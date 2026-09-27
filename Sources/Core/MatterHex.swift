import Foundation

/// Matter 十六进制展示：统一 `0x` 前缀、固定宽度与大写。
///
/// 此前各处直接手写 `String(format: "0x%04X", …)`，散落三十余处，大小写也不一致
/// （Thread 的 PAN ID 与配网 errorCode 曾用小写）。约定集中到这里。
enum MatterHex {
    /// 按类型的自然宽度：UInt8 → 2、UInt16 / UInt32 → 4、UInt64 → 16。
    static func hex(_ value: UInt8) -> String { hex(value, width: 2) }
    static func hex(_ value: UInt16) -> String { hex(value, width: 4) }
    static func hex(_ value: UInt32) -> String { hex(value, width: 4) }
    static func hex(_ value: UInt64) -> String { hex(value, width: 16) }

    /// 显式宽度：用于宽度与类型不一致的取值（如软件版本 `0x00000001`）
    /// 或栈内的 `Int` 载体（无 `Int` 便捷重载，避免宽度被默认值悄悄改掉）。
    static func hex<T: BinaryInteger>(_ value: T, width: Int) -> String {
        String(format: "0x%0\(width)llX", UInt64(truncatingIfNeeded: value))
    }
}