import Foundation
import Matter
import os

// MARK: - 值类型（跨线程安全）

/// 集群操作（读 / 写 / 命令）结果快照。
struct ClusterOperationResult: Error, Sendable {
    let isSuccess: Bool
    let message: String
    let json: String?
    let duration: TimeInterval
    let nodeID: UInt64

    /// 操作耗时展示（毫秒，一位小数）。
    var durationText: String { String(format: "%.1f ms", duration * 1000) }
}

/// 属性报告：订阅实时流或读操作的单条结果。
struct ClusterAttributeReport: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let nodeID: UInt64
    let endpointID: UInt16?
    let clusterID: UInt32?
    let attributeID: UInt32?
    let valueJSON: String
    let isError: Bool
    /// 类型化值（供控制面板等按属性取值；错误条目为 nil）。
    let scalar: MatterScalar?
}

/// Matter 属性值的类型化快照与编解码见 MatterValueCodec.swift。

/// 集群工具服务：节点注册表 + MTRBaseDevice 读 / 写 / 命令封装 + MTRDevice 订阅桥接。
/// 线程安全：注册表经 UserDefaults；订阅句柄由 NSLock 保护；所有回调经 Sendable 值类型传递。
final class ClusterToolService: @unchecked Sendable {
    static let shared = ClusterToolService()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.example.MatterExplorer", category: "ClusterTool")
    private let queue = DispatchQueue(label: "com.example.MatterExplorer.clusterTool")

    /// 活动订阅：令牌 → 句柄。MTRDevice 对 delegate 弱引用，须强持有。
    /// 同一节点可存在多个订阅（如集群工具单属性订阅 + 设备控制多属性订阅），故以令牌为键。
    private struct SubscriptionHandle {
        let nodeID: UInt64
        let device: MTRDevice
        let delegate: ClusterSubscriptionDelegate
    }

    private var subscriptions: [String: SubscriptionHandle] = [:]

    // MARK: - 节点注册表（数据由 DeviceRegistry 统一维护）

    /// 配网成功后登记节点（幂等）；设备报告的 VID / PID 一并写入，设备列表无需等详情页读取。
    func registerCommissionedNode(_ nodeID: UInt64, vendorID: UInt32? = nil, productID: UInt32? = nil) {
        let record = DeviceRegistry.shared.registerCommissioned(
            nodeID: nodeID, vendorID: vendorID, productID: productID
        )
        LogStore.shared.log(
            category: .system, level: .info,
            message: "已登记已配网节点",
            detail: [
                "nodeID": "\(nodeID)",
                "首次登记": record.commissionedAt.formatted(date: .numeric, time: .standard),
                "VID / PID": record.vendorProductText,
            ],
            nodeID: nodeID
        )
    }

    // MARK: - 设备访问

    /// 构造 MTRBaseDevice（供本模块内其它服务复用类型化集群 API）。
    func baseDevice(nodeID: UInt64) -> MTRBaseDevice? {
        guard let controller = MatterManager.shared.controller else { return nil }
        return MTRBaseDevice(nodeID: NSNumber(value: nodeID), controller: controller)
    }

    /// 读属性。endpoint / cluster / attribute 传 nil 表示通配。
    func readAttribute(
        nodeID: UInt64,
        endpointID: UInt16?,
        clusterID: UInt32?,
        attributeID: UInt32?,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let device = baseDevice(nodeID: nodeID) else {
            completion(failure(nodeID: nodeID, message: "Matter 控制器未就绪"))
            return
        }
        let start = Date()
        device.readAttributes(
            withEndpointID: endpointID.map { NSNumber(value: $0) },
            clusterID: clusterID.map { NSNumber(value: $0) },
            attributeID: attributeID.map { NSNumber(value: $0) },
            params: nil,
            queue: queue
        ) { values, error in
            self.finishOperation(nodeID: nodeID, start: start, values: values, error: error, completion: completion)
        }
    }

    /// 写属性。value 为数据值字典（{MTRTypeKey, MTRValueKey}）。
    func writeAttribute(
        nodeID: UInt64,
        endpointID: UInt16,
        clusterID: UInt32,
        attributeID: UInt32,
        value: Any,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let device = baseDevice(nodeID: nodeID) else {
            completion(failure(nodeID: nodeID, message: "Matter 控制器未就绪"))
            return
        }
        let start = Date()
        device.writeAttribute(
            withEndpointID: NSNumber(value: endpointID),
            clusterID: NSNumber(value: clusterID),
            attributeID: NSNumber(value: attributeID),
            value: value,
            timedWriteTimeout: nil,
            queue: queue
        ) { values, error in
            self.finishOperation(nodeID: nodeID, start: start, values: values, error: error, completion: completion)
        }
    }

