import SwiftUI

struct ProjectReferenceRemovalView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    @State private var documentIDs: [UUID]
    @State private var choosingDocuments: Bool
    @State private var selection: Set<UUID> = []
    @State private var query = ""
    @State private var review: ProjectReferenceRemovalReview?
    @State private var error: String?
    @State private var message: String?

    init(projectID: UUID, profileID: UUID, initialDocumentIDs: [UUID] = []) {
        self.projectID = projectID
        self.profileID = profileID
        _documentIDs = State(initialValue: initialDocumentIDs)
        _choosingDocuments = State(initialValue: initialDocumentIDs.isEmpty)
    }
    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var documents: [ProjectDocument] { ProjectDocumentBatch.ordered(project?.documents ?? []) }
    private var selectedDocuments: [ProjectDocument] { documentIDs.compactMap { id in documents.first { $0.id == id } } }
    private var records: [Conversation] {
        model.projectDocumentConversations(projectID: projectID, profileID: profileID).sorted {
            if status($0).order != status($1).order { return status($0).order < status($1).order }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    private var visible: [Conversation] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { text.isEmpty || $0.title.localizedStandardContains(text) }
    }
    private var unavailable: Bool { project == nil || model.needsRecovery || model.isSending }
    private var planIssue: String? {
        guard !unavailable, !documentIDs.isEmpty, !selection.isEmpty else { return nil }
        do { _ = try makeReview(); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let project, !model.needsRecovery {
                    List {
                        Section {
                            Label(project.name, systemImage: "folder").foregroundStyle(HermesTheme.accent)
                            Text("整理引用，保留资料。").font(.title2.bold())
                            Text("选择需要解除引用的资料，再明确选择目标对话。检查移除后的顺序与编号，确认后统一保存。")
                                .font(.subheadline).foregroundStyle(HermesTheme.muted)
                            if unavailable { Text("请先停止回复或等待完成后再整理引用。").font(.caption).foregroundStyle(.orange) }
                            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green).font(.subheadline) }
                        }.listRowBackground(HermesTheme.surface)
                        documentSections
                        conversationSections
                        Section {
                            if let planIssue { Text(planIssue).font(.subheadline).foregroundStyle(.orange) }
                            Button("检查移除前后方案", systemImage: "list.bullet.rectangle") {
                                do { review = try makeReview() } catch { self.error = error.localizedDescription }
                            }.disabled(unavailable || documentIDs.isEmpty || selection.isEmpty || planIssue != nil)
                                .accessibilityIdentifier("knowledge-removal-preview")
                        } footer: {
                            Text("可选择项目全部 20 篇资料。只更新明确选中对话的后续请求引用；资料仍保留在项目中。")
                        }.listRowBackground(HermesTheme.surface)
                    }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView("资料引用暂不可用", systemImage: "doc.badge.ellipsis",
                        description: Text("当前连接、项目或本机存储状态已改变，请返回检查。"))
                }
            }
            .background(HermesTheme.background).navigationTitle("批量移除资料引用").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索目标对话标题")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $review) { snapshot in
                ProjectReferenceRemovalReviewView(review: snapshot) {
                    review = nil; selection = []; message = "已为 \(snapshot.changedCount) 段对话移除资料引用"
                }
            }
            .alert("移除方案暂不可用", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: records.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .onChange(of: documents.map(\.id)) { _, ids in documentIDs.removeAll { !ids.contains($0) } }
            .onChange(of: model.activeProfileID) { _, _ in selection = []; documentIDs = []; message = nil }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }

    private var documentSections: some View {
        Group {
            if !selectedDocuments.isEmpty {
                Section("1 · 待移除引用的资料 · \(documentIDs.count) 篇") {
                    ForEach(selectedDocuments) { document in
                        Label(document.title, systemImage: "doc.text").font(.subheadline)
                    }
                }.listRowBackground(HermesTheme.surface)
            }
            Section(selectedDocuments.isEmpty ? "1 · 选择资料" : "选择或取消资料") {
                DisclosureGroup("查看并选择项目资料", isExpanded: $choosingDocuments) {
                ForEach(documents) { document in
                    Button {
                        if let index = documentIDs.firstIndex(of: document.id) { documentIDs.remove(at: index) }
                        else { documentIDs.append(document.id) }
                        message = nil
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: documentIDs.contains(document.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(HermesTheme.accent)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(document.title).font(.subheadline).foregroundStyle(.white)
                                Text("\(document.body.count.formatted()) 正文字符").font(.caption).foregroundStyle(HermesTheme.muted)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain).disabled(unavailable)
                        .accessibilityLabel("\(document.title)，\(documentIDs.contains(document.id) ? "已选择" : "未选择")")
                        .accessibilityIdentifier("knowledge-removal-document-\(document.id)")
                }
                if documents.isEmpty { Text("请先在项目中保存资料。").foregroundStyle(HermesTheme.muted) }
                }.accessibilityIdentifier("knowledge-removal-documents")
            }.listRowBackground(HermesTheme.surface)
        }
    }
    private var conversationSections: some View {
        Group {
            Section {
                Text("已选 \(selection.count) / \(records.count) 段对话").font(.headline)
                    .accessibilityIdentifier("knowledge-removal-count")
                let hidden = selection.subtracting(visible.map(\.id)).count
                if hidden > 0 { Text("另有 \(hidden) 段已选对话被搜索隐藏，仍纳入本次检查。").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("选择当前结果") { selection.formUnion(visible.map(\.id)); message = nil }
                        .disabled(unavailable || visible.isEmpty).accessibilityIdentifier("knowledge-removal-select-visible")
                    Spacer()
                    Button("清空选择") { selection = []; message = nil }.disabled(selection.isEmpty)
                }.font(.subheadline)
                if records.isEmpty { Text("本项目还没有可整理引用的对话。").font(.subheadline).foregroundStyle(HermesTheme.muted) }
            } header: { Text("2 · 明确选择目标对话") } footer: {
                Text("包含进行中、归档和回收站，初始不选择任何对话。不会恢复或打开回收站记录。")
            }.listRowBackground(HermesTheme.surface)
            ForEach(ProjectDocumentUsage.Status.allCases, id: \.self) { state in
                let conversations = visible.filter { status($0) == state }
                if !conversations.isEmpty {
                    Section(state.title) {
                        ForEach(conversations) { conversation in
                            Button {
                                if selection.contains(conversation.id) { selection.remove(conversation.id) }
                                else { selection.insert(conversation.id) }
                                message = nil
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: selection.contains(conversation.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(HermesTheme.accent)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(conversation.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                        let count = documentIDs.filter { (conversation.referenceDocumentIDs ?? []).contains($0) }.count
                                        Text("当前 \((conversation.referenceDocumentIDs ?? []).count) 篇" + (documentIDs.isEmpty ? "" : count == 0 ? " · 未引用所选资料，无需改动" : " · 将移除 \(count) 篇"))
                                            .font(.caption).foregroundStyle(HermesTheme.muted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(unavailable).accessibilityIdentifier("knowledge-removal-row-\(conversation.id)")
                                .accessibilityLabel("\(conversation.title)，\(selection.contains(conversation.id) ? "已选择" : "未选择")")
                        }
                    }.listRowBackground(HermesTheme.surface)
                }
            }
        }
    }
    private func status(_ conversation: Conversation) -> ProjectDocumentUsage.Status {
        conversation.isTrashed ? .trash : conversation.isArchived ? .archived : .active
    }
    private func makeReview() throws -> ProjectReferenceRemovalReview {
        try model.previewProjectReferenceRemoval(documentIDs: documentIDs, conversationIDs: selection, projectID: projectID, profileID: profileID)
    }
}

struct ProjectReferenceRemovalReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let review: ProjectReferenceRemovalReview
    let onApplied: () -> Void
    @State private var error: String?
    private var changeMessage: String? {
        do {
            let current = try model.previewProjectReferenceRemoval(documentIDs: review.removingDocuments.map(\.id),
                conversationIDs: Set(review.rows.map(\.id)), projectID: review.projectID, profileID: review.profileID)
            guard current.projectName == review.projectName, current.removingDocuments == review.removingDocuments,
                  current.documents == review.documents, current.rows == review.rows else { return ProjectReferenceRemovalError.changed.localizedDescription }
            return nil
        } catch { return error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(review.projectName, systemImage: "folder").foregroundStyle(HermesTheme.accent)
                    Text("为 \(review.changedCount) 段对话移除引用").font(.title2.bold())
                    Text("明确选中 \(review.rows.count) 段，其中 \(review.rows.count - review.changedCount) 段未引用所选资料、无需改动。保留其余资料的相对顺序，移除后按新顺序重新编号。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    if let changeMessage { Label(changeMessage, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) }
                }.listRowBackground(HermesTheme.surface)
                Section("将从所选对话解除引用的资料") {
                    ForEach(Array(review.removingDocuments.enumerated()), id: \.element.id) { index, document in
                        Text("\(index + 1). \(document.title)").font(.subheadline)
                    }
                }.listRowBackground(HermesTheme.surface)
                ForEach(review.rows) { row in
                    Section(row.status.title) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(row.title).font(.headline)
                            Text(row.hasChanges ? "移除 \(row.removedCount) 篇" : "未引用所选资料 · 保持原样").font(.caption).foregroundStyle(HermesTheme.accent)
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 24) {
                                    selectionList(row.beforeIDs, title: "移除前").frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                                    selectionList(row.afterIDs, title: "移除后").frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                                }
                                VStack(alignment: .leading, spacing: 16) {
                                    selectionList(row.beforeIDs, title: "移除前")
                                    selectionList(row.afterIDs, title: "移除后")
                                }
                            }
                        }.padding(.vertical, 8).accessibilityIdentifier("knowledge-removal-plan-\(row.id)")
                    }.listRowBackground(HermesTheme.surface)
                }
                Section("检查涉及资料全文 · 当前版本") {
                    ForEach(review.documents) { document in
                        DisclosureGroup("\(document.title) · \(document.body.count.formatted()) 字符") {
                            Text(document.body).font(.subheadline).textSelection(.enabled)
                        }
                    }
                }.listRowBackground(HermesTheme.surface)
                Section {
                    Button("确认更新 \(review.changedCount) 段对话的引用", systemImage: "minus.circle") {
                        do { try model.applyProjectReferenceRemoval(review); onApplied(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(changeMessage != nil).accessibilityIdentifier("knowledge-removal-apply")
                } footer: {
                    Text("保存前重新核对整批范围与资料版本，任一处过期则全部停止。资料仍在项目中；历史消息中的旧编号保持原文。只改变后续请求引用，原日期、草稿、图片和归档、回收站状态保留。")
                }.listRowBackground(HermesTheme.surface)
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
                .navigationTitle("引用移除检查").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回选择") { dismiss() } } }
                .alert("资料引用移除失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("知道了", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func selectionList(_ ids: [UUID], title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(HermesTheme.accent)
            Text("\(ids.count) 篇 · \(ids.reduce(0) { sum, id in sum + (review.documents.first { $0.id == id }?.body.count ?? 0) }.formatted()) 正文字符")
                .font(.caption).foregroundStyle(HermesTheme.muted)
            if ids.isEmpty { Text("暂无已保存的引用").font(.subheadline).foregroundStyle(HermesTheme.muted) }
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                Text("[资料\(index + 1)] " + (review.documents.first { $0.id == id }?.title ?? "资料已改变"))
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
