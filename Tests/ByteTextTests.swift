import Foundation
import Testing
@testable import MatterExplorer

/// `Int.byteText` 让存储用量、OTA 镜像体积等处共用同一格式。
///
/// 底层是 `ByteCountFormatter`，输出随当前 locale 变化，因此这里**不断言具体字符串**，
/// 只锁与 locale 无关的性质：不为空、且随量级变化（防止扩展被改成返回固定值或空串）。
struct ByteTextTests {

    @Test func notEmpty() {
        #expect(!Int(0).byteText.isEmpty)
        #expect(!Int(1_024).byteText.isEmpty)
    }

    @Test func changesAcrossMagnitudes() {
        let texts = [0, 1_048_576, 1_073_741_824].map(\.byteText)
        #expect(Set(texts).count == texts.count, "不同量级应呈现不同文本，实际：\(texts)")
    }
}