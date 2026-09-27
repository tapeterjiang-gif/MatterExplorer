import Testing
@testable import MatterExplorer

/// `ClusterCatalog` 的名称表是**手写**的，此前已经错过一次：
/// Power Source（0x2F）的属性名整体错位约 3 格，还含一个规范里不存在的 `BatteryTimeToEmpty`。
/// 取值以 `MTRClusterConstants.h` 为准，这里锁死改正后的结果。
struct ClusterCatalogTests {

    @Test func powerSourceAttributeNames() {
        #expect(ClusterCatalog.attributeName(clusterID: 0x2F, attributeID: 0x0B) == "BatVoltage")
        #expect(ClusterCatalog.attributeName(clusterID: 0x2F, attributeID: 0x0C) == "BatPercentRemaining")
        #expect(ClusterCatalog.attributeName(clusterID: 0x2F, attributeID: 0x0E) == "BatChargeLevel")
        #expect(ClusterCatalog.attributeName(clusterID: 0x2F, attributeID: 0x11) == "BatPresent")
    }

    @Test func globalAttributeFallback() {
        // 未在集群特有表里登记的属性，回退到全局属性表。
        #expect(ClusterCatalog.attributeName(clusterID: 0x06, attributeID: 0xFFFD) == "ClusterRevision")
        #expect(ClusterCatalog.attributeName(clusterID: 0x1D, attributeID: 0xFFFB) == "AttributeList")
    }

    @Test func unknownIDsFallBackToHex() {
        // 未收录的 ID 一律回退十六进制，不臆造名称。
        #expect(ClusterCatalog.clusterName(0x9999) == "0x9999")
        #expect(ClusterCatalog.attributeName(clusterID: 0x9999, attributeID: 0x9999) == "0x9999")
    }

    @Test func knownClusterNames() {
        #expect(ClusterCatalog.clusterName(0x1D) == "Descriptor")
        #expect(ClusterCatalog.clusterName(0x2F) == "Power Source")
        #expect(ClusterCatalog.clusterName(0x2A) == "OTA Software Update Requestor")
    }
}