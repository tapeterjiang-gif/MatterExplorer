import SwiftUI

/// 明细行：字段名（弱化）+ 完整值（等宽、可选中）。
/// 供控制器诊断、Thread 网络等以「字段名 + 长值」罗列信息的页面复用。
struct DetailLine: View {
    let title: String
    let value: String

    init(_ title: String, _ value: String) {
        self.title = title
        self.value = value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}