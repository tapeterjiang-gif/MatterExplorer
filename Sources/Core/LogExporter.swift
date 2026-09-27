import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// 日志导出：把事件快照格式化为 JSON / 纯文本，并写入临时文件供分享面板使用。
enum LogExporter {

    enum Format: String, CaseIterable, Identifiable, Sendable {
        case json
        case text

        var id: String { rawValue }

        var label: String {
            switch self {
            case .json: "JSON"
            case .text: "纯文本"
            }
        }

        var fileExtension: String {
            switch self {
            case .json: "json"
            case .text: "txt"
            }
        }
    }

    /// 导出条目的稳定结构（不直接序列化 MatterEvent，避免内部字段变动影响格式）。
    private struct Record: Codable {
        let timestamp: String
        let level: String
        let category: String
        let nodeID: String?
        let endpointID: Int?
        let message: String
        let errorCode: String?
        let detail: [String: String]?
    }

    private static func makeRecords(_ events: [MatterEvent]) -> [Record] {
        events.map { event in
            Record(
                timestamp: ISO8601DateFormatter().string(from: event.timestamp),
                level: event.level.rawValue,
                category: event.category.rawValue,
                nodeID: event.nodeID.map(String.init),
                endpointID: event.endpointID.map(Int.init),
                message: event.message,
                errorCode: event.errorCode.map { MatterHex.hex($0, width: 2) },
                detail: event.detail
            )
        }
    }

    // MARK: - 格式化

    static func json(from events: [MatterEvent]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(makeRecords(events)),
              let text = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return text
    }

    static func text(from events: [MatterEvent]) -> String {
        let formatter = ISO8601DateFormatter()
        return events.map { event in
            var line = "[\(formatter.string(from: event.timestamp))] "
                + "\(event.level.rawValue.uppercased()) "
                + "\(event.category.rawValue)"
            if let nodeID = event.nodeID { line += " node=\(nodeID)" }
            if let endpointID = event.endpointID { line += " ep=\(endpointID)" }
            line += " | \(event.message)"
            if let code = event.errorCode {
                line += " | error=\(MatterHex.hex(code, width: 2))"
            }
            if let detail = event.detail, !detail.isEmpty {
                let pairs = detail.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
                line += " | " + pairs.joined(separator: ", ")
            }
            return line
        }
        .joined(separator: "\n")
    }

    static func string(from events: [MatterEvent], format: Format) -> String {
        switch format {
        case .json: json(from: events)
        case .text: text(from: events)
        }
    }

    // MARK: - 文件

    /// 写入临时目录（文件名含时间戳），返回可分享的 URL。
    static func writeTemporaryFile(events: [MatterEvent], format: Format) throws -> URL {
        let now = Date()
        let day = now.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        let clock = now.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
        )
        let name = "MatterExplorer-\(day)-\(clock.replacingOccurrences(of: ":", with: "")).\(format.fileExtension)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try string(from: events, format: format).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - 分享用 Transferable 包装

/// 只在用户点击分享时才生成文件（构造包装类型本身不做格式化）。
struct LogExportJSON: Transferable, Sendable {
    let events: [MatterEvent]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { item in
            SentTransferredFile(try LogExporter.writeTemporaryFile(events: item.events, format: .json))
        }
    }
}

struct LogExportText: Transferable, Sendable {
    let events: [MatterEvent]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { item in
            SentTransferredFile(try LogExporter.writeTemporaryFile(events: item.events, format: .text))
        }
    }
}