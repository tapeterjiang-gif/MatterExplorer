import SwiftUI

/// Matter 错误码词典：分组浏览 + 关键字搜索；可从日志行直接跳到具体条目。
struct ErrorDictionaryView: View {
    /// 由日志行带入的条目（置顶高亮展示）。
    var highlighted: MatterErrorDictionary.Entry? = nil
    @State private var searchText = ""

    private var results: [MatterErrorDictionary.Entry] {
        MatterErrorDictionary.search(searchText)
    }

    var body: some View {
        List {
            if let highlighted, searchText.isEmpty {
                Section("当前错误") {
                    EntryRow(entry: highlighted)
                }
            }

            if results.isEmpty {
                ContentUnavailableView(
                    "未找到匹配条目",
                    systemImage: "magnifyingglass",
                    description: Text("试试错误码的十六进制值或英文名")
                )
            }

            ForEach(MatterErrorDictionary.Scope.allCases, id: \.self) { scope in
                let entries = results.filter { $0.scope == scope }
                if !entries.isEmpty {
                    Section {
                        ForEach(entries) { entry in
                            EntryRow(entry: entry)
                        }
                    } header: {
                        Text(scope.title)
                    } footer: {
                        Text(scope.footnote)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "搜索码值 / 名称 / 说明")
        .secondaryPageTitle("错误码词典")
    }
}

private struct EntryRow: View {
    let entry: MatterErrorDictionary.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.codeText)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 52, alignment: .leading)
                Text(entry.summary)
                    .font(.subheadline)
                Spacer(minLength: 0)
                Text(entry.name)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if !entry.suggestion.isEmpty {
                Text("建议：\(entry.suggestion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview {
    NavigationStack {
        ErrorDictionaryView()
    }
}