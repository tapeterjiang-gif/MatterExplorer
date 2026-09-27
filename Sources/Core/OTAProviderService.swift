import Foundation
import Matter
import os

/// OTA Provider：实现 `MTROTAProviderDelegate`，用本地镜像库应答设备的 QueryImage，并按 BDX 分块回传镜像。
///
/// 安装点在 `MatterManager`：控制器工厂启动参数上设置 `otaProviderDelegate`，并开启服务端
/// （`shouldStartServer`），否则设备的 CASE 连接无法到达本机、OTA 流程无法启动。
/// 框架在任意线程回调本 delegate，且保证不并发；内部状态仍以 NSLock 保护。
final class OTAProviderService: NSObject, MTROTAProviderDelegate, @unchecked Sendable {
    static let shared = OTAProviderService()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.example.MatterExplorer", category: "OTAProvider")

    /// 进行中的 BDX 传输：nodeID → 镜像内容（内存映射，避免每个块重新读盘）。
    private var transfers: [UInt64: Data] = [:]

    // MARK: - 协议枚举（Matter 规范取值）

    /// QueryImageResponse.status
    private static let queryStatusUpdateAvailable: UInt8 = 0
    private static let queryStatusNotAvailable: UInt8 = 2
    private static let queryStatusDownloadProtocolNotSupported: UInt8 = 3
    /// ApplyUpdateResponse.action
    private static let applyActionProceed: UInt8 = 0
    private static let applyActionDiscontinue: UInt8 = 2
    /// 下载协议枚举中的 BDX。
    private static let bdxProtocolID: UInt8 = 0

    static let errorDomain = "com.example.MatterExplorer.OTAProvider"

    // MARK: - QueryImage（集群 0x29 / 命令 0x00）

    func handleQueryImage(
        forNodeID nodeID: NSNumber,
        controller: MTRDeviceController,
        params: MTROTASoftwareUpdateProviderClusterQueryImageParams,
        completion: @escaping (MTROTASoftwareUpdateProviderClusterQueryImageResponseParams?, Error?) -> Void
    ) {
        let vendorID = params.vendorID.uint32Value
        let productID = params.productID.uint32Value
        let currentVersion = params.softwareVersion.uint32Value
        let protocols = params.protocolsSupported.compactMap { ($0 as? NSNumber)?.uint8Value }
        let response = MTROTASoftwareUpdateProviderClusterQueryImageResponseParams()

        // 请求者未声明支持 BDX 时无法下载。
        guard protocols.isEmpty || protocols.contains(Self.bdxProtocolID) else {
            response.status = NSNumber(value: Self.queryStatusDownloadProtocolNotSupported)
            log("拒绝 QueryImage：请求者未声明支持 BDX", nodeID: nodeID, detail: [
                "VID / PID": "\(MatterHex.hex(vendorID, width: 4)) / \(MatterHex.hex(productID, width: 4))",
                "协议": protocols.map(String.init).joined(separator: "、"),
            ])
            completion(response, nil)
            return
        }

        guard let image = OTAImageStore.shared.image(
            vendorID: vendorID, productID: productID, newerThan: currentVersion
        ) else {
            response.status = NSNumber(value: Self.queryStatusNotAvailable)
            log("QueryImage：无可用镜像", nodeID: nodeID, detail: [
                "VID / PID": "\(MatterHex.hex(vendorID, width: 4)) / \(MatterHex.hex(productID, width: 4))",
                "设备当前版本": MatterHex.hex(currentVersion, width: 8),
                "库中镜像": "\(OTAImageStore.shared.all().count) 个",
            ])
            completion(response, nil)
            return
        }

        response.status = NSNumber(value: Self.queryStatusUpdateAvailable)
        response.imageURI = image.designator
        response.softwareVersion = NSNumber(value: image.softwareVersion)
        response.softwareVersionString = image.softwareVersionString
        response.updateToken = image.updateToken
        log("QueryImage：下发镜像 \(image.fileName)", nodeID: nodeID, detail: [
            "VID / PID": "\(MatterHex.hex(image.vendorID, width: 4)) / \(MatterHex.hex(image.productID, width: 4))",
            "目标版本": image.versionText,
            "载荷": "\(image.payloadSize) 字节",
        ])
        completion(response, nil)
    }

    // MARK: - ApplyUpdateRequest（集群 0x29 / 命令 0x02）

