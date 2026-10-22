import SwiftUI

struct ProjectDocumentUsageControls: View {
    @Binding var filter: ProjectDocumentUsageFilter
    @Binding var sort: ProjectDocumentUsageSort
    var body: some View {
        Picker("引用筛选", selection: $filter) {
            ForEach(ProjectDocumentUsageFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).accessibilityIdentifier("knowledge-usage-filter")
        Picker("排序", selection: $sort) {
            ForEach(ProjectDocumentUsageSort.allCases) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("knowledge-usage-sort")
    }
}

private struct DocumentReferenceCounts: View {
    let references: [ProjectDocumentUsage.Reference]
    var body: some View {
        HStack(spacing: 10) {
            ForEach(ProjectDocumentUsage.Status.allCases, id: \.self) { status in
                VStack(alignment: .leading, spacing: 5) {
                    Text("\(references.filter { $0.status == status }.count)").font(.title3.weight(.semibold))
                    Text(status.title).font(.caption).foregroundStyle(HermesTheme.muted)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.accessibilityElement(children: .combine)
    }
}

private struct DocumentReferenceRow: View {
    let reference: ProjectDocumentUsage.Reference
    let documents: [ProjectDocument]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(reference.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(3)
            Text(reference.slots.map { slot in
                "[资料\(slot.number)] " + (documents.first { $0.id == slot.documentID }?.title ?? "资料已改变")
            }.joined(separator: "\n"))
                .font(.caption).foregroundStyle(HermesTheme.muted)
        }.padding(.vertical, 5)
    }
}

/// The numbers displayed here describe current saved selections, not historical requests.
struct ProjectDocumentUsageView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: UUID
    let profileID: UUID
    let documentID: UUID
    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var document: ProjectDocument? { project?.documents.first { $0.id == documentID } }
    private var references: [ProjectDocumentUsage.Reference] {
        ProjectDocumentUsage.references(documentIDs: [documentID], projectID: projectID, profileID: profileID,
            conversations: model.projectDocumentConversations(projectID: projectID, profileID: profileID))
    }
    var body: some View {
        Group {
            if let document, !model.needsRecovery {
                List {
                    Section {
                        Text(document.title).font(.title2.bold()).textSelection(.enabled)
                        Label(project?.name ?? "", systemImage: "folder").font(.caption).foregroundStyle(HermesTheme.accent)
                        Text("\(references.count) 段对话当前引用").font(.headline)
                            .accessibilityIdentifier("knowledge-usage-count")
                        DocumentReferenceCounts(references: references)
                        Text("数字来自对话当前已保存的资料选择，包含归档与回收站。编号只对应当前选择，不能据此判断历史回复使用了哪个版本。")
                            .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    }.listRowBackground(HermesTheme.surface)
                    if references.isEmpty {
                        Section {
                            Text("暂无已保存的引用").font(.headline)
                            Text("这不表示资料从未发送过。清理前可检查原对话，重要内容请先备份。")
                                .font(.subheadline).foregroundStyle(HermesTheme.muted)
                        }.listRowBackground(HermesTheme.surface)
                    }
                    ForEach(ProjectDocumentUsage.Status.allCases, id: \.self) { status in
                        let rows = references.filter { $0.status == status }
                        if !rows.isEmpty {
                            Section("\(status.title) · \(rows.count) 段") {
                                ForEach(rows) { reference in
                                    NavigationLink {
                                        ProjectReferenceConversationView(projectID: projectID, profileID: profileID,
                                            conversationID: reference.conversationID, inspectedDocumentIDs: [documentID])
                                    } label: {
                                        DocumentReferenceRow(reference: reference, documents: [document])
                                    }.accessibilityIdentifier("knowledge-usage-conversation-\(reference.id)")
                                }
                            }.listRowBackground(HermesTheme.surface)
                        }
                    }
                }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("引用情况暂不可用", systemImage: "link",
                    description: Text("资料、项目、连接或本机存储状态已改变，请返回检查。"))
            }
        }.background(HermesTheme.background)
            .navigationTitle("资料引用情况").navigationBarTitleDisplayMode(.inline)
            .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

/// Inspecting a source never selects, restores, edits or sends a conversation.
struct ProjectReferenceConversationView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: UUID
    let profileID: UUID
    let conversationID: UUID
    let inspectedDocumentIDs: Set<UUID>
    private var conversation: Conversation? {
        model.projectDocumentConversations(projectID: projectID, profileID: profileID).first { $0.id == conversationID }
    }
    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    var body: some View {
        Group {
            if let conversation, let project {
                let selected = (try? ProjectDocument.selected(ids: conversation.referenceDocumentIDs ?? [], from: project)) ?? []
                List {
                    Section {
                        Text(conversation.title).font(.title2.bold()).textSelection(.enabled)
                        Label(conversation.isTrashed ? "回收站 · 仅查看" : conversation.isArchived ? "已归档 · 仅查看" : "进行中 · 仅查看", systemImage: "eye")
                            .font(.subheadline).foregroundStyle(HermesTheme.accent)
                        Text("检查原消息及当前已保存的资料选择。查看不会切换聊天、恢复回收站记录或改动草稿。")
                            .font(.subheadline).foregroundStyle(HermesTheme.muted)
                        if selected.allSatisfy({ !inspectedDocumentIDs.contains($0.id) }) {
                            Text("当前已不再引用检查中的资料。").font(.subheadline).foregroundStyle(.orange)
                        }
                    }.listRowBackground(HermesTheme.surface)
                    Section {
                        ForEach(Array(selected.enumerated()), id: \.element.id) { index, document in
                            DisclosureGroup("[资料\(index + 1)] \(document.title)") {
                                Text(document.body).font(.subheadline).textSelection(.enabled)
                            }
                        }
                        if selected.isEmpty { Text("暂无已保存的资料选择").foregroundStyle(HermesTheme.muted) }
                    } header: { Text("当前已保存的全部资料选择") } footer: {
                        Text("这里展示资料最新正文，不代表历史请求的内容快照或历史回复的引用出处。")
                    }.listRowBackground(HermesTheme.surface)
                    Section("原消息 · \(conversation.messages.count) 条") {
                        ForEach(conversation.messages) { message in
                            InspectionMessageCard(message: message, directory: model.attachmentDirectory,
                                label: message.role == .user ? "我" : "Hermes")
                        }
                        if conversation.messages.isEmpty { Text("还没有消息").foregroundStyle(HermesTheme.muted) }
                    }.listRowBackground(HermesTheme.surface)
                }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView("这段对话已改变", systemImage: "text.bubble",
                    description: Text("记录可能已删除、移出项目或连接已切换，请返回检查。"))
            }
        }.background(HermesTheme.background)
            .navigationTitle("引用对话检查").navigationBarTitleDisplayMode(.inline)
            .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

struct ProjectDocumentDeletionReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let review: ProjectDocumentDeletionReview
    let onDeleted: () -> Void
    @State private var confirming = false
    @State private var error: String?
    private var changeMessage: String? {
        do {
            let current = try model.reviewProjectDocumentDeletion(review.documents, projectID: review.projectID, profileID: review.profileID)
            return current.references == review.references ? nil : ProjectDocumentUsageError.changedReferences.localizedDescription
        } catch { return error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(review.projectName, systemImage: "folder").foregroundStyle(HermesTheme.accent)
                    Text("删除 \(review.documents.count) 篇资料，影响 \(review.references.count) 段对话")
                        .font(.title3.bold()).accessibilityIdentifier("knowledge-deletion-summary")
                    DocumentReferenceCounts(references: review.references)
                    Text("将解除下列对话的相应引用。聊天、草稿、图片、收藏及其他资料保留；其他项目中的副本也会保留。删除无法直接撤销，重要内容请先备份。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    if let changeMessage {
                        Label(changeMessage, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).foregroundStyle(.orange).accessibilityIdentifier("knowledge-deletion-changed")
                    }
                }.listRowBackground(HermesTheme.surface)
                Section("本次删除的资料") {
                    ForEach(review.documents) { document in
                        DisclosureGroup(document.title) { Text(document.body).font(.subheadline).textSelection(.enabled) }
                    }
                }.listRowBackground(HermesTheme.surface)
                if review.references.isEmpty {
                    Section {
                        Text("当前没有已保存的对话引用这些资料。").font(.subheadline)
                        Text("这不表示从未发送过资料；已发送到服务端的内容不会因此撤回。")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                    }.listRowBackground(HermesTheme.surface)
                }
                ForEach(ProjectDocumentUsage.Status.allCases, id: \.self) { status in
                    let rows = review.references.filter { $0.status == status }
                    if !rows.isEmpty {
                        Section("\(status.title) · \(rows.count) 段受影响") {
                            ForEach(rows) { reference in
                                NavigationLink {
                                    ProjectReferenceConversationView(projectID: review.projectID, profileID: review.profileID,
                                        conversationID: reference.conversationID, inspectedDocumentIDs: Set(review.documents.map(\.id)))
                                } label: {
                                    DocumentReferenceRow(reference: reference, documents: review.documents)
                                }.disabled(changeMessage != nil)
                            }
                        }.listRowBackground(HermesTheme.surface)
                    }
                }
                Section {
                    Button("删除资料并解除引用", systemImage: "trash", role: .destructive) { confirming = true }
                        .disabled(changeMessage != nil).accessibilityIdentifier("knowledge-deletion-confirm")
                } footer: {
                    Text("再次确认时会重新检查资料与引用范围。发生变化需关闭本页后重新检查。")
                }.listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("删除前检查").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("保留资料") { dismiss() } } }
            .confirmationDialog("确认删除 \(review.documents.count) 篇资料？", isPresented: $confirming, titleVisibility: .visible) {
                Button("确认删除并解除引用", role: .destructive) { delete() }
                Button("保留资料", role: .cancel) {}
            } message: { Text("将影响 \(review.references.count) 段对话的资料选择，删除无法直接撤销。") }
            .alert("删除失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func delete() {
        do { try model.deleteReviewedProjectDocuments(review); onDeleted(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
