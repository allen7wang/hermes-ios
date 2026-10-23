import SwiftUI
import UIKit

private struct MessageLibraryBookmarkBatchRoute: Identifiable {
    let id = UUID()
    let snapshot: MessageLibraryBatchSnapshot
    let operation: MessageLibraryBatchOperation
}

struct MessageLibraryView: View {
    var embedded = false
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onOpen: (LocalMessageTarget) -> Void
    let onShowDraft: (() -> Void)?
    @State private var query = ""
    @State private var filter: MessageLibraryFilter = .bookmarks
    @State private var role: MessageLibraryRole = .all
    @State private var results: [MessageLibraryItem] = []
    @State private var searching = false
    @State private var scope: MessageLibraryScope = .all
    @State private var tag: String?
    @State private var project: ProjectFilter = .all
    @State private var selecting: Bool
    @State private var selection: Set<LocalMessageTarget> = []
    @State private var exportedBatch: MessageLibraryBatchSnapshot?
    @State private var bookmarkBatch: MessageLibraryBookmarkBatchRoute?
    @State private var batchError: String?
    @State private var batchNotice: String?
    @State private var quotedBatch: MessageDraftQuoteSnapshot?

    init(embedded: Bool = false, onShowDraft: (() -> Void)? = nil,
         onOpen: @escaping (LocalMessageTarget) -> Void, selecting: Bool = false) {
        self.embedded = embedded
        self.onShowDraft = onShowDraft
        self.onOpen = onOpen
        _selecting = State(initialValue: selecting)
    }

    private struct QueryRequest: Equatable {
        let profileID: UUID
        let conversations: [Conversation]
        let query: String
        let filter: MessageLibraryFilter
        let role: MessageLibraryRole
        let scope: MessageLibraryScope
        let tag: String?
        let project: ProjectFilter
        let projects: [LocalProject]
    }

