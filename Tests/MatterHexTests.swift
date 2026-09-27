import Testing
@testable import MatterExplorer

/// `MatterHex` 是全项目十六进制展示的唯一入口（此前散落三十余处手写 `String(format:)`，
/// 大小写也不一致）。这里锁死「大写 + `0x` 前缀 + 各整型自然位宽」的约定。
struct MatterHexTests {

    @Test func naturalWidths() {
        #expect(MatterHex.hex(UInt8(0x0A)) == "0x0A")
        #expect(MatterHex.hex(UInt16(0x001D)) == "0x001D")
        #expect(MatterHex.hex(UInt32(0x0402)) == "0x0402")
        #expect(MatterHex.hex(UInt64(1)) == "0x0000000000000001")
    }

    @Test func explicitWidthOverridesNaturalWidth() {
        // 宽度与类型不一致的取值（软件版本 `0x00000001`）。
        #expect(MatterHex.hex(UInt32(1), width: 8) == "0x00000001")
        // `Int` 载体没有便捷重载，必须显式给宽度——故意如此，避免宽度被默认值悄悄改掉。
        #expect(MatterHex.hex(2, width: 2) == "0x02")
    }

    @Test func maximumValues() {
        #expect(MatterHex.hex(UInt8.max) == "0xFF")
        #expect(MatterHex.hex(UInt16.max) == "0xFFFF")
        #expect(MatterHex.hex(UInt32.max) == "0xFFFFFFFF")
        #expect(MatterHex.hex(UInt64.max) == "0xFFFFFFFFFFFFFFFF")
    }
}