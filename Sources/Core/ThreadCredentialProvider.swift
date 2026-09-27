import Foundation
#if canImport(ThreadNetwork)
import ThreadNetwork
#endif

// MARK: - 系统 Thread 网络凭证（值类型）

/// 系统已保存的 Thread 网络凭证摘要（跨线程安全传递，UI 直接消费）。
struct SystemThreadNetwork: Identifiable, Sendable, Equatable {
    let networkName: String
    let extendedPANID: String?
    let channel: UInt8
    let panID: String?
    /// 可直接用于配网的 Active Operational Dataset（十六进制）。
    let activeOperationalDatasetHex: String?
    let borderAgentID: String?

    var id: String { activeOperationalDatasetHex ?? networkName }
    var isDatasetComplete: Bool { activeOperationalDatasetHex != nil }
}

// MARK: - 平台能力

/// 当前构建是否具备读取系统 Thread 凭证的框架（模拟器 SDK 不含 ThreadNetwork.framework）。
enum ThreadCapability {
    static var isSupported: Bool {
        #if canImport(ThreadNetwork)
        true
        #else
        false
        #endif
    }

    /// 框架缺失时的降级说明（entitlement 要求见页面 footer）。
    static let unavailableMessage = "模拟器不支持读取系统 Thread 凭证，请在真机验证。"
}

#if canImport(ThreadNetwork)

// MARK: - THClient 封装（真机构建）

/// 封装 THClient（ThreadNetwork.framework）：读取系统已保存的 Thread 网络凭证。
///
/// 需要 entitlement `com.apple.developer.networking.manage-thread-network-credentials` 且仅真机可用；
/// 缺失 entitlement 或用户拒绝授权时调用会抛错，由 UI 降级提示。
enum ThreadCredentialProvider {
    /// 读取「当前 Team ID 保存」的网络（静默，不弹授权）；无结果或失败时给出说明。
    static func loadSavedNetworks() async -> (networks: [SystemThreadNetwork], message: String?) {
        do {
            let all = try await allNetworks()
            return (all, all.isEmpty ? "系统未保存任何 Thread 网络凭证（仅读取当前 Team ID 保存的网络）" : nil)
        } catch {
            return ([], Self.fallbackMessage(error))
        }
    }

    /// 读取附近活跃网络（会弹出系统授权提示）；无结果或失败时给出说明。
    static func loadNearbyNetworks() async -> (networks: [SystemThreadNetwork], message: String?) {
        do {
            let nearby = try await nearbyNetworks()
            return (nearby, nearby.isEmpty ? "未发现附近活跃的 Thread 网络" : nil)
        } catch {
            return ([], Self.fallbackMessage(error))
        }
    }

    /// 一次加载尝试多路径：附近网络（iOS 27，弹授权、不受 Team ID 限制）
    /// → 本应用 Team ID 已保存凭证（无弹窗）。
    static func loadNetworks() async -> (networks: [SystemThreadNetwork], message: String?) {
        do {
            let nearby = try await nearbyNetworks()
            if !nearby.isEmpty { return (nearby, nil) }
        } catch {
            LogStore.shared.log(
                category: .commissioning, level: .debug,
                message: "读取附近 Thread 网络失败，回退到已保存凭证",
                detail: ["错误": (error as NSError).localizedDescription]
            )
        }
        do {
            let all = try await allNetworks()
            if !all.isEmpty { return (all, nil) }
            return (all, "未找到已保存的 Thread 凭证（仅读取当前 Team ID 保存的网络）")
        } catch {
            return ([], Self.fallbackMessage(error))
        }
    }

    /// 当前 Team ID 保存的全部 Thread 网络（不会弹出授权提示）。
    static func allNetworks() async throws -> [SystemThreadNetwork] {
        let credentials = try await THClient().allCredentials()
        return credentials.map(SystemThreadNetwork.init).sorted { $0.networkName < $1.networkName }
    }

    /// 用户首选网络（会弹出系统授权提示）。
    static func preferredNetwork() async throws -> SystemThreadNetwork? {
        SystemThreadNetwork(try await THClient().preferredCredentials())
    }

    /// 附近活跃网络（iOS 27+，会弹出系统授权提示；拒绝时错误码为 15）。
    static func nearbyNetworks() async throws -> [SystemThreadNetwork] {
        let credentials = try await THClient().activeCredentialsForNearbyNetworks
        return credentials.map(SystemThreadNetwork.init).sorted { $0.networkName < $1.networkName }
    }

    private static func fallbackMessage(_ error: Error) -> String {
        let ns = error as NSError
        if ns.code == 15 {
            return "用户拒绝了共享 Thread 凭证的授权"
        }
        return "读取系统 Thread 凭证不可用（需 entitlement com.apple.developer.networking.manage-thread-network-credentials 与真机支持）"
    }
}

private extension SystemThreadNetwork {
    init(_ c: THCredentials) {
        self.init(
            networkName: c.networkName ?? "未命名网络",
            extendedPANID: c.extendedPANID?.hexString,
            channel: c.channel,
            panID: c.panID?.hexString,
            activeOperationalDatasetHex: c.activeOperationalDataSet?.hexString,
            borderAgentID: c.borderAgentID?.hexString
        )
    }
}

#else

// MARK: - 模拟器降级实现

/// 模拟器 SDK 不含 ThreadNetwork.framework：直接返回不可用提示。
enum ThreadCredentialProvider {
    static func loadSavedNetworks() async -> (networks: [SystemThreadNetwork], message: String?) {
        ([], ThreadCapability.unavailableMessage)
    }

    static func loadNearbyNetworks() async -> (networks: [SystemThreadNetwork], message: String?) {
        ([], ThreadCapability.unavailableMessage)
    }

    static func loadNetworks() async -> (networks: [SystemThreadNetwork], message: String?) {
        ([], ThreadCapability.unavailableMessage)
    }
}

#endif