    private var request: QueryRequest {
        QueryRequest(profileID: model.activeProfileID, conversations: model.conversations, query: query, filter: filter, role: role, scope: scope, tag: tag, project: project, projects: model.projects)
    }
    private var projectLabel: String {
        switch project {
        case .all: "全部项目"
        case .unassigned: "未分组"
        case .project(let id): model.projects.first { $0.id == id }?.name ?? "项目已不可用"
        }
    }
    private var availableTags: [String] { Array(Set(model.conversations.flatMap { $0.workspaceState.tags })).sorted() }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("\(model.activeProfileName) · \(scope.title) · \(results.count) 条结果")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                        if searching { ProgressView().controlSize(.mini) }
                    }
                    Picker("消息范围", selection: $filter) {
                        ForEach(MessageLibraryFilter.allCases) { Text($0.label).tag($0) }
                    }.pickerStyle(.segmented)
                    if tag != nil || scope != .all || role != .all || project != .all {
                        HStack {
                            Text([projectLabel, scope.title, role.label, tag.map { "#" + $0 } ?? "全部标签"].joined(separator: " · "))
                                .font(.caption).foregroundStyle(HermesTheme.accent).lineLimit(2)
                            Spacer()
                            Button("清除筛选") { scope = .all; role = .all; tag = nil; project = .all }.font(.caption)
                        }
                    }
                    if selecting {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("已选 \(selection.count) / \(MessageLibraryBatch.selectionLimit) 条").font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("清空选择") { selection = []; batchNotice = nil }.font(.caption).disabled(selection.isEmpty)
                            }
                            let visibleIDs = Set(results.map(\.id))
                            let hidden = selection.subtracting(visibleIDs).count
                            if hidden > 0 { Text("其中 \(hidden) 条被搜索或筛选隐藏，仍会纳入操作。").font(.caption).foregroundStyle(.orange) }
                            Button(!visibleIDs.isEmpty && visibleIDs.isSubset(of: selection) ? "取消选择当前结果" : "选择当前结果") {
                                selectVisible()
                            }.font(.subheadline).disabled(searching || results.isEmpty || model.needsRecovery)
                                .accessibilityIdentifier("library-batch-select-visible")
                            Text("检查最多 100 条、500,000 个正文与备注等文字字符；超限会提示，保留完整内容。")
                                .font(.caption2).foregroundStyle(HermesTheme.muted)
                        }.foregroundStyle(HermesTheme.accent).accessibilityIdentifier("library-batch-selection")
                    }
                    if model.needsRecovery { Text("本机数据需要恢复，批量整理暂不可用。").font(.caption).foregroundStyle(.orange) }
                    if let batchNotice { Label(batchNotice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
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
                        Group {
                            if selecting {
                                Button { toggleSelection(item.id) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        Image(systemName: selection.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(HermesTheme.accent).padding(.top, 9)
                                        MessageLibraryRow(item: item, query: query)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(model.needsRecovery)
                                    .accessibilityLabel("\(item.conversationTitle)，\(item.roleLabel)，\(selection.contains(item.id) ? "已选择" : "未选择")")
                                    .accessibilityIdentifier("library-batch-row-\(item.id.id)")
                            } else {
                                NavigationLink(value: item.id) { MessageLibraryRow(item: item, query: query) }
                                    .accessibilityIdentifier("library-row-\(item.id.id)")
                            }
                        }.listRowBackground(HermesTheme.surface)
                    }
                    .scrollContentBackground(.hidden)
                    .disabled(searching)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if selecting {
                    HStack(spacing: 8) {
                        Button { prepareBatch(operation: nil) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                        Button { prepareQuote() } label: { Label("引用到草稿", systemImage: "text.quote") }
                            .accessibilityIdentifier("library-batch-quote")
                        Menu {
                            Button { prepareBatch(operation: .add) } label: { Label("收藏所选消息", systemImage: "bookmark") }
                            Button(role: .destructive) { prepareBatch(operation: .remove) } label: { Label("取消所选收藏", systemImage: "bookmark.slash") }
                        } label: { Label("收藏", systemImage: "bookmark") }
                    }.font(.subheadline).buttonStyle(.bordered).frame(maxWidth: .infinity)
                        .padding(12).background(HermesTheme.surface)
                        .disabled(selection.isEmpty || model.needsRecovery)
                        .accessibilityIdentifier("library-batch-actions")
                }
            }
            .background(HermesTheme.background)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索正文、项目、标签或备注")
            .navigationTitle("本机消息库").navigationBarTitleDisplayMode(.inline)
            .task(id: request) {
                let snapshot = request
                searching = true
                do { if !snapshot.query.isEmpty { try await Task.sleep(for: .milliseconds(250)) } }
                catch { return }
                let search = Task.detached(priority: .userInitiated) {
                    MessageLibrary.items(in: snapshot.conversations, query: snapshot.query, filter: snapshot.filter,
                                         role: snapshot.role, scope: snapshot.scope, tag: snapshot.tag,
                                         project: snapshot.project, projects: snapshot.projects)
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
                if !embedded { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(selecting ? "完成多选" : "多选") {
                        selecting.toggle(); selection = []; batchNotice = nil
                    }.disabled(model.needsRecovery && !selecting).accessibilityIdentifier("library-batch-toggle")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("所属项目", selection: $project) {
                            Text("全部项目").tag(ProjectFilter.all)
                            Text("未分组").tag(ProjectFilter.unassigned)
                            ForEach(model.projects) { Text($0.name).tag(ProjectFilter.project($0.id)) }
                        }
                        Picker("消息角色", selection: $role) {
                            ForEach(MessageLibraryRole.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("对话范围", selection: $scope) {
                            ForEach(MessageLibraryScope.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("对话标签", selection: $tag) {
                            Text("全部标签").tag(String?.none)
                            ForEach(availableTags, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                    } label: {
                        Image(systemName: role == .all && scope == .all && tag == nil && project == .all ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                    .accessibilityLabel("筛选项目、角色、对话范围与标签")
                }
            }
        }
        .sheet(item: $exportedBatch) { snapshot in MessageLibraryBatchExportView(snapshot: snapshot) }
        .sheet(item: $quotedBatch) { snapshot in
            MessageDraftQuoteReviewView(snapshot: snapshot, onApplied: {
                selection = []
                batchNotice = "已将 \(snapshot.source.items.count) 条消息引用保存到「\(snapshot.destination.title)」的草稿，尚未发送"
            }, onShowDraft: {
                if let onShowDraft { onShowDraft() } else { dismiss() }
            })
        }
        .sheet(item: $bookmarkBatch) { route in
            MessageLibraryBookmarkReviewView(snapshot: route.snapshot, operation: route.operation) { report in
                bookmarkBatch = nil; selection = []
                batchNotice = "已\(route.operation == .add ? "收藏" : "取消收藏") \(report.changed) 条，\(report.unchanged) 条无需变更"
            }
        }
        .alert("消息批量操作暂不可用", isPresented: Binding(get: { batchError != nil }, set: { if !$0 { batchError = nil } })) {
            Button("知道了", role: .cancel) { batchError = nil }
        } message: { Text(batchError ?? "") }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
        .onChange(of: availableTags) { _, values in if let tag, !values.contains(tag) { self.tag = nil } }
        .onChange(of: model.activeProfileID) { _, _ in
            query = ""; scope = .all; role = .all; tag = nil; project = .all
            selection = []; selecting = false; batchNotice = nil; results = []; searching = true
        }
        .onChange(of: model.conversations) { _, _ in
            selection = Set(selection.filter { model.libraryItem($0) != nil })
        }
        .onChange(of: model.projects.map(\.id)) { _, ids in
            if case .project(let id) = project, !ids.contains(id) { project = .all }
        }
    }

    private func toggleSelection(_ target: LocalMessageTarget) {
        if selection.contains(target) { selection.remove(target) }
        else {
            guard selection.count < MessageLibraryBatch.selectionLimit else { batchError = MessageLibraryBatchError.selectionLimit.localizedDescription; return }
            selection.insert(target)
        }
        batchNotice = nil
    }
    private func selectVisible() {
        let ids = Set(results.map(\.id))
        if ids.isSubset(of: selection) { selection.subtract(ids) }
        else {
            let next = selection.union(ids)
            guard next.count <= MessageLibraryBatch.selectionLimit else { batchError = "当前结果加已选内容超过 100 条，请缩小筛选范围或逐条选择。"; return }
            selection = next
        }
        batchNotice = nil
    }
    private func prepareBatch(operation: MessageLibraryBatchOperation?) {
        do {
            let snapshot = try model.makeMessageLibraryBatch(Array(selection), profileID: model.activeProfileID)
            if let operation { bookmarkBatch = MessageLibraryBookmarkBatchRoute(snapshot: snapshot, operation: operation) }
            else { exportedBatch = snapshot }
        } catch { batchError = error.localizedDescription }
    }

    private func prepareQuote() {
        do { quotedBatch = try model.makeMessageDraftQuote(Array(selection), profileID: model.activeProfileID) }
        catch { batchError = error.localizedDescription }
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
            if let name = item.projectName {
                Label(name, systemImage: "folder").font(.caption).foregroundStyle(HermesTheme.accent).lineLimit(1)
            }
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
            if item.conversationArchived || !item.conversationTags.isEmpty {
                Text((item.conversationArchived ? "已归档 · " : "") + item.conversationTags.map { "#" + $0 }.joined(separator: " "))
                    .font(.caption).foregroundStyle(HermesTheme.accent).lineLimit(1)
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
    @State private var documentCapture: ProjectDocumentCapture?
    private var item: MessageLibraryItem? { model.libraryItem(target) }

    var body: some View {
        Group {
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.conversationTitle).font(.headline)
                            if let conversation = model.conversations.first(where: { $0.id == target.conversationID }),
                               let project = model.project(for: conversation) {
                                Label(project.name, systemImage: "folder").font(.caption).foregroundStyle(HermesTheme.accent)
                            }
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
                            if let conversation = model.conversations.first(where: { $0.id == target.conversationID }),
                               conversation.projectID != nil {
                                Button {
                                    perform { documentCapture = try model.captureProjectDocument(target, profileID: model.activeProfileID) }
                                } label: { Label("存为来源项目的资料", systemImage: "doc.badge.plus") }
                                    .disabled(model.needsRecovery || model.isSending || item.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
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
        .sheet(item: $documentCapture) { capture in ProjectDocumentCaptureView(capture: capture) }
        .alert("本机操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("知道了", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { failure = error.localizedDescription }
    }
}
