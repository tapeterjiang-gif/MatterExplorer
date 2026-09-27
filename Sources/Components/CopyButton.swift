import SwiftUI
import UIKit

/// 拷贝按钮：点击写入剪贴板并短暂显示勾选反馈。
/// 供控制器诊断、Thread 网络等需要把长值（节点 ID、路径、dataset）带走的页面复用。
struct CopyButton: View {
    let value: String

    @State private var isCopied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            isCopied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                isCopied = false
            }
        } label: {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.footnote)
                .foregroundStyle(isCopied ? Color.green : Color.accentColor)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(isCopied ? "已拷贝" : "拷贝")
    }
}