import SwiftUI

struct MessageSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let entries: [MessageSearchEntry]
    let scope: String
    let onSelect: (String) -> Void
    @State private var query = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("\(scope) · \(entries.count) 条消息")
                    .font(.caption).foregroundStyle(HermesTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                let hits = MessageSearch.hits(in: entries, query: query)
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView("查找消息正文", systemImage: "magnifyingglass",
                        description: Text("输入关键词，点按结果可回到对应消息。"))
                } else if hits.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(hits) { hit in
                        Button {
                            onSelect(hit.id)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(hit.entry.label).font(.caption.weight(.semibold)).foregroundStyle(HermesTheme.accent)
                                (Text(hit.before) + Text(hit.match).bold().foregroundColor(HermesTheme.accent) + Text(hit.after))
                                    .font(.system(size: 15)).foregroundStyle(.white).lineLimit(4)
                            }.padding(.vertical, 8)
                        }
                        .accessibilityIdentifier("search-hit-\(hit.id)")
                        .listRowBackground(HermesTheme.surface)
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(HermesTheme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "关键词")
            .navigationTitle("查找消息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { dismiss() } } }
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}