    /// 调用命令。commandFields 为结构体数据值字典（{MTRTypeKey: MTRStructureValueType, MTRValueKey: [...]}）。
    func invokeCommand(
        nodeID: UInt64,
        endpointID: UInt16,
        clusterID: UInt32,
        commandID: UInt32,
        commandFields: Any,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        guard let device = baseDevice(nodeID: nodeID) else {
            completion(failure(nodeID: nodeID, message: "Matter 控制器未就绪"))
            return
        }
        let start = Date()
        device.invokeCommand(
            withEndpointID: NSNumber(value: endpointID),
            clusterID: NSNumber(value: clusterID),
            commandID: NSNumber(value: commandID),
            commandFields: commandFields,
            timedInvokeTimeout: nil,
            queue: queue
        ) { values, error in
            self.finishOperation(nodeID: nodeID, start: start, values: values, error: error, completion: completion)
        }
    }

    /// 读属性并解析为「属性 ID → 类型化值」快照。attributeIDs 为空时读取该集群全部属性。
    /// 多个属性时逐个交互（框架单次只支持单属性过滤），全部成功才返回。
    func readScalars(
        nodeID: UInt64,
        endpointID: UInt16,
        clusterID: UInt32,
        attributeIDs: [UInt32],
        completion: @escaping @Sendable (Result<[UInt32: MatterScalar], ClusterOperationResult>) -> Void
    ) {
        guard let device = baseDevice(nodeID: nodeID) else {
            completion(.failure(failure(nodeID: nodeID, message: "Matter 控制器未就绪")))
            return
        }
        let targets: [NSNumber?] = attributeIDs.isEmpty ? [nil] : attributeIDs.map { NSNumber(value: $0) }
        readScalarsNext(
            device: device, nodeID: nodeID, endpointID: endpointID, clusterID: clusterID,
            remaining: targets, accumulated: [:], start: Date(), completion: completion
        )
    }

    private func readScalarsNext(
        device: MTRBaseDevice,
        nodeID: UInt64,
        endpointID: UInt16,
        clusterID: UInt32,
        remaining: [NSNumber?],
        accumulated: [UInt32: MatterScalar],
        start: Date,
        completion: @escaping @Sendable (Result<[UInt32: MatterScalar], ClusterOperationResult>) -> Void
    ) {
        guard let attributeID = remaining.first else {
            completion(.success(accumulated))
            return
        }
        device.readAttributes(
            withEndpointID: NSNumber(value: endpointID),
            clusterID: NSNumber(value: clusterID),
            attributeID: attributeID,
            params: nil,
            queue: queue
        ) { values, error in
            if let error {
                completion(.failure(ClusterOperationResult(
                    isSuccess: false,
                    message: MatterErrorDictionary.description(for: error),
                    json: nil,
                    duration: Date().timeIntervalSince(start),
                    nodeID: nodeID
                )))
                return
            }
            let pathErrors = (values ?? []).compactMap { $0[MTRErrorKey] as? Error }
            if let first = pathErrors.first {
                completion(.failure(ClusterOperationResult(
                    isSuccess: false,
                    message: MatterErrorDictionary.description(for: first),
                    json: MatterValueCodec.prettyJSON(from: values ?? []),
                    duration: Date().timeIntervalSince(start),
                    nodeID: nodeID
                )))
                return
            }
            var merged = accumulated
            merged.merge(MatterValueCodec.scalars(from: values ?? [])) { _, new in new }
            self.readScalarsNext(
                device: device, nodeID: nodeID, endpointID: endpointID, clusterID: clusterID,
                remaining: Array(remaining.dropFirst()), accumulated: merged, start: start, completion: completion
            )
        }
    }

    // MARK: - 端点 / 集群发现（Descriptor 列表属性）

    /// 端点发现：读取端点 0 的 Descriptor.PartsList（属性 0），解析为端点 ID 列表。
    func discoverEndpoints(nodeID: UInt64, completion: @escaping @Sendable (Result<[UInt16], ClusterOperationResult>) -> Void) {
        readAttribute(nodeID: nodeID, endpointID: 0, clusterID: 0x1D, attributeID: 3) { result in
            if result.isSuccess {
                let numbers = MatterValueCodec.extractNumberArray(from: result.json)
                completion(.success(numbers.map { $0.uint16Value }))
            } else {
                completion(.failure(result))
            }
        }
    }

