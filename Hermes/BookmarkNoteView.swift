import SwiftUI

struct BookmarkNoteView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: LocalMessageTarget
    @State private var note: String
    @State private var failure: String?

    init(target: LocalMessageTarget, note: String) {
        self.target = target
        _note = State(initialValue: note)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("记下这条消息为什么值得保留…", text: $note, axis: .vertical)
                        .lineLimit(5...15).accessibilityLabel("收藏备注内容")
                } footer: {
                    Text("\(note.count) / 2,000 字符 · 备注仅保存在本机，会随备份导出。")
                        .foregroundStyle(note.count > MessageBookmark.noteLimit ? .red : HermesTheme.muted)
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("收藏备注").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        do { try model.updateBookmarkNote(target, note: note); dismiss() }
                        catch { failure = error.localizedDescription }
                    }
                    .disabled(note.count > MessageBookmark.noteLimit || model.needsRecovery)
                }
            }
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}
