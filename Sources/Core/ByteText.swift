import Foundation

extension Int {
    /// 字节数的展示文本（如「21.7 KB」）。
    /// 存储用量、OTA 镜像体积等处共用同一格式，避免各处自行拼 `ByteCountFormatter`。
    var byteText: String {
        ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file)
    }
}