    /// 集群发现：读取指定端点的 Descriptor.ServerList（属性 1），解析为集群 ID 列表。
    func discoverClusters(
        nodeID: UInt64,
        endpointID: UInt16,
        completion: @escaping @Sendable (Result<[UInt32], ClusterOperationResult>) -> Void
    ) {
        readAttribute(nodeID: nodeID, endpointID: endpointID, clusterID: 0x1D, attributeID: 1) { result in
            if result.isSuccess {
                let numbers = MatterValueCodec.extractNumberArray(from: result.json)
                completion(.success(numbers.map { $0.uint32Value }))
            } else {
                completion(.failure(result))
            }
        }
    }

    /// 设备类型发现：读取指定端点的 `Descriptor.DeviceTypeList`（属性 0）。
    /// 与 `discoverClusters` 不同，该属性是结构体数组，走 `readScalars` 解析（`extractNumberArray` 取不到）。
    func discoverDeviceTypes(
        nodeID: UInt64,
        endpointID: UInt16,
        completion: @escaping @Sendable (Result<[UInt32], ClusterOperationResult>) -> Void
    ) {
        readScalars(nodeID: nodeID, endpointID: endpointID, clusterID: 0x1D, attributeIDs: [0]) { result in
            switch result {
            case .success(let scalars):
                completion(.success(MatterValueCodec.deviceTypeIDs(from: scalars[0])))
            case .failure(let operation):
                completion(.failure(operation))
            }
        }
    }

    // MARK: - 订阅

    /// 订阅属性实时报告。参数全 nil = 订阅全部属性。
    /// onUpdate 与 onState 均在主线程回调。返回取消令牌；nil 表示控制器未就绪。
    func subscribe(
        nodeID: UInt64,
        endpointID: UInt16?,
        clusterID: UInt32?,
        attributeID: UInt32?,
        onUpdate: @escaping @Sendable ([ClusterAttributeReport]) -> Void,
        onState: @escaping @Sendable (String) -> Void
    ) -> String? {
        // 兴趣路径：按粒度构造 MTRAttributePath / MTRClusterPath / NSNumber，全 nil 时不加过滤。
        let interested: [Any]?
        if let endpointID, let clusterID, let attributeID {
            interested = [MTRAttributePath(
                endpointID: NSNumber(value: endpointID), clusterID: NSNumber(value: clusterID), attributeID: NSNumber(value: attributeID)
            )]
        } else if let endpointID, let clusterID {
            interested = [MTRClusterPath(endpointID: NSNumber(value: endpointID), clusterID: NSNumber(value: clusterID))]
        } else if let endpointID {
            interested = [NSNumber(value: endpointID)]
        } else {
            interested = nil
        }

        let detail: [String: String] = [
            "nodeID": "\(nodeID)",
            "端点": endpointID.map(String.init) ?? "全部",
            "集群": clusterID.map { MatterHex.hex($0, width: 4) } ?? "全部",
            "属性": attributeID.map { MatterHex.hex($0, width: 4) } ?? "全部",
        ]
        return addSubscription(nodeID: nodeID, interested: interested, detail: detail, onUpdate: onUpdate, onState: onState)
    }

    /// 订阅指定兴趣路径（多端点 / 多属性），返回取消令牌；返回 nil 表示控制器未就绪。
    func subscribe(
        nodeID: UInt64,
        interestedPaths: [Any],
        detail: [String: String],
        onUpdate: @escaping @Sendable ([ClusterAttributeReport]) -> Void,
        onState: @escaping @Sendable (String) -> Void
    ) -> String? {
        addSubscription(
            nodeID: nodeID, interested: interestedPaths.isEmpty ? nil : interestedPaths,
            detail: detail, onUpdate: onUpdate, onState: onState
        )
    }