    func handleApplyUpdateRequest(
        forNodeID nodeID: NSNumber,
        controller: MTRDeviceController,
        params: MTROTASoftwareUpdateProviderClusterApplyUpdateRequestParams,
        completion: @escaping (MTROTASoftwareUpdateProviderClusterApplyUpdateResponseParams?, Error?) -> Void
    ) {
        let response = MTROTASoftwareUpdateProviderClusterApplyUpdateResponseParams()
        response.delayedActionTime = NSNumber(value: 0)

        // 令牌由镜像 ID 派生，据此定位本次下载的镜像并核对版本。
        let image = OTAImageStore.shared.all().first { $0.updateToken == params.updateToken }
        if let image, image.softwareVersion == params.newVersion.uint32Value {
            response.action = NSNumber(value: Self.applyActionProceed)
            log("ApplyUpdateRequest：允许应用更新", nodeID: nodeID, detail: [
                "镜像": image.fileName,
                "目标版本": image.versionText,
            ])
        } else {
            response.action = NSNumber(value: Self.applyActionDiscontinue)
            log("ApplyUpdateRequest：终止更新（令牌或版本不匹配）", nodeID: nodeID, detail: [
                "声明版本": MatterHex.hex(params.newVersion.uint32Value, width: 8),
                "令牌": String(params.updateToken.hexString.prefix(32)),
            ])
        }
        completion(response, nil)
    }

    // MARK: - NotifyUpdateApplied（集群 0x29 / 命令 0x04）

    func handleNotifyUpdateApplied(
        forNodeID nodeID: NSNumber,
        controller: MTRDeviceController,
        params: MTROTASoftwareUpdateProviderClusterNotifyUpdateAppliedParams,
        completion: @escaping (Error?) -> Void
    ) {
        log("NotifyUpdateApplied：设备已应用新固件", nodeID: nodeID, detail: [
            "软件版本": MatterHex.hex(params.softwareVersion.uint32Value, width: 8),
        ])
        completion(nil)
    }

    // MARK: - BDX 传输

    func handleBDXTransferSessionBegin(
        forNodeID nodeID: NSNumber,
        controller: MTRDeviceController,
        fileDesignator: String,
        offset: NSNumber,
        completion: @escaping (Error?) -> Void
    ) {
        guard let image = OTAImageStore.shared.image(forDesignator: fileDesignator),
              let data = OTAImageStore.shared.contents(of: image) else {
            log("BDX 会话开始被拒：未知 designator", nodeID: nodeID, detail: ["designator": fileDesignator])
            completion(NSError(
                domain: Self.errorDomain, code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未知的 file designator：\(fileDesignator)"]
            ))
            return
        }
        lock.lock()
        transfers[nodeID.uint64Value] = data
        lock.unlock()
        log("BDX 会话开始", nodeID: nodeID, detail: [
            "镜像": image.fileName,
            "designator": fileDesignator,
            "起传偏移": "\(offset.intValue)",
            "总长度": "\(data.count) 字节",
        ])
        completion(nil)
    }

    func handleBDXQuery(
        forNodeID nodeID: NSNumber,
        controller: MTRDeviceController,
        blockSize: NSNumber,
        blockIndex: NSNumber,
        bytesToSkip: NSNumber,
        completion: @escaping (Data?, Bool) -> Void
    ) {
        lock.lock()
        let data = transfers[nodeID.uint64Value]
        lock.unlock()

        let size = blockSize.intValue
        guard let data, size > 0 else {
            completion(nil, true)
            return
        }
        // BDX BlockQuery 语义：偏移 = 块序号 × 块大小 + 起始跳过字节。
        let (product, multiplyOverflow) = blockIndex.uint64Value.multipliedReportingOverflow(by: UInt64(size))
        let (offset, addOverflow) = product.addingReportingOverflow(bytesToSkip.uint64Value)
        guard !multiplyOverflow, !addOverflow, offset < UInt64(data.count) else {
            completion(nil, true)
            return
        }
        let end = min(UInt64(data.count), offset + UInt64(size))
        let isEOF = end >= UInt64(data.count)
        completion(data.subdata(in: Int(offset) ..< Int(end)), isEOF)
    }

    func handleBDXTransferSessionEnd(
        forNodeID nodeID: NSNumber,
        controller: MTRDeviceController,
        metrics: MTRMetrics,
        error: Error?
    ) {
        lock.lock()
        let data = transfers.removeValue(forKey: nodeID.uint64Value)
        lock.unlock()
        log("BDX 会话结束", nodeID: nodeID, level: error == nil ? .info : .warning, detail: [
            "镜像大小": data.map { "\($0.count) 字节" } ?? "未登记",
            "结果": error.map { MatterErrorDictionary.description(for: $0) } ?? "成功",
        ])
    }

    // MARK: - 日志

    private func log(
        _ message: String,
        nodeID: NSNumber,
        level: MatterEvent.Level = .info,
        detail: [String: String]? = nil
    ) {
        logger.info("\(message), nodeID=\(nodeID.uint64Value)")
        LogStore.shared.log(
            category: .system, level: level, message: message, detail: detail,
            nodeID: nodeID.uint64Value, endpointID: 0
        )
    }
}