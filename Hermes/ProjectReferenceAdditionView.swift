import SwiftUI

struct ProjectReferenceAdditionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    @State private var documentIDs: [UUID]
    @State private var choosingDocuments: Bool
    @State private var selection: Set<UUID> = []
    @State private var query = ""
    @State private var review: ProjectReferenceAdditionReview?
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
                            Text("让新资料，加入后续讨论。").font(.title2.bold())
                            Text("选择同项目资料与目标对话。保留原引用顺序，只把尚未引用的资料追加到末尾；先检查，再保存。")
                                .font(.subheadline).foregroundStyle(HermesTheme.muted)
                            if unavailable { Text("请先停止回复或等待完成后再整理引用。").font(.caption).foregroundStyle(.orange) }
                            if let message { Label(message, systemImage: "checkmark.circle").foregroundStyle(.green).font(.subheadline) }
                        }.listRowBackground(HermesTheme.surface)
                        documentSections
                        conversationSections
                        Section {
                            if let planIssue { Text(planIssue).font(.subheadline).foregroundStyle(.orange) }
                            Button("检查添加前后方案", systemImage: "list.bullet.rectangle") {
                                do { review = try makeReview() } catch { self.error = error.localizedDescription }
                            }.disabled(unavailable || documentIDs.isEmpty || selection.isEmpty || planIssue != nil)
                                .accessibilityIdentifier("knowledge-addition-preview")
                        } footer: {
                            Text("每段对话最多 5 篇、50,000 正文字符，任一段超限则整批停止。保存只影响后续请求，不会发送消息。")
                        }.listRowBackground(HermesTheme.surface)
                    }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView("资料引用暂不可用", systemImage: "doc.badge.ellipsis",
                        description: Text("当前连接、项目或本机存储状态已改变，请返回检查。"))
                }
            }
            .background(HermesTheme.background).navigationTitle("批量添加资料引用").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索目标对话标题")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $review) { snapshot in
                ProjectReferenceAdditionReviewView(review: snapshot) {
                    review = nil; selection = []; message = "已为 \(snapshot.changedCount) 段对话添加资料引用"
                }
            }
            .alert("添加方案暂不可用", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
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
                Section {
                    ForEach(Array(selectedDocuments.enumerated()), id: \.element.id) { index, document in
                        HStack(alignment: .top, spacing: 12) {
                            Text("\(index + 1)").foregroundStyle(HermesTheme.accent).monospacedDigit()
                            Text(document.title).font(.subheadline)
                            Spacer(minLength: 0)
                            Button { move(document.id, by: -1) } label: { Image(systemName: "arrow.up") }
                                .disabled(unavailable || index == 0).accessibilityLabel("上移 \(document.title)")
                            Button { move(document.id, by: 1) } label: { Image(systemName: "arrow.down") }
                                .disabled(unavailable || index == selectedDocuments.count - 1).accessibilityLabel("下移 \(document.title)")
                        }.buttonStyle(.borderless)
                    }
                } header: { Text("1 · 待追加资料顺序 · \(documentIDs.count) / 5 篇") }
                footer: { Text("已经存在的引用保留原编号，不因这里的顺序而移动。只有新的引用按此顺序追加。") }
                .listRowBackground(HermesTheme.surface)
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
                    }.buttonStyle(.plain).disabled(unavailable || (!documentIDs.contains(document.id) && documentIDs.count >= ProjectDocument.selectionLimit))
                        .accessibilityLabel("\(document.title)，\(documentIDs.contains(document.id) ? "已选择" : "未选择")")
                        .accessibilityIdentifier("knowledge-addition-document-\(document.id)")
                }
                if documents.isEmpty { Text("请先在项目中保存资料。").foregroundStyle(HermesTheme.muted) }
                }.accessibilityIdentifier("knowledge-addition-documents")
            }.listRowBackground(HermesTheme.surface)
        }
    }
    private var conversationSections: some View {
        Group {
            Section {
                Text("已选 \(selection.count) / \(records.count) 段对话").font(.headline)
                    .accessibilityIdentifier("knowledge-addition-count")
                let hidden = selection.subtracting(visible.map(\.id)).count
                if hidden > 0 { Text("另有 \(hidden) 段已选对话被搜索隐藏，仍纳入本次检查。").font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button("选择当前结果") { selection.formUnion(visible.map(\.id)); message = nil }
                        .disabled(unavailable || visible.isEmpty).accessibilityIdentifier("knowledge-addition-select-visible")
                    Spacer()
                    Button("清空选择") { selection = []; message = nil }.disabled(selection.isEmpty)
                }.font(.subheadline)
                if records.isEmpty { Text("本项目还没有对话。请先创建项目对话，再添加资料引用。").font(.subheadline).foregroundStyle(HermesTheme.muted) }
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
                                        let count = documentIDs.filter { !(conversation.referenceDocumentIDs ?? []).contains($0) }.count
                                        Text("当前 \((conversation.referenceDocumentIDs ?? []).count) 篇" + (documentIDs.isEmpty ? "" : count == 0 ? " · 已全部引用，无需改动" : " · 将追加 \(count) 篇"))
                                            .font(.caption).foregroundStyle(HermesTheme.muted)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(unavailable).accessibilityIdentifier("knowledge-addition-row-\(conversation.id)")
                                .accessibilityLabel("\(conversation.title)，\(selection.contains(conversation.id) ? "已选择" : "未选择")")
                        }
                    }.listRowBackground(HermesTheme.surface)
                }
            }
        }
    }
    private func move(_ id: UUID, by offset: Int) {
        guard let index = documentIDs.firstIndex(of: id), documentIDs.indices.contains(index + offset) else { return }
        documentIDs.swapAt(index, index + offset); message = nil
    }
    private func status(_ conversation: Conversation) -> ProjectDocumentUsage.Status {
        conversation.isTrashed ? .trash : conversation.isArchived ? .archived : .active
    }
    private func makeReview() throws -> ProjectReferenceAdditionReview {
        try model.previewProjectReferenceAddition(documentIDs: documentIDs, conversationIDs: selection, projectID: projectID, profileID: profileID)
    }
}

struct ProjectReferenceAdditionReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let review: ProjectReferenceAdditionReview
    let onApplied: () -> Void
    @State private var error: String?
    private var changeMessage: String? {
        do {
            let current = try model.previewProjectReferenceAddition(documentIDs: review.addingDocuments.map(\.id),
                conversationIDs: Set(review.rows.map(\.id)), projectID: review.projectID, profileID: review.profileID)
            guard current.projectName == review.projectName, current.addingDocuments == review.addingDocuments,
                  current.documents == review.documents, current.rows == review.rows else { return ProjectReferenceAdditionError.changed.localizedDescription }
            return nil
        } catch { return error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(review.projectName, systemImage: "folder").foregroundStyle(HermesTheme.accent)
                    Text("为 \(review.changedCount) 段对话添加引用").font(.title2.bold())
                    Text("明确选中 \(review.rows.count) 段，其中 \(review.rows.count - review.changedCount) 段已包含全部资料、无需改动。原有引用位置保持，新的资料仅追加到末尾。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    if let changeMessage { Label(changeMessage, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) }
                }.listRowBackground(HermesTheme.surface)
                Section("待追加资料 · 按选择顺序") {
                    ForEach(Array(review.addingDocuments.enumerated()), id: \.element.id) { index, document in
                        Text("\(index + 1). \(document.title)").font(.subheadline)
                    }
                }.listRowBackground(HermesTheme.surface)
                ForEach(review.rows) { row in
                    Section(row.status.title) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(row.title).font(.headline)
                            Text(row.hasChanges ? "追加 \(row.addedCount) 篇" : "已全部引用 · 保持原样").font(.caption).foregroundStyle(HermesTheme.accent)
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 24) {
                                    selectionList(row.beforeIDs, title: "添加前").frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                                    selectionList(row.afterIDs, title: "添加后").frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                                }
                                VStack(alignment: .leading, spacing: 16) {
                                    selectionList(row.beforeIDs, title: "添加前")
                                    selectionList(row.afterIDs, title: "添加后")
                                }
                            }
                        }.padding(.vertical, 8).accessibilityIdentifier("knowledge-addition-plan-\(row.id)")
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
                    Button("确认更新 \(review.changedCount) 段对话的引用", systemImage: "plus.circle") {
                        do { try model.applyProjectReferenceAddition(review); onApplied(); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(changeMessage != nil).accessibilityIdentifier("knowledge-addition-apply")
                } footer: {
                    Text("保存前重新核对整批范围与资料版本，过期或超限时全部停止。不会修改历史消息、日期、草稿或图片，也不会发送请求；回收站和归档状态保留。字符量不是模型令牌量。")
                }.listRowBackground(HermesTheme.surface)
            }.listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
                .navigationTitle("引用添加检查").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回选择") { dismiss() } } }
                .alert("资料引用添加失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
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
