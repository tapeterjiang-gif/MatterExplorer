import Testing
@testable import MatterExplorer

/// OTA `UpdateState` 与 Power Source（0x2F）的枚举映射。
///
/// 这两处各出过一次「凭印象手写取值表」的错：OTA 的 `UpdateState` 从 3 开始整体错位一格，
/// 且凭空多出 `DelayedOnDownload` / `DownloadError` 两个不存在的状态；`ClusterCatalog` 里
/// 0x2F 的属性名整体错位约 3 格。取值以 Matter.framework 头文件为准，这里逐个锁死。
struct DeviceServiceEnumTests {

    // MARK: - OTA

    private func updateStateLabel(_ value: UInt8) -> String? {
        var status = DeviceOTAStatus()
        status.updateState = value
        return status.updateStateLabel
    }

    @Test func otaUpdateStateLabels() {
        #expect(updateStateLabel(0) == "Unknown（未知）")
        #expect(updateStateLabel(1) == "Idle（空闲）")
        #expect(updateStateLabel(2) == "Querying（查询中）")
        #expect(updateStateLabel(3) == "DelayedOnQuery（推迟查询）")
        #expect(updateStateLabel(4) == "Downloading（下载中）")
        #expect(updateStateLabel(5) == "Applying（应用中）")
        #expect(updateStateLabel(6) == "DelayedOnApply（推迟应用）")
        #expect(updateStateLabel(7) == "RollingBack（回滚中）")
        #expect(updateStateLabel(8) == "DelayedOnUserConsent（等待用户确认）")
    }

    @Test func otaUnknownStateFallsBackToHex() {
        // 未知取值回退十六进制，不臆造状态名。
        #expect(updateStateLabel(9) == "0x09")
    }

    @Test func otaNotReadShowsNothing() {
        // 未读到该属性时不显示任何状态（而不是显示 Unknown）。
        #expect(DeviceOTAStatus().updateStateLabel == nil)
    }

    // MARK: - Power Source

    @Test func powerSourceStatusLabels() {
        func label(_ value: UInt8) -> String? {
            var source = DeviceBatteryStatus.Source(endpointID: 1)
            source.powerSourceStatus = value
            return source.powerSourceStatusLabel
        }
        #expect(label(0) == "Unspecified（未指定）")
        #expect(label(1) == "Active（供电中）")
        #expect(label(2) == "Standby（待机）")
        #expect(label(3) == "Unavailable（不可用）")
        #expect(label(4) == "0x04")
    }

    @Test func batteryEnumLabels() {
        var source = DeviceBatteryStatus.Source(endpointID: 1)
        source.chargeLevel = 2
        source.chargeState = 1
        source.replaceability = 2

        #expect(source.chargeLevelLabel == "Critical（严重不足）")
        #expect(source.chargeStateLabel == "IsCharging（充电中）")
        #expect(source.replaceabilityLabel == "UserReplaceable（用户可更换）")
    }

    @Test func notReadEnumsProduceNoText() {
        let source = DeviceBatteryStatus.Source(endpointID: 1)
        #expect(source.powerSourceStatusLabel == nil)
        #expect(source.chargeLevelLabel == nil)
        #expect(source.chargeStateLabel == nil)
        #expect(source.replaceabilityLabel == nil)
        #expect(source.percentText == nil)
    }

    @Test func percentRemainingIsHalfPercentUnits() {
        func percent(_ half: UInt16) -> String? {
            var source = DeviceBatteryStatus.Source(endpointID: 1)
            source.percentRemainingHalf = half
            return source.percentText
        }
        // 规范单位是半个百分点（0–200）。
        #expect(percent(0) == "0%")
        #expect(percent(100) == "50%")
        #expect(percent(200) == "100%")
        // 奇数表示带 .5%。
        #expect(percent(101) == "50.5%")
        #expect(percent(1) == "0.5%")
    }

    @Test func isBatteryAndHasDetails() {
        var source = DeviceBatteryStatus.Source(endpointID: 1)
        #expect(!source.isBattery)
        #expect(!source.hasDetails)

        // BatPresent 决定「是不是电池」，但本身不算明细字段（有线电源也可有该属性）。
        source.present = true
        #expect(source.isBattery)
        #expect(!source.hasDetails)

        source.chargeLevel = 0
        #expect(source.hasDetails)
    }
}