    /// 建立订阅并登记句柄。onUpdate / onState 转发到主线程。
    private func addSubscription(
        nodeID: UInt64,
        interested: [Any]?,
        detail: [String: String],
        onUpdate: @escaping @Sendable ([ClusterAttributeReport]) -> Void,
        onState: @escaping @Sendable (String) -> Void
    ) -> String? {
        guard let controller = MatterManager.shared.controller else { return nil }

        let device = MTRDevice(nodeID: NSNumber(value: nodeID), controller: controller)
        let delegate = ClusterSubscriptionDelegate(nodeID: nodeID) { reports in
            DispatchQueue.main.async { onUpdate(reports) }
        } onState: { text in
            DispatchQueue.main.async { onState(text) }
        }

        device.add(delegate, queue: queue, interestedPathsForAttributes: interested, interestedPathsForEvents: nil)

        let token = UUID().uuidString
        lock.lock()
        subscriptions[token] = SubscriptionHandle(nodeID: nodeID, device: device, delegate: delegate)
        lock.unlock()

        LogStore.shared.log(category: .dataModel, level: .info, message: "订阅已建立", detail: detail, nodeID: nodeID)
        return token
    }

    /// 取消该节点的全部订阅并移除句柄。
    func unsubscribe(nodeID: UInt64) {
        lock.lock()
        let tokens = subscriptions.filter { $0.value.nodeID == nodeID }.map(\.key)
        let handles = tokens.compactMap { subscriptions.removeValue(forKey: $0) }
        lock.unlock()
        guard !handles.isEmpty else { return }
        for handle in handles {
            handle.device.remove(handle.delegate)
        }
        LogStore.shared.log(
            category: .dataModel, level: .debug, message: "订阅已取消",
            detail: ["数量": "\(handles.count)"], nodeID: nodeID
        )
    }

    /// 按令牌取消单个订阅。
    func unsubscribe(token: String) {
        lock.lock()
        let handle = subscriptions.removeValue(forKey: token)
        lock.unlock()
        guard let handle else { return }
        handle.device.remove(handle.delegate)
        LogStore.shared.log(category: .dataModel, level: .debug, message: "订阅已取消", nodeID: handle.nodeID)
    }

    /// 当前订阅中的节点。
    func subscribedNodeIDs() -> [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return Array(Set(subscriptions.values.map(\.nodeID)))
    }

    // MARK: - 结果组装

    private func finishOperation(
        nodeID: UInt64,
        start: Date,
        values: [[String: Any]]?,
        error: Error?,
        completion: @escaping @Sendable (ClusterOperationResult) -> Void
    ) {
        let duration = Date().timeIntervalSince(start)

        if let error {
            completion(ClusterOperationResult(
                isSuccess: false,
                message: MatterErrorDictionary.description(for: error),
                json: nil,
                duration: duration,
                nodeID: nodeID
            ))
            return
        }

        // 提取逐路径错误（值数组中可能含 MTRErrorKey 条目）。
        let pathErrors = (values ?? []).compactMap { $0[MTRErrorKey] as? Error }
        if !pathErrors.isEmpty {
            completion(ClusterOperationResult(
                isSuccess: false,
                message: pathErrors.map { MatterErrorDictionary.description(for: $0) }.joined(separator: "; "),
                json: MatterValueCodec.prettyJSON(from: values ?? []),
                duration: duration,
                nodeID: nodeID
            ))
            return
        }

        completion(ClusterOperationResult(
            isSuccess: true,
            message: "成功（\(values?.count ?? 0) 个路径）",
            json: MatterValueCodec.prettyJSON(from: values ?? []),
            duration: duration,
            nodeID: nodeID
        ))
    }

    private func failure(nodeID: UInt64, message: String) -> ClusterOperationResult {
        ClusterOperationResult(isSuccess: false, message: message, json: nil, duration: 0, nodeID: nodeID)
    }
}

// MARK: - 订阅 Delegate 桥接

/// MTRDeviceDelegate 桥接：属性 / 事件报告与设备状态转换为 Sendable 值类型。
/// 回调运行在创建订阅时传入的串行 queue 上，再由桥接转发到主线程。
final class ClusterSubscriptionDelegate: NSObject, MTRDeviceDelegate, @unchecked Sendable {
    private let nodeID: UInt64
    private let onUpdate: @Sendable ([ClusterAttributeReport]) -> Void
    private let onState: @Sendable (String) -> Void

    init(
        nodeID: UInt64,
        onUpdate: @escaping @Sendable ([ClusterAttributeReport]) -> Void,
        onState: @escaping @Sendable (String) -> Void
    ) {
        self.nodeID = nodeID
        self.onUpdate = onUpdate
        self.onState = onState
        super.init()
    }

