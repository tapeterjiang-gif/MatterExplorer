import Foundation
import Matter
import os

/// Matter 核心引导：Keychain IPK → MTRStorage 适配器 → Factory 启动 → Controller 创建/恢复。
/// 设计为 v1 单 fabric；后续多 fabric 时按 controller 集合建模。
final class MatterManager: @unchecked Sendable {
    static let shared = MatterManager()

    /// 首个 fabric 的固定 fabric ID（非零即可，与根公钥共同标识 fabric）。
    private static let fabricID: UInt64 = 1
    /// 控制器 VID：CSA 测试厂商 ID，用于自建 fabric。
    private static let vendorID: UInt32 = 0xFFF1

    private let lock = NSLock()
    private var _controller: MTRDeviceController?
    private let logger = Logger(subsystem: "com.example.MatterExplorer", category: "MatterManager")

    var controller: MTRDeviceController? {
        lock.lock(); defer { lock.unlock() }
        return _controller
    }

    /// 本机在该 fabric 上的节点 ID（OTA Provider 通告 / DefaultOTAProviders 需用）。
    var controllerNodeID: UInt64? {
        controller?.controllerNodeID?.uint64Value
    }

    /// Matter 存储目录（Library/MatterStore/）。
    private var storageDirectory: URL? {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("MatterStore", isDirectory: true)
    }

    /// App 启动时调用（MainActor .task）；阻塞性工作移到后台执行。
    nonisolated func bootstrap() async {
        await Task.detached(priority: .userInitiated) {
            self.bootstrapSynchronously()
        }.value
    }

    private func bootstrapSynchronously() {
        let log = LogStore.shared
        logger.info("bootstrap 开始")

        // 1. IPK（16 字节，Keychain 持久化）
        let ipk = KeychainStore.standard.loadOrCreateIPK()
        log.system("IPK 已就绪", detail: ["来源": "Keychain（自动创建/恢复）", "长度": "\(ipk.count) 字节", "hex": ipk.hexString])
        logger.info("IPK 就绪: \(ipk.count) 字节")

        // 2. MTRStorage 适配器（Library/MatterStore/）
        guard let storageDirectory else {
            log.error("无法定位 Library 目录", error: nil)
            return
        }
        let storage = MTRStorageAdapter(directory: storageDirectory)
        log.system("Matter 存储就绪", detail: ["目录": storageDirectory.path])

        // 3. 根密钥对（P-256，Keychain 持久化，框架自动签发证书）
        guard let keypair = MatterKeypair.loadOrCreateRootKeypair() else {
            log.error("根密钥对创建/恢复失败", error: nil)
            return
        }
        log.system("根密钥对已就绪", detail: ["算法": "P-256", "存储": "Keychain（永久项）"])

        // 4. 控制器工厂
        let factory = MTRDeviceControllerFactory.sharedInstance()
        if !factory.isRunning {
            let params = MTRDeviceControllerFactoryParams(storage: storage)
            // OTA Provider：设备（Requestor）需主动以 CASE 连接到本机发起 QueryImage，
            // 因此工厂必须以服务端模式运行；delegate 只能在工厂启动前装好。
            params.shouldStartServer = true
            params.otaProviderDelegate = OTAProviderService.shared
            log.system("OTA Provider 已挂载", detail: ["服务端模式": "开启", "镜像库": OTAImageStore.shared.directoryPath])
            // 未加载自定义 PAA 时保持为空 = 使用系统默认 PAA 信任列表（决策点 4）。
            let customs = PAAStore.shared.certificateData()
            if !customs.isEmpty {
                params.productAttestationAuthorityCertificates = customs
                log.system(
                    "已加载自定义 PAA 证书",
                    detail: ["数量": "\(customs.count)", "目录": PAAStore.shared.directoryPath]
                )
            }
            do {
                try factory.start(params)
                log.system("Matter 控制器工厂已启动", detail: ["模式": "共享 MTRStorage 持久化"])
            } catch {
                log.error("Matter 控制器工厂启动失败", error: error)
                return
            }
        }

        // 栈日志桥接（按已保存阈值恢复，默认「仅错误」）。
        MatterStackLogBridge.restore()

        // 5. 创建/恢复控制器
        let startupParams = MTRDeviceControllerStartupParams(
            ipk: ipk,
            fabricID: NSNumber(value: Self.fabricID),
            nocSigner: keypair
        )
        startupParams.vendorID = NSNumber(value: Self.vendorID)

        var controller: MTRDeviceController?
        var mode = ""
        let known = factory.knownFabrics ?? []
        if known.isEmpty {
            mode = "创建新 fabric"
            do {
                controller = try factory.createController(onNewFabric: startupParams)
            } catch {
                // Keychain 与存储状态不一致时回退到"恢复现有 fabric"。
                do {
                    controller = try factory.createController(onExistingFabric: startupParams)
                    mode = "回退：恢复现有 fabric"
                } catch {
                    log.error("控制器创建失败", error: error, detail: ["fabricID": "\(Self.fabricID)"])
                }
            }
        } else {
            mode = "恢复现有 fabric（已知 \(known.count) 个）"
            do {
                controller = try factory.createController(onExistingFabric: startupParams)
            } catch {
                log.error("控制器恢复失败", error: error, detail: ["fabricID": "\(Self.fabricID)"])
            }
        }

        if let controller {
            lock.lock()
            _controller = controller
            lock.unlock()
            let nodeID = controller.controllerNodeID?.uint64Value ?? 0
            log.system("Matter 控制器就绪", detail: [
                "模式": mode,
                "controllerNodeID": "\(nodeID)",
                "运行中": "\(controller.isRunning)",
                "uniqueIdentifier": "\(controller.uniqueIdentifier.uuidString)",
            ])
            logger.info("控制器就绪，nodeID=\(nodeID), running=\(controller.isRunning)")
        }
    }

