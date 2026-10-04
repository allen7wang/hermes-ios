import SwiftUI
import UIKit

struct MessageLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onOpen: (LocalMessageTarget) -> Void
    @State private var query = ""
    @State private var filter: MessageLibraryFilter = .bookmarks
    @State private var role: MessageLibraryRole = .all
    @State private var results: [MessageLibraryItem] = []
    @State private var searching = false

    private struct QueryRequest: Equatable {
        let conversations: [Conversation]
        let query: String
        let filter: MessageLibraryFilter
        let role: MessageLibraryRole
    }

    private var request: QueryRequest {
        QueryRequest(conversations: model.conversations, query: query, filter: filter, role: role)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(model.activeProfileName) · 本机记录 · \(results.count) 条结果")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                        if searching { ProgressView().controlSize(.mini) }
                    }
                    Picker("消息范围", selection: $filter) {
                        ForEach(MessageLibraryFilter.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                }.padding(16)
                if results.isEmpty {
                    if searching { ProgressView("正在查找…").frame(maxHeight: .infinity) }
                    else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        ContentUnavailableView(filter == .bookmarks ? "还没有收藏消息" : "没有符合条件的消息",
                            systemImage: filter == .bookmarks ? "bookmark" : "text.bubble",
                            description: Text("长按本机消息可收藏。选择“全部”可查找当前连接的所有本机对话。"))
                    }
                } else {
                    List(results) { item in
                        NavigationLink(value: item.id) { MessageLibraryRow(item: item, query: query) }
                            .accessibilityIdentifier("library-row-\(item.id.id)")
                            .listRowBackground(HermesTheme.surface)
                    }
                    .scrollContentBackground(.hidden)
                    .disabled(searching)
                }
            }
            .background(HermesTheme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索正文、对话标题或收藏备注")
            .navigationTitle("本机消息库").navigationBarTitleDisplayMode(.inline)
            .task(id: request) {
                let snapshot = request
                searching = true
                do { if !snapshot.query.isEmpty { try await Task.sleep(for: .milliseconds(250)) } }
                catch { return }
                let search = Task.detached(priority: .userInitiated) {
                    MessageLibrary.items(in: snapshot.conversations, query: snapshot.query, filter: snapshot.filter, role: snapshot.role)
                }
                let matches = await withTaskCancellationHandler(operation: { await search.value }, onCancel: { search.cancel() })
                guard !Task.isCancelled else { return }
                results = matches
                searching = false
            }
            .navigationDestination(for: LocalMessageTarget.self) { target in
                MessageLibraryDetailView(target: target, onOpen: onOpen)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("消息角色", selection: $role) {
                            ForEach(MessageLibraryRole.allCases) { Text($0.label).tag($0) }
                        }
                    } label: {
                        Image(systemName: role == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("筛选消息角色")
                }
            }
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

private struct MessageLibraryRow: View {
    let item: MessageLibraryItem
    let query: String
    private var hit: MessageSearchHit? {
        MessageSearch.hits(in: [MessageSearchEntry(id: item.id.id, label: item.roleLabel, text: item.message.content)], query: query).first
    }

    private var noteHit: MessageSearchHit? {
        guard let note = item.message.bookmark?.note else { return nil }
        return MessageSearch.hits(in: [MessageSearchEntry(id: item.id.id, label: "备注", text: note)], query: query).first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(item.conversationTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if item.message.bookmark != nil {
                    Image(systemName: "bookmark.fill").foregroundStyle(HermesTheme.accent).accessibilityLabel("已收藏")
                }
            }
            HStack {
                Text(item.roleLabel).foregroundStyle(HermesTheme.accent)
                if item.message.imageID != nil { Image(systemName: "photo").accessibilityLabel("包含图片") }
                Spacer()
                Text(item.message.createdAt, style: .date)
            }.font(.caption).foregroundStyle(HermesTheme.muted)
            if let hit {
                (Text(hit.before) + Text(hit.match).bold().foregroundColor(HermesTheme.accent) + Text(hit.after))
                    .font(.subheadline).lineLimit(4)
            } else { Text(item.preview).font(.subheadline).lineLimit(4) }
            if let note = item.message.bookmark?.note, !note.isEmpty {
                Label {
                    if let hit = noteHit {
                        Text(hit.before) + Text(hit.match).bold().foregroundColor(HermesTheme.accent) + Text(hit.after)
                    } else { Text(note) }
                } icon: { Image(systemName: "note.text") }
                    .font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(3)
            }
        }.foregroundStyle(.white).padding(.vertical, 8)
    }
}