    // MARK: MTRDeviceDelegate (required)

    func device(_ device: MTRDevice, stateChanged state: MTRDeviceState) {
        let text: String
        switch state {
        case .unknown: text = "未知"
        case .reachable: text = "可达"
        case .unreachable: text = "不可达"
        @unknown default: text = "未知状态"
        }
        onState(text)
        LogStore.shared.log(category: .dataModel, level: .debug, message: "设备状态变化：\(text)", nodeID: nodeID)
    }

    func device(_ device: MTRDevice, receivedAttributeReport attributeReport: [[String: Any]]) {
        let reports = attributeReport.map { dict -> ClusterAttributeReport in
            let path = dict[MTRAttributePathKey] as? MTRAttributePath
            let error = dict[MTRErrorKey] as? Error
            return ClusterAttributeReport(
                id: UUID(),
                timestamp: Date(),
                nodeID: nodeID,
                endpointID: path?.endpoint.uint16Value,
                clusterID: path?.cluster.uint32Value,
                attributeID: path?.attribute.uint32Value,
                valueJSON: error != nil
                    ? "错误：\(MatterErrorDictionary.description(for: error!))"
                    : MatterValueCodec.prettyJSON(from: [dict]),
                isError: error != nil,
                scalar: error != nil ? nil : (dict[MTRDataKey] as? [String: Any]).map { MatterValueCodec.scalar(from: $0) }
            )
        }
        onUpdate(reports)
        // 属性报告是最高频的事件：正常报告合并成一条（避免刷屏与逐条 detail 的开销），
        // 仅错误报告逐条保留并附错误信息。
        let failures = reports.filter(\.isError)
        for report in failures {
            LogStore.shared.log(
                category: .dataModel, level: .warning, message: "订阅属性错误",
                detail: [
                    "路径": Self.pathText(report),
                    "值": String(report.valueJSON.prefix(200)),
                ],
                nodeID: nodeID, endpointID: report.endpointID
            )
        }
        let succeeded = reports.filter { !$0.isError }
        if !succeeded.isEmpty {
            LogStore.shared.log(
                category: .dataModel, level: .debug, message: "订阅属性更新（\(succeeded.count) 条）",
                detail: ["路径": Self.pathList(succeeded)],
                nodeID: nodeID
            )
        }
    }

    /// 单条报告的「端点 / 集群 / 属性」文本。
    private static func pathText(_ report: ClusterAttributeReport) -> String {
        "端点 \(report.endpointID.map(String.init) ?? "-") / 集群 \(report.clusterID.map { MatterHex.hex($0, width: 4) } ?? "-") / 属性 \(report.attributeID.map { MatterHex.hex($0, width: 4) } ?? "-")"
    }

    /// 合并后的路径清单：去重、最多列出 6 条，其余以计数概括。
    private static func pathList(_ reports: [ClusterAttributeReport]) -> String {
        var seen = Set<String>()
        var lines: [String] = []
        for report in reports {
            let text = pathText(report)
            guard seen.insert(text).inserted else { continue }
            lines.append(text)
        }
        let shown = lines.prefix(6)
        return shown.joined(separator: "\n")
            + (lines.count > shown.count ? "\n…另有 \(lines.count - shown.count) 个路径" : "")
    }

    func device(_ device: MTRDevice, receivedEventReport eventReport: [[String: Any]]) {
        // 事件不进入订阅流，仅记录日志（保真调试信息）。
        let summary = eventReport.prefix(3).map { dict -> String in
            let path = dict[MTREventPathKey] as? MTREventPath
            let tag = path != nil
                ? "端点 \(path?.endpoint.uint16Value ?? 0) / 集群 \(MatterHex.hex(path?.cluster.uint32Value ?? 0)) / 事件 \(MatterHex.hex(path?.event.uint32Value ?? 0))"
                : "未知路径"
            return "\(tag) \(MatterValueCodec.prettyJSON(from: [dict]))"
        }
        LogStore.shared.log(
            category: .dataModel, level: .info, message: "收到事件报告（\(eventReport.count) 条）",
            detail: ["摘要": summary.joined(separator: "\n")],
            nodeID: nodeID
        )
    }

    // MARK: MTRDeviceDelegate (optional)

    func deviceCachePrimed(_ device: MTRDevice) {
        LogStore.shared.log(category: .dataModel, level: .debug, message: "设备缓存已就绪", nodeID: nodeID)
    }
}