    // MARK: - 状态快照（设置页展示）

    /// 控制器 / fabric 状态（Sendable 值类型）。
    struct Status: Sendable {
        struct FabricEntry: Sendable, Identifiable {
            let id: String
            let fabricIndex: Int
            let fabricID: UInt64
            let nodeID: UInt64
            let vendorID: UInt32
            let label: String
            let rootPublicKeyHex: String
            let hasRootCertificate: Bool

            var identityText: String {
                "fabric \(MatterHex.hex(fabricID)) · node \(MatterHex.hex(nodeID))"
            }

            /// 厂商名 + VID。厂商名来自 DCL 厂商表（未收录时只显示 VID，如测试厂商之外的自定义值）。
            var vendorText: String {
                let identifier = MatterHex.hex(vendorID)
                guard let name = MatterVendorCatalog.name(for: vendorID) else { return "VID \(identifier)" }
                return "\(name) · VID \(identifier)"
            }
        }

        var isFactoryRunning: Bool
        var isControllerReady: Bool
        var controllerNodeID: UInt64?
        var fabrics: [FabricEntry]
        var commissionedDeviceCount: Int
        var customPAACount: Int
        var storagePath: String?
    }

    func status() -> Status {
        let controller = self.controller
        let factory = MTRDeviceControllerFactory.sharedInstance()
        let fabrics = (factory.knownFabrics ?? []).map { info in
            Status.FabricEntry(
                id: info.rootPublicKey.hexString,
                fabricIndex: info.fabricIndex.intValue,
                fabricID: info.fabricID.uint64Value,
                nodeID: info.nodeID.uint64Value,
                vendorID: info.vendorID.uint32Value,
                label: info.label,
                rootPublicKeyHex: info.rootPublicKey.hexString,
                hasRootCertificate: info.rootCertificate != nil
            )
        }
        return Status(
            isFactoryRunning: factory.isRunning,
            isControllerReady: controller != nil,
            controllerNodeID: controller?.controllerNodeID?.uint64Value,
            fabrics: fabrics,
            commissionedDeviceCount: DeviceRegistry.shared.allDevices().count,
            customPAACount: PAAStore.shared.all().count,
            storagePath: storageDirectory?.path
        )
    }

    // MARK: - 重置

    /// 清空本机 Matter 持久化状态：控制器工厂、MatterStore、IPK、根密钥对、设备注册表。
    /// 框架不支持同进程重建工厂状态，因此重置后需重启 App 才会以全新 fabric 初始化。
    /// 自定义 PAA 证书与 OTA 镜像库不属于 fabric 状态，不在此清除。
    @discardableResult
    func resetPersistentState() -> [String: String] {
        var detail: [String: String] = [:]

        MTRDeviceControllerFactory.sharedInstance().stop()
        lock.lock()
        _controller = nil
        lock.unlock()
        detail["控制器工厂"] = "已关闭"

        DeviceService.shared.stopAllMonitoring()

        if let storageDirectory {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: storageDirectory.path)) ?? []
            for file in files {
                try? FileManager.default.removeItem(at: storageDirectory.appendingPathComponent(file))
            }
            detail["MatterStore"] = "已清空 \(files.count) 个文件"
        }

        detail["IPK"] = KeychainStore.standard.deleteIPK() ? "已删除" : "删除失败"
        detail["根密钥对"] = MatterKeypair.deletePersisted() ? "已删除" : "删除失败"

        let devices = DeviceRegistry.shared.allDevices().count
        DeviceRegistry.shared.removeAll()
        detail["设备注册表"] = "已清空 \(devices) 条记录"

        LogStore.shared.log(
            category: .system, level: .warning,
            message: "已重置本机 Matter 状态（重启 App 后生效）", detail: detail
        )
        return detail
    }
}
