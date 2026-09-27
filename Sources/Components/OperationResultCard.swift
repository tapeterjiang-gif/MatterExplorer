import SwiftUI

/// 集群操作结果卡片：成功/失败图标 + 消息 + 耗时 + 可选中 JSON。
/// 供设备控制、设备管理、集群工具三处的「最近一次操作」复用。
struct OperationResultCard: View {
    let result: ClusterOperationResult

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: result.isSuccess ? "checkmark.circle" : "xmark.octagon")
                    .foregroundStyle(result.isSuccess ? .green : .red)
                Text(result.message)
                    .font(.subheadline)
                Spacer()
                Text(result.durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let json = result.json {
                Text(json)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        }
    }
}