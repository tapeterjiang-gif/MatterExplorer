import Testing
@testable import MatterExplorer

/// 特征目录：集群 → 特征映射与读数换算。
/// 读数是列表摘要与详情卡片的共同来源，其中的**哨兵值**判定（温度 0x8000、PM2.5 与 CO₂ 0xFFFF、
/// 照度 0、占用 0xFF）此前没有测试保护，这里逐条锁死。
struct DeviceTraitCatalogTests {

    // MARK: - 集群 → 特征

    @Test func traitsAreReadingsFirstThenControls() {
        // 读数特征按 listPriority 在前，控制特征在后。
        let traits = DeviceTraitCatalog.traits(from: [0x06, 0x0405, 0x0402])
        #expect(traits == [.temperature, .humidity, .onOff])
    }

    @Test func unknownClustersProduceNoTraits() {
        #expect(DeviceTraitCatalog.traits(from: [0x9999, 0x1D]) == [])
    }

    @Test func clusterMappingIsOneToOne() {
        // `traitForCluster` 用 Dictionary(uniqueKeysWithValues:) 构造：
        // 一旦两个特征共用一个集群 ID，构造时会直接 trap（而非测试失败），故在此守住唯一性。
        #expect(DeviceTraitCatalog.traitForCluster.count == DeviceTrait.allCases.count)
    }

    // MARK: - 读数

    private func reading(_ trait: DeviceTrait, _ value: MatterScalar) -> TraitReading {
        DeviceTraitCatalog.reading(trait, values: [trait.primaryKey: value], endpointID: 1)
    }

    @Test func temperatureReadings() {
        let ok = reading(.temperature, .number(2_500))
        #expect(ok.text == "25.0 ℃")
        #expect(ok.isAvailable)
        #expect(ok.endpointID == 1)

        // 0x8000 是规范里的无效值哨兵。
        let invalid = reading(.temperature, .number(-32_768))
        #expect(invalid.text == "—")
        #expect(!invalid.isAvailable)
    }

    @Test func humidityReadings() {
        #expect(reading(.humidity, .number(4_300)).text == "43%")
        #expect(!reading(.humidity, .number(-32_768)).isAvailable)
    }

    @Test func pm25AndCO2Sentinel() {
        // 0xFFFF 是 PM2.5 与 CO₂ 的无效值哨兵。
        #expect(!reading(.pm25, .number(65_535)).isAvailable)
        #expect(reading(.pm25, .number(12)).text == "12 µg/m³")
        #expect(!reading(.co2, .number(65_535)).isAvailable)
        #expect(reading(.co2, .number(800)).text == "800 ppm")
    }

    @Test func airQualityIndex() {
        #expect(reading(.airQuality, .number(1)).text == "优")
        #expect(reading(.airQuality, .number(1)).isAvailable)
        // 0 = 未知：有值但不算有效读数。
        #expect(reading(.airQuality, .number(0)).text == "未知")
        #expect(!reading(.airQuality, .number(0)).isAvailable)
        // 越界索引按无有效读数处理。
        #expect(!reading(.airQuality, .number(9)).isAvailable)
    }

    @Test func illuminanceZeroMeansTooDark() {
        // MeasuredValue == 0 是规范定义的「过暗无法测量」：显示「过暗」，但不作为有效读数。
        let dark = reading(.illuminance, .number(0))
        #expect(dark.text == "过暗")
        #expect(!dark.isAvailable)
        // 10_000 → 10^(10000/10000) = 10 lx
        #expect(reading(.illuminance, .number(10_000)).text == "10 lx")
    }

    @Test func occupancy() {
        #expect(reading(.occupancy, .number(1)).text == "有人")
        #expect(reading(.occupancy, .number(0)).text == "无人")
        // 0xFF 为无效值哨兵。
        #expect(!reading(.occupancy, .number(255)).isAvailable)
    }

    @Test func missingValueGivesDash() {
        let none = DeviceTraitCatalog.reading(.temperature, values: [:], endpointID: 2)
        #expect(none.text == "—")
        #expect(!none.isAvailable)
        #expect(none.endpointID == 2)
    }
}