private struct MessageLibraryDetailView: View {
    @EnvironmentObject private var model: AppModel
    let target: LocalMessageTarget
    let onOpen: (LocalMessageTarget) -> Void
    @State private var editingNote = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var copied = false
    private var item: MessageLibraryItem? { model.libraryItem(target) }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.conversationTitle).font(.headline)
                            HStack {
                                Text(item.roleLabel)
                                Text(item.message.createdAt, style: .date)
                                Text(item.message.createdAt, style: .time)
                            }.font(.caption).foregroundStyle(HermesTheme.muted)
                        }
                        if let id = item.message.imageID {
                            if let image = ImageAttachmentStore.image(id, directory: model.attachmentDirectory) {
                                Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 320)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            } else { Label("本机图片暂时无法读取", systemImage: "photo").font(.caption).foregroundStyle(HermesTheme.muted) }
                        }
                        MessageContentView(text: item.message.content, rendersMarkdown: item.message.role == .assistant)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        if let bookmark = item.message.bookmark {
                            VStack(alignment: .leading, spacing: 10) {
                                Label("收藏备注", systemImage: "note.text").font(.subheadline.weight(.semibold))
                                Text(bookmark.note.isEmpty ? "为这条消息添加用途、结论或待办。" : bookmark.note)
                                    .font(.subheadline).foregroundStyle(HermesTheme.muted).textSelection(.enabled)
                                Button("编辑备注") { editingNote = true }
                                    .foregroundStyle(HermesTheme.accent)
                            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                                .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            Button {
                                onOpen(target)
                            } label: { Label("回到原文", systemImage: "arrow.uturn.backward") }
                                .disabled(model.isSending || model.needsRecovery)
                            Button {
                                perform {
                                    try model.quoteMessage(target)
                                    notice = "已追加到当前对话草稿，尚未发送。"
                                }
                            } label: { Label("引用到当前草稿", systemImage: "text.quote") }
                                .disabled(model.needsRecovery)
                            Button {
                                UIPasteboard.general.string = item.message.content
                                copied = true
                            } label: { Label(copied ? "已复制原文" : "复制原文", systemImage: copied ? "checkmark" : "doc.on.doc") }
                                .disabled(item.message.content.isEmpty)
                            ShareLink(item: MessageLibrary.shareText(item)) { Label("分享文字与备注", systemImage: "square.and.arrow.up") }
                        }.foregroundStyle(HermesTheme.accent)
                        if model.isSending { Text("回复进行中，回到原文需先停止或等待完成。").font(.caption).foregroundStyle(HermesTheme.muted) }
                        if let notice { Text(notice).font(.caption).foregroundStyle(HermesTheme.accent).accessibilityIdentifier("library-notice") }
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            perform { try model.toggleBookmark(target) }
                        } label: {
                            Image(systemName: item.message.bookmark == nil ? "bookmark" : "bookmark.fill")
                        }
                        .accessibilityLabel(item.message.bookmark == nil ? "收藏消息" : "取消收藏")
                        .foregroundStyle(HermesTheme.accent)
                        .disabled(model.needsRecovery)
                    }
                }
            } else {
                ContentUnavailableView("原消息已不可用", systemImage: "text.bubble", description: Text("消息可能已删除，或当前连接已变更。"))
            }
        }
        .background(HermesTheme.background).foregroundStyle(.white)
        .navigationTitle("消息详情").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editingNote) {
            BookmarkNoteView(target: target, note: item?.message.bookmark?.note ?? "")
        }
        .alert("本机操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("知道了", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { failure = error.localizedDescription }
    }
}
