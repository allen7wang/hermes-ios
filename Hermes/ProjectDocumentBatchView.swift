import SwiftUI
import UIKit

private struct DocumentBatchReview: Identifiable {
    let id = UUID()
    let documents: [ProjectDocument]
    let projectName: String
}

struct ProjectDocumentBatchView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    @State private var query = ""
    @State private var selection: Set<UUID> = []
    @State private var copyReview: DocumentBatchReview?
    @State private var exportReview: DocumentBatchReview?
    @State private var deletionReview: ProjectDocumentDeletionReview?
    @State private var usageFilter: ProjectDocumentUsageFilter = .all
    @State private var usageSort: ProjectDocumentUsageSort = .recent
    @State private var error: String?
    @State private var message: String?

    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var documents: [ProjectDocument] { ProjectDocumentBatch.ordered(project?.documents ?? []) }
    private var references: [ProjectDocumentUsage.Reference] {
        ProjectDocumentUsage.references(documentIDs: Set(documents.map(\.id)), projectID: projectID, profileID: profileID,
            conversations: model.projectDocumentConversations(projectID: projectID, profileID: profileID))
    }
    private var visible: [ProjectDocument] {
        ProjectDocumentUsage.filtered(documents, query: query, filter: usageFilter, sort: usageSort, references: references)
    }
    private var selected: [ProjectDocument] { documents.filter { selection.contains($0.id) } }
    private var unavailable: Bool { project == nil || model.isSending || model.needsRecovery }
    private var allVisibleSelected: Bool { !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(project?.name ?? "项目已改变", systemImage: "folder").foregroundStyle(HermesTheme.accent)
                    Text("先选择，再整理。所有操作仅限当前连接。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    Text("已选 \(selected.count) 篇 · \(selected.reduce(0) { $0 + $1.body.count }.formatted()) 正文字符")
                        .font(.headline).accessibilityIdentifier("knowledge-batch-count")
                    let hidden = selected.filter { item in !visible.contains { $0.id == item.id } }.count
                    if hidden > 0 {
                        Text("其中 \(hidden) 篇被搜索或引用筛选隐藏，仍在本次选择中。")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    HStack {
                        Button(allVisibleSelected ? "取消选择当前结果" : "选择当前结果") {
                            let ids = Set(visible.map(\.id))
                            if allVisibleSelected { selection.subtract(ids) } else { selection.formUnion(ids) }
                            message = nil
                        }.disabled(visible.isEmpty || unavailable).accessibilityIdentifier("knowledge-batch-select-visible")
                        Spacer()
                        Button("清空选择") { selection = []; message = nil }.disabled(selection.isEmpty)
                    }.font(.subheadline)
                    if let message { Label(message, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.green) }
                    if unavailable { Text("当前连接、项目或写入状态暂不可用，请返回检查。 ").font(.caption).foregroundStyle(.orange) }
                }.listRowBackground(HermesTheme.surface)
                Section {
                    ProjectDocumentUsageControls(filter: $usageFilter, sort: $usageSort)
                        .disabled(model.needsRecovery || project == nil)
                } footer: {
                    Text(model.needsRecovery ? "本机存储需要恢复，引用统计暂不可用。" : "引用包含归档和回收站。未引用只表示当前没有保存的选择，请检查后再清理。")
                }.listRowBackground(HermesTheme.surface)
                Section("\(visible.count) 篇当前结果") {
                    ForEach(visible) { document in
                        Button {
                            if selection.contains(document.id) { selection.remove(document.id) } else { selection.insert(document.id) }
                            message = nil
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selection.contains(document.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(HermesTheme.accent).padding(.top, 8)
                                ProjectDocumentRow(document: document, referenceCount: model.needsRecovery ? nil : ProjectDocumentUsage.forDocument(document.id, in: references).count)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(unavailable)
                            .accessibilityLabel("\(document.title)，\(selection.contains(document.id) ? "已选择" : "未选择")")
                            .accessibilityIdentifier("knowledge-batch-row-\(document.id)")
                    }
                    if visible.isEmpty { Text("没有匹配的资料").foregroundStyle(HermesTheme.muted) }
                }.listRowBackground(HermesTheme.surface)
                Section {
                    Button("检查并导出 Markdown", systemImage: "square.and.arrow.up") {
                        review { exportReview = $0 }
                    }.accessibilityIdentifier("knowledge-batch-export")
                    Button("复制到其他项目", systemImage: "doc.on.doc") {
                        review { copyReview = $0 }
                    }.accessibilityIdentifier("knowledge-batch-copy")
                    Button("检查并删除所选资料", systemImage: "trash", role: .destructive) {
                        review {
                            do { deletionReview = try model.reviewProjectDocumentDeletion($0.documents, projectID: projectID, profileID: profileID) }
                            catch { self.error = error.localizedDescription }
                        }
                    }.accessibilityIdentifier("knowledge-batch-delete")
                } header: { Text("所选资料") } footer: {
                    Text("复制会新建独立资料，保留同名项；原资料和对话引用保持原状。删除需再次确认，并解除所有相关对话的引用。")
                }.disabled(unavailable || selected.isEmpty).listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .searchable(text: $query, prompt: "搜索标题或正文")
            .navigationTitle("批量整理资料").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $copyReview) { review in
                ProjectDocumentCopyView(projectID: projectID, profileID: profileID, documents: review.documents) { count, name in
                    copyReview = nil; message = "已复制 \(count) 篇到「\(name)」"
                }
            }
            .sheet(item: $exportReview) { review in
                ProjectDocumentExportView(projectName: review.projectName, documents: review.documents)
            }
            .sheet(item: $deletionReview) { review in
                ProjectDocumentDeletionReviewView(review: review) {
                    selection.subtract(review.documents.map(\.id))
                    message = "已删除 \(review.documents.count) 篇资料并解除相关引用"
                    deletionReview = nil
                }
            }
            .alert("资料操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: documents.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .onChange(of: model.activeProfileID) { _, _ in selection = []; message = nil }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }

    private func review(_ present: (DocumentBatchReview) -> Void) {
        do {
            guard !unavailable, let project else { throw ProjectError.changedContext }
            present(DocumentBatchReview(documents: try ProjectDocumentBatch.selected(selection, in: project), projectName: project.name))
        } catch { self.error = error.localizedDescription }
    }
}

struct ProjectDocumentCopyView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    let documents: [ProjectDocument]
    let onCopied: (Int, String) -> Void
    @State private var targetID: UUID?
    @State private var error: String?

    private var source: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var targets: [LocalProject] { source == nil ? [] : model.projects.filter { $0.id != projectID } }
    private var target: LocalProject? { targets.first { $0.id == targetID } }
    private var sourceChanged: Bool {
        guard let source else { return true }
        do { try ProjectDocumentBatch.validate(documents, in: source); return false } catch { return true }
    }
    private func capacityOK(_ project: LocalProject) -> Bool {
        do { try ProjectDocumentBatch.validateCapacity(documents, target: project); return true } catch { return false }
    }
    private var canCopy: Bool { !sourceChanged && !model.isSending && !model.needsRecovery && target.map(capacityOK) == true }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(source?.name ?? "来源项目已改变", systemImage: "folder")
                    Text("复制 \(documents.count) 篇 · \(documents.reduce(0) { $0 + $1.body.count }.formatted()) 正文字符").font(.headline)
                    Text("确认后一次性保存到目标项目。同名资料会作为独立副本保留，复制后的编辑互不影响。需要使用时，再在目标对话中选择引用。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    if sourceChanged { Text("所选资料已改变，请关闭并重新选择。").foregroundStyle(.orange) }
                }.listRowBackground(HermesTheme.surface)
                Section("选择目标项目") {
                    if targets.isEmpty { Text("请先在当前连接中创建另一个项目。").foregroundStyle(HermesTheme.muted) }
                    ForEach(targets) { project in
                        Button { targetID = project.id } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: targetID == project.id ? "checkmark.circle.fill" : "circle").foregroundStyle(HermesTheme.accent)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(project.name).foregroundStyle(.white)
                                    Text("复制后 \(project.documents.count + documents.count) / 20 篇 · \((project.documents + documents).reduce(0) { $0 + $1.body.count }.formatted()) / 200,000 字符")
                                        .font(.caption).foregroundStyle(capacityOK(project) ? HermesTheme.muted : .orange)
                                    if !capacityOK(project) { Text("容量不足，请先整理目标项目").font(.caption).foregroundStyle(.orange) }
                                }
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(!capacityOK(project) || sourceChanged || model.isSending || model.needsRecovery)
                            .accessibilityIdentifier("knowledge-copy-target-\(project.id)")
                    }
                }.listRowBackground(HermesTheme.surface)
                Section("本次资料快照") {
                    ForEach(documents) { document in
                        DisclosureGroup(document.title) { Text(document.body).font(.subheadline).textSelection(.enabled) }
                    }
                }.listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("复制项目资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认复制") { copy() }.disabled(!canCopy).accessibilityIdentifier("knowledge-copy-confirm")
                }
            }
            .alert("复制失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func copy() {
        guard let target else { return }
        do {
            let ids = try model.copyProjectDocuments(documents, fromProject: projectID, toProject: target.id, profileID: profileID)
            onCopied(ids.count, target.name); dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ProjectDocumentExportView: View {
    @Environment(\.dismiss) private var dismiss
    let projectName: String
    let documents: [ProjectDocument]
    @State private var exporting = false
    @State private var exportedDocument: ConversationDocument?
    @State private var copied = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(projectName, systemImage: "folder").foregroundStyle(HermesTheme.accent)
                    Text("\(documents.count) 篇资料的完整文字").font(.headline)
                    Text("按下列顺序生成一份 Markdown 汇编。此页保留打开时的资料快照，后续编辑需关闭后重新选择。恢复项目与引用关系请使用 JSON 备份。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                }.listRowBackground(HermesTheme.surface)
                Section("检查本次内容") {
                    ForEach(Array(documents.enumerated()), id: \.element.id) { index, document in
                        DisclosureGroup("\(index + 1). \(document.title)") {
                            Text(document.body).font(.subheadline).textSelection(.enabled)
                        }
                    }
                }.listRowBackground(HermesTheme.surface)
                Section {
                    Button("导出 Markdown 文件", systemImage: "square.and.arrow.up") {
                        do { exportedDocument = ConversationDocument(text: try markdown()); exporting = true }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("knowledge-batch-export-file")
                    Button(copied ? "汇编已复制" : "复制完整汇编", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        do { UIPasteboard.general.string = try markdown(); copied = true }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("knowledge-batch-export-copy")
                }.listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("导出资料汇编").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .fileExporter(isPresented: $exporting, document: exportedDocument, contentType: ConversationDocument.markdownType,
                defaultFilename: ConversationWorkbench.filename(projectName + "-资料汇编")) { result in
                if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription }
            }
            .alert("导出失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func markdown() throws -> String { try ProjectDocumentBatch.markdown(projectName: projectName, documents: documents) }
}
