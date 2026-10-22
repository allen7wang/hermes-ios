import SwiftUI
import UniformTypeIdentifiers
import UIKit

private struct ProjectDocumentRoute: Hashable {
    let documentID: UUID
}

private struct ProjectDocumentEditorTarget: Identifiable {
    let id = UUID()
    var document: ProjectDocument? = nil
    var importedDocument: ProjectDocument? = nil
    var sourceFilename: String? = nil
}

private struct ImportedProjectDocumentText: Sendable {
    let title: String
    let body: String
}

private enum ProjectDocumentFileReader {
    nonisolated static func read(_ url: URL) throws -> ImportedProjectDocumentText {
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: ProjectDocument.importByteLimit + 1) ?? Data()
        try Task.checkCancellation()
        let document = try ProjectDocument.importText(data: data, filename: url.lastPathComponent)
        return ImportedProjectDocumentText(title: document.title, body: document.body)
    }
}

struct ProjectKnowledgeView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: UUID
    let profileID: UUID
    @State private var query = ""
    @State private var editor: ProjectDocumentEditorTarget?
    @State private var importing = false
    @State private var readingFile = false
    @State private var importTask: Task<Void, Never>?
    @State private var importRequestID: UUID?
    @State private var viewActive = false
    @State private var error: String?
    @State private var managing = false
    @State private var usageFilter: ProjectDocumentUsageFilter = .all
    @State private var usageSort: ProjectDocumentUsageSort = .recent

    private var project: LocalProject? {
        model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil
    }
    private var documents: [ProjectDocument] { project?.documents ?? [] }
    private var characterCount: Int { documents.reduce(0) { $0 + $1.body.count } }
    private var references: [ProjectDocumentUsage.Reference] {
        ProjectDocumentUsage.references(documentIDs: Set(documents.map(\.id)), projectID: projectID, profileID: profileID,
            conversations: model.projectDocumentConversations(projectID: projectID, profileID: profileID))
    }
    private var visible: [ProjectDocument] {
        ProjectDocumentUsage.filtered(documents, query: query, filter: usageFilter, sort: usageSort, references: references)
    }
    private var unavailable: Bool { project == nil || model.isSending || model.needsRecovery }
    private var canAdd: Bool { !unavailable && !readingFile && documents.count < ProjectDocument.collectionLimit && characterCount < ProjectDocument.projectCharacterLimit }
    private var importTypes: [UTType] { [.plainText, UTType(filenameExtension: "md") ?? .plainText] }

    var body: some View {
        Group {
            if let project {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(project.name, systemImage: "folder").font(.caption.weight(.semibold)).foregroundStyle(HermesTheme.accent)
                            Text("让参考资料，跟着项目走。")
                                .font(.title2.bold())
                            Text("保存背景材料、约定或笔记，再在每段对话里选择要携带的资料。仅选中内容随请求发送，不会自动读取全部资料或联网查找。")
                                .font(.subheadline).foregroundStyle(HermesTheme.muted)
                            HStack(spacing: 12) {
                                knowledgeMetric("资料", value: "\(documents.count) / \(ProjectDocument.collectionLimit)")
                                knowledgeMetric("正文字符", value: characterCount.formatted())
                            }
                            HStack(spacing: 12) {
                                Button("新建资料", systemImage: "doc.badge.plus") { editor = ProjectDocumentEditorTarget() }
                                    .accessibilityIdentifier("knowledge-create")
                                Spacer(minLength: 8)
                                Button("导入文件", systemImage: "square.and.arrow.down") { importing = true }
                                    .accessibilityIdentifier("knowledge-import")
                            }.font(.subheadline.weight(.medium)).foregroundStyle(HermesTheme.accent).disabled(!canAdd)
                            if readingFile {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("正在读取文件…").font(.caption).foregroundStyle(HermesTheme.muted)
                                }.accessibilityIdentifier("knowledge-import-progress")
                            }
                            Text("支持 UTF-8 的 .txt / .md 文件，单文件最多 256 KiB。导入后先检查编辑，再点击保存。")
                                .font(.caption).foregroundStyle(HermesTheme.muted)
                            Button("批量整理资料", systemImage: "checklist") { managing = true }
                                .disabled(unavailable || documents.isEmpty || readingFile)
                                .accessibilityIdentifier("knowledge-batch")
                            if documents.count >= ProjectDocument.collectionLimit || characterCount >= ProjectDocument.projectCharacterLimit {
                                Text("资料库已达到数量或正文字符上限。可以编辑或删除已有资料，再添加新内容。")
                                    .font(.caption).foregroundStyle(.orange)
                            }
                        }.padding(.vertical, 8)
                    }.listRowBackground(Color.clear).listRowSeparator(.hidden)
                    Section {
                        ProjectDocumentUsageControls(filter: $usageFilter, sort: $usageSort)
                            .disabled(model.needsRecovery)
                    } footer: {
                        Text(model.needsRecovery ? "本机存储需要恢复，引用统计暂不可用。" : "统计当前已保存的对话选择，包含归档与回收站。未引用不表示从未发送过这份资料。")
                    }.listRowBackground(HermesTheme.surface)
                    Section("\(visible.count) 篇资料") {
                        if visible.isEmpty {
                            ContentUnavailableView(documents.isEmpty ? "还没有参考资料" : "没有匹配的资料",
                                systemImage: "doc.text.magnifyingglass",
                                description: Text(documents.isEmpty ? "新建一篇资料，或导入文本文件。保存资料不会自动把它加入任何对话。" : "调整引用筛选或搜索关键词后再试。"))
                                .listRowBackground(Color.clear)
                        }
                        ForEach(visible) { document in
                            NavigationLink(value: ProjectDocumentRoute(documentID: document.id)) {
                                ProjectDocumentRow(document: document, referenceCount: model.needsRecovery ? nil : ProjectDocumentUsage.forDocument(document.id, in: references).count)
                            }.listRowBackground(HermesTheme.surface).accessibilityIdentifier("knowledge-row-\(document.id)")
                        }
                    }
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
                .searchable(text: $query, prompt: "搜索资料标题或正文")
                .navigationDestination(for: ProjectDocumentRoute.self) { route in
                    ProjectDocumentDetailView(projectID: projectID, profileID: profileID, documentID: route.documentID)
                }
            } else {
                ContentUnavailableView("资料库暂时无法打开", systemImage: "folder.badge.questionmark",
                    description: Text(model.activeProfileID != profileID ? "当前连接已改变，请返回后重新打开。" : "项目可能已解散，请返回项目列表。"))
                    .background(HermesTheme.background)
            }
        }
        .navigationTitle("项目资料库").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("新建资料", systemImage: "doc.badge.plus") { editor = ProjectDocumentEditorTarget() }
                    Button("导入 .txt / .md", systemImage: "square.and.arrow.down") { importing = true }
                } label: { Image(systemName: "plus") }
                    .disabled(!canAdd).accessibilityLabel("添加项目资料")
            }
        }
        .sheet(item: $editor) { target in
            ProjectDocumentEditorView(projectID: projectID, profileID: profileID, document: target.document,
                importedDocument: target.importedDocument, sourceFilename: target.sourceFilename) { editor = nil }
        }
        .sheet(isPresented: $managing) {
            ProjectDocumentBatchView(projectID: projectID, profileID: profileID)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: importTypes, allowsMultipleSelection: false) { result in
            importFile(result)
        }
        .alert("资料导入失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
        .onAppear { viewActive = true }
        .onDisappear {
            if !importing && editor == nil && !managing {
                viewActive = false
                cancelImport()
            }
        }
        .onChange(of: model.activeProfileID) { _, _ in importing = false; cancelImport() }
    }

    private func knowledgeMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value).font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.6)
            Text(title).font(.caption).foregroundStyle(HermesTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func importFile(_ result: Result<[URL], Error>) {
        guard viewActive, model.activeProfileID == profileID, project != nil else { return }
        do {
            guard let url = try result.get().first else { return }
            guard viewActive, canAdd else { error = "当前连接、项目或资料库状态已改变，请返回检查后重试。"; return }
            let requestID = UUID()
            importRequestID = requestID
            readingFile = true
            importTask = Task { @MainActor in
                let read = Task.detached(priority: .userInitiated) { try ProjectDocumentFileReader.read(url) }
                do {
                    let imported = try await withTaskCancellationHandler(operation: { try await read.value }, onCancel: { read.cancel() })
                    guard importRequestID == requestID else { return }
                    importRequestID = nil
                    importTask = nil
                    readingFile = false
                    guard !Task.isCancelled, viewActive, model.activeProfileID == profileID, project != nil else { return }
                    guard canAdd else { error = "资料库状态已改变，导入内容尚未保存，请检查后重试。"; return }
                    let document = ProjectDocument(title: imported.title, body: imported.body)
                    editor = ProjectDocumentEditorTarget(importedDocument: document, sourceFilename: url.lastPathComponent)
                } catch {
                    guard importRequestID == requestID else { return }
                    importRequestID = nil
                    importTask = nil
                    readingFile = false
                    guard !Task.isCancelled, !(error is CancellationError), viewActive,
                          model.activeProfileID == profileID, project != nil else { return }
                    self.error = error.localizedDescription
                }
            }
        } catch {
            if (error as? CocoaError)?.code != .userCancelled { self.error = error.localizedDescription }
        }
    }
    private func cancelImport() {
        importTask?.cancel()
        importTask = nil
        importRequestID = nil
        readingFile = false
    }
}

struct ProjectDocumentRow: View {
    let document: ProjectDocument
    var referenceCount: Int? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(document.title, systemImage: "doc.text").font(.subheadline.weight(.semibold)).foregroundStyle(.white).lineLimit(2)
            Text(document.body).font(.subheadline).foregroundStyle(HermesTheme.muted).lineLimit(2)
            if let referenceCount {
                Label(referenceCount == 0 ? "暂无已保存的引用" : "\(referenceCount) 段对话引用", systemImage: "link")
                    .font(.caption).foregroundStyle(referenceCount == 0 ? HermesTheme.muted : HermesTheme.accent)
            }
            HStack {
                Text("\(document.body.count.formatted()) 字符")
                Spacer(minLength: 8)
                Text(document.updatedAt, style: .date)
            }.font(.caption2).foregroundStyle(HermesTheme.muted)
        }.padding(.vertical, 7)
    }
}

struct ProjectDocumentDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    let documentID: UUID
    @State private var editingDocument: ProjectDocument?
    @State private var deletionReview: ProjectDocumentDeletionReview?
    @State private var replacingReferences = false
    @State private var copied = false
    @State private var exportedDocument: ConversationDocument?
    @State private var exporting = false
    @State private var error: String?

    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var document: ProjectDocument? { project?.documents.first { $0.id == documentID } }
    private var unavailable: Bool { document == nil || model.isSending || model.needsRecovery }

    var body: some View {
        Group {
            if let document {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(document.title).font(.title2.bold()).textSelection(.enabled)
                            Text(project?.name ?? "").font(.caption).foregroundStyle(HermesTheme.accent)
                            HStack {
                                Text("\(document.body.count.formatted()) 字符")
                                Spacer()
                                Text("更新于 ") + Text(document.updatedAt, style: .date)
                            }.font(.caption).foregroundStyle(HermesTheme.muted)
                        }.padding(.vertical, 8)
                    }.listRowBackground(Color.clear)
                    Section {
                        NavigationLink {
                            ProjectDocumentUsageView(projectID: projectID, profileID: profileID, documentID: documentID)
                        } label: {
                            Label("查看当前引用与关联对话", systemImage: "link")
                        }.disabled(model.needsRecovery).accessibilityIdentifier("knowledge-usage")
                        Button("替换这篇资料的引用", systemImage: "arrow.triangle.2.circlepath") { replacingReferences = true }
                            .disabled(unavailable).accessibilityIdentifier("knowledge-replace-references")
                    } footer: {
                        Text("包括归档和回收站中的已保存选择。此处用于检查当前引用，不追溯历史请求。")
                    }.listRowBackground(HermesTheme.surface)
                    Section("完整正文") {
                        Text(document.body).font(.subheadline).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            .accessibilityIdentifier("knowledge-document-body")
                    }.listRowBackground(HermesTheme.surface)
                    Section {
                        documentActions(document)
                    } footer: {
                        Text("资料保存在本机当前项目中。仅在对话里手动选中后，才会随该对话的请求发送。编辑后，已有引用会使用后续请求时的最新正文。")
                    }.listRowBackground(HermesTheme.surface)
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            } else {
                ContentUnavailableView("资料已改变", systemImage: "doc.badge.ellipsis",
                    description: Text(model.activeProfileID != profileID ? "当前连接已改变，请返回后重新打开。" : "资料或项目可能已删除，请返回资料库。"))
                    .background(HermesTheme.background)
            }
        }
        .navigationTitle("资料详情").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingDocument) { snapshot in
            ProjectDocumentEditorView(projectID: projectID, profileID: profileID, document: snapshot) { editingDocument = nil }
        }
        .sheet(item: $deletionReview) { review in
            ProjectDocumentDeletionReviewView(review: review) { deletionReview = nil }
        }
        .sheet(isPresented: $replacingReferences) {
            ProjectReferenceReplacementView(projectID: projectID, profileID: profileID, sourceID: documentID)
        }
        .toolbar {
            if let document {
                ToolbarItem(placement: .primaryAction) {
                    Menu { documentActions(document) } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("编辑、复制、导出或删除资料")
                }
            }
        }
        .fileExporter(isPresented: $exporting, document: exportedDocument, contentType: ConversationDocument.markdownType,
                      defaultFilename: document.map { ConversationWorkbench.filename($0.title) } ?? "Hermes-资料") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .alert("资料操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }

    @ViewBuilder private func documentActions(_ document: ProjectDocument) -> some View {
        Button("编辑资料", systemImage: "pencil") { editingDocument = document }.disabled(unavailable)
            .accessibilityIdentifier("knowledge-edit")
        Button(copied ? "正文已复制" : "复制完整正文", systemImage: copied ? "checkmark" : "doc.on.doc") {
            UIPasteboard.general.string = document.body
            copied = true
        }.accessibilityIdentifier("knowledge-copy")
        Button("导出这篇资料 Markdown", systemImage: "square.and.arrow.up") {
            exportedDocument = ConversationDocument(text: "# \(document.title)\n\n\(document.body)\n")
            exporting = true
        }.accessibilityIdentifier("knowledge-export")
        Button("检查并删除资料", systemImage: "trash", role: .destructive) {
            do { deletionReview = try model.reviewProjectDocumentDeletion([document], projectID: projectID, profileID: profileID) }
            catch { self.error = error.localizedDescription }
        }.disabled(unavailable)
            .accessibilityIdentifier("knowledge-delete")
    }
}

struct ProjectDocumentCaptureView: View {
    let capture: ProjectDocumentCapture
    var body: some View {
        ProjectDocumentEditorView(projectID: capture.projectID, profileID: capture.profileID,
            importedDocument: capture.document, sourceDescription: capture.sourceDescription, onSaved: {})
    }
}

struct ProjectDocumentEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    var document: ProjectDocument? = nil
    var importedDocument: ProjectDocument? = nil
    var sourceFilename: String? = nil
    var sourceDescription: String? = nil
    let onSaved: () -> Void
    @State private var title = ""
    @State private var text = ""
    @State private var loaded = false
    @State private var error: String?
    @State private var baseDocument: ProjectDocument?
    @State private var confirmingReload = false
    @State private var copiedInput = false

    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var otherCharacterCount: Int { (project?.documents ?? []).filter { $0.id != document?.id }.reduce(0) { $0 + $1.body.count } }
    private var projectedCount: Int { otherCharacterCount + text.count }
    private var originalDocumentMissing: Bool {
        guard let document, let project else { return false }
        return !project.documents.contains { $0.id == document.id }
    }
    private var changedContext: Bool { model.activeProfileID != profileID || project == nil || originalDocumentMissing }
    private var latestDocument: ProjectDocument? { document.flatMap { original in project?.documents.first { $0.id == original.id } } }
    private var externalChange: Bool { loaded && document != nil && latestDocument != nil && latestDocument != baseDocument }
    private var canSave: Bool {
        loaded && !changedContext && !externalChange && !model.isSending && !model.needsRecovery &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && title.count <= ProjectDocument.titleLimit &&
        !title.contains(where: { $0.isNewline }) && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        text.count <= ProjectDocument.bodyLimit && projectedCount <= ProjectDocument.projectCharacterLimit &&
        (document != nil || (project?.documents.count ?? 0) < ProjectDocument.collectionLimit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(project?.name ?? "当前项目", systemImage: "folder").foregroundStyle(HermesTheme.accent)
                    if let sourceDescription {
                        Text(sourceDescription).font(.subheadline)
                        Text("仅预填这条消息的文字与来源说明，不包含图片或收藏备注。检查编辑并保存后才加入项目；不会自动引用或发送。")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                    } else if let sourceFilename {
                        Text("来源：\(sourceFilename)").font(.subheadline)
                        Text("文件内容只预填到此编辑器。检查并点击保存后，才会写入本机资料库。后续修改文件不会自动同步。")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                    } else {
                        Text(document == nil ? "手动输入资料。点击保存后写入当前项目的本机资料库。" : "正在编辑本机已保存的资料。修改在保存后生效。")
                            .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    }
                }.listRowBackground(HermesTheme.surface)
                Section {
                    TextField("资料标题", text: $title).accessibilityIdentifier("knowledge-editor-title")
                    Text("\(title.count) / \(ProjectDocument.titleLimit)").font(.caption)
                        .foregroundStyle(title.count > ProjectDocument.titleLimit ? .orange : HermesTheme.muted)
                } header: { Text("标题") }.listRowBackground(HermesTheme.surface)
                Section {
                    TextEditor(text: $text).frame(minHeight: 260).scrollContentBackground(.hidden)
                        .accessibilityLabel("资料正文").accessibilityIdentifier("knowledge-editor-body")
                    HStack {
                        Text("\(text.count.formatted()) / \(ProjectDocument.bodyLimit.formatted()) 字符")
                        Spacer()
                        if text.count > ProjectDocument.bodyLimit { Text("正文超出上限") }
                    }.font(.caption).foregroundStyle(text.count > ProjectDocument.bodyLimit ? .orange : HermesTheme.muted)
                } header: { Text("完整正文") } footer: {
                    Text("保存不会自动选入对话。已引用这篇资料的对话会在后续请求使用更新后的正文；若引用合计超过 50,000 字符，保存会被拒绝，请缩短内容或先取消部分引用。")
                }.listRowBackground(HermesTheme.surface)
                Section {
                    LabeledContent("保存后资料库正文", value: "\(projectedCount.formatted()) / \(ProjectDocument.projectCharacterLimit.formatted()) 字符")
                        .foregroundStyle(projectedCount > ProjectDocument.projectCharacterLimit ? .orange : HermesTheme.muted)
                    Text("每项目最多 \(ProjectDocument.collectionLimit) 篇资料。超出限制时需要缩短正文或整理已有资料，内容不会自动截断。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }.listRowBackground(HermesTheme.surface)
                if changedContext {
                    Text(originalDocumentMissing ? "原资料已被删除，当前输入仍保留，无法覆盖保存。需要保留时可复制内容后关闭，再新建资料。" : "当前连接或项目已改变，当前输入仍保留。请复制需要保留的内容，再返回资料库。")
                        .foregroundStyle(.orange).listRowBackground(HermesTheme.surface)
                }
                if externalChange {
                    Section {
                        Label("资料已在其他窗口更新", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("当前输入仍留在此编辑器中，尚未覆盖最新资料。先复制输入，或确认载入最新版本后继续编辑。")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                        Button("载入最新资料") { confirmingReload = true }
                    }.listRowBackground(HermesTheme.surface)
                }
                Section {
                    Button(copiedInput ? "当前输入已复制" : "复制当前标题与正文", systemImage: copiedInput ? "checkmark" : "doc.on.doc") {
                        UIPasteboard.general.string = "# \(title)\n\n\(text)"
                        copiedInput = true
                    }.disabled(title.isEmpty && text.isEmpty)
                } footer: { Text("编辑器输入不会自动保存为草稿；关闭前可复制需要保留的内容。") }
                    .listRowBackground(HermesTheme.surface)
            }
            .scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle(document == nil ? "新建参考资料" : "编辑参考资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!canSave).accessibilityIdentifier("knowledge-editor-save")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                title = (document ?? importedDocument)?.title ?? ""
                text = (document ?? importedDocument)?.body ?? ""
                baseDocument = document
            }
            .onChange(of: title) { _, _ in copiedInput = false }
            .onChange(of: text) { _, _ in copiedInput = false }
            .confirmationDialog("载入最新资料并替换当前未保存输入？", isPresented: $confirmingReload, titleVisibility: .visible) {
                Button("替换输入，载入最新资料", role: .destructive) {
                    guard let latest = latestDocument else { return }
                    title = latest.title; text = latest.body; baseDocument = latest; copiedInput = false
                }
                Button("保留当前输入", role: .cancel) {}
            }
            .alert("资料尚未保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("继续编辑", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func save() {
        guard canSave else {
            error = originalDocumentMissing ? "原资料已删除，当前输入尚未保存，请复制需要保留的内容后重新新建资料。" : "当前输入或资料库状态尚不符合保存条件，请检查连接、项目及字符限制。"
            return
        }
        do {
            _ = try model.saveProjectDocument(id: document?.id, projectID: projectID, title: title, body: text,
                profileID: profileID, expectedDocument: baseDocument)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

struct ProjectDocumentSelectionView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let conversationID: UUID
    let profileID: UUID
    @State private var selectedIDs: [UUID] = []
    @State private var originalProjectID: UUID?
    @State private var originalSelection: [UUID] = []
    @State private var loaded = false
    @State private var query = ""
    @State private var error: String?
    @State private var confirmingSelectionReload = false

    private var conversation: Conversation? {
        guard model.activeProfileID == profileID else { return nil }
        return model.conversations.first { $0.id == conversationID } ?? model.trashedConversations.first { $0.id == conversationID }
    }
    private var project: LocalProject? { conversation?.projectID.flatMap { id in model.projects.first { $0.id == id } } }
    private var documents: [ProjectDocument] { project?.documents ?? [] }
    private var visible: [ProjectDocument] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return documents.filter { text.isEmpty || $0.title.localizedStandardContains(text) || $0.body.localizedStandardContains(text) }
    }
    private var selectedCharacterCount: Int { selectedIDs.reduce(0) { count, id in count + (documents.first { $0.id == id }?.body.count ?? 0) } }
    private var missingSelections: Bool { selectedIDs.contains { id in !documents.contains { $0.id == id } } }
    private var changedContext: Bool {
        model.activeProfileID != profileID || conversation == nil ||
        (loaded && originalProjectID != conversation?.projectID)
    }
    private var canChange: Bool { !changedContext && project != nil && conversation?.isTrashed != true && !model.isSending && !model.needsRecovery }
    private var externalSelectionChange: Bool { loaded && originalSelection != (conversation?.referenceDocumentIDs ?? []) }
    private var canSave: Bool {
        loaded && canChange && !externalSelectionChange && !missingSelections && selectedIDs.count <= ProjectDocument.selectionLimit &&
        selectedCharacterCount <= ProjectDocument.selectionCharacterLimit
    }

    var body: some View {
        NavigationStack {
            Group {
                if changedContext {
                    ContentUnavailableView("对话或连接已改变", systemImage: "arrow.triangle.2.circlepath",
                        description: Text("请关闭后从当前对话重新打开参考资料。"))
                } else if conversation?.isTrashed == true {
                    ContentUnavailableView("对话已在回收站", systemImage: "trash",
                        description: Text("恢复对话后可以调整参考资料；现有聊天消息会保留。"))
                } else if let project {
                    selectionList(project)
                } else {
                    ContentUnavailableView("先为对话分配项目", systemImage: "folder.badge.plus",
                        description: Text("参考资料来自所属项目。请返回对话设置，选择项目后再添加资料。"))
                }
            }
            .background(HermesTheme.background)
            .navigationTitle("选择参考资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(!canSave).accessibilityIdentifier("reference-selection-save")
                }
            }
            .onAppear { if !loaded { loadSelection() } }
            .confirmationDialog("载入当前已保存的引用，替换这次未保存的选择？", isPresented: $confirmingSelectionReload, titleVisibility: .visible) {
                Button("载入当前选择") { loadSelection() }
                Button("保留本次选择", role: .cancel) {}
            }
            .alert("无法选择资料", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }

    private func selectionList(_ project: LocalProject) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Label(project.name, systemImage: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(HermesTheme.accent)
                    Text("已选 \(selectedIDs.count) / \(ProjectDocument.selectionLimit) 篇 · \(selectedCharacterCount.formatted()) / \(ProjectDocument.selectionCharacterLimit.formatted()) 字符")
                        .font(.headline).accessibilityIdentifier("reference-selection-count")
                    Text("仅选中的完整正文随这段对话的请求发送，按你选择的先后顺序携带。点击保存才会更改引用，不会自动读取项目内全部资料或联网查找。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                    if conversation?.isArchived == true {
                        Label("对话已归档，可以调整选择；恢复后发送时生效。", systemImage: "archivebox")
                            .font(.caption).foregroundStyle(HermesTheme.accent)
                    }
                    if !selectedIDs.isEmpty {
                        Button("清空选择") { selectedIDs = [] }.font(.caption).disabled(!canChange)
                            .accessibilityIdentifier("reference-selection-clear")
                    }
                }.padding(.vertical, 6)
            }.listRowBackground(Color.clear)
            if externalSelectionChange {
                Section {
                    Label("引用已在其他窗口改变", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("本次整理尚未保存，不会覆盖其他窗口的新选择。请载入当前已保存的引用后重新整理。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                    Button("载入当前选择") { confirmingSelectionReload = true }.disabled(!canChange)
                }.listRowBackground(HermesTheme.surface)
            }
            if !selectedIDs.isEmpty {
                Section {
                    ForEach(Array(selectedIDs.enumerated()), id: \.element) { index, id in
                        HStack(spacing: 8) {
                            Text("\(index + 1)").font(.headline).foregroundStyle(HermesTheme.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(documents.first { $0.id == id }?.title ?? "资料已删除").font(.subheadline.weight(.semibold)).lineLimit(2)
                                Text("\(documents.first { $0.id == id }?.body.count ?? 0) 字符").font(.caption).foregroundStyle(HermesTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Button { move(id, by: -1) } label: { Image(systemName: "arrow.up").frame(width: 36, height: 44) }
                                .disabled(!canChange || index == 0).accessibilityLabel("上移第 \(index + 1) 份资料")
                            Button { move(id, by: 1) } label: { Image(systemName: "arrow.down").frame(width: 36, height: 44) }
                                .disabled(!canChange || index == selectedIDs.count - 1).accessibilityLabel("下移第 \(index + 1) 份资料")
                            Button { selectedIDs.removeAll { $0 == id } } label: { Image(systemName: "xmark.circle").frame(width: 36, height: 44) }
                                .disabled(!canChange).accessibilityLabel("移除第 \(index + 1) 份引用")
                        }.buttonStyle(.borderless).listRowBackground(HermesTheme.surface)
                            .accessibilityIdentifier("reference-order-\(id)")
                    }
                } header: { Text("已选资料 · 请求顺序") } footer: {
                    Text("用上下箭头调整顺序；资料编号随顺序更新。移除仅改变本次选择，点击保存后生效。")
                }
            }
            if missingSelections || selectedCharacterCount > ProjectDocument.selectionCharacterLimit {
                Section {
                    Text("资料库已发生变化，请调整选择或重新载入。超出字符上限时不能保存，正文不会截断。")
                        .font(.caption).foregroundStyle(.orange)
                    Button("重新载入已保存的选择") { confirmingSelectionReload = true }.disabled(!canChange)
                }.listRowBackground(HermesTheme.surface)
            }
            if model.isSending || model.needsRecovery {
                Section {
                    Text(model.needsRecovery ? "本机数据需要恢复，当前不能保存资料选择。" : "回复正在生成，请等待完成或停止后再调整资料选择。")
                        .font(.caption).foregroundStyle(.orange)
                }.listRowBackground(HermesTheme.surface)
            }
            Section("\(visible.count) 篇可选资料") {
                if visible.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "项目资料库还是空的" : "没有匹配的资料", systemImage: "doc.text",
                        description: Text(query.isEmpty ? "前往项目工作区的资料库，新建或导入资料后再选择。" : "试试其他标题或正文关键词。"))
                        .listRowBackground(Color.clear)
                }
                ForEach(visible) { document in
                    Button { toggle(document) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 4) {
                                Image(systemName: selectedIDs.contains(document.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                if let position = selectedIDs.firstIndex(of: document.id) {
                                    Text("\(position + 1)").font(.caption2.weight(.semibold))
                                }
                            }.foregroundStyle(selectedIDs.contains(document.id) ? HermesTheme.accent : HermesTheme.muted).padding(.top, 8)
                            ProjectDocumentRow(document: document)
                        }
                    }.buttonStyle(.plain).disabled(!canChange).listRowBackground(HermesTheme.surface)
                        .accessibilityLabel("\(document.title)，\(document.body.count) 字符，\(selectedIDs.contains(document.id) ? "已选择" : "未选择")")
                        .accessibilityIdentifier("reference-document-\(document.id)")
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "搜索项目资料标题或正文")
    }
    private func loadSelection() {
        selectedIDs = conversation?.referenceDocumentIDs ?? []
        originalSelection = selectedIDs
        originalProjectID = conversation?.projectID
        loaded = true
    }
    private func toggle(_ document: ProjectDocument) {
        guard canChange else { return }
        if selectedIDs.contains(document.id) { selectedIDs.removeAll { $0 == document.id }; return }
        guard selectedIDs.count < ProjectDocument.selectionLimit else {
            error = "最多选择 \(ProjectDocument.selectionLimit) 篇资料，请先取消部分选择。"
            return
        }
        guard selectedCharacterCount + document.body.count <= ProjectDocument.selectionCharacterLimit else {
            error = "选中资料的完整正文合计最多 \(ProjectDocument.selectionCharacterLimit.formatted()) 字符。加入这篇会超出上限，请先取消部分选择；内容不会截断。"
            return
        }
        selectedIDs.append(document.id)
    }
    private func move(_ id: UUID, by offset: Int) {
        guard canChange, let index = selectedIDs.firstIndex(of: id), selectedIDs.indices.contains(index + offset) else { return }
        selectedIDs.swapAt(index, index + offset)
    }
    private func save() {
        guard loaded, canSave, originalProjectID == conversation?.projectID else {
            error = "当前连接、项目或资料选择已改变，请检查后重新保存；尚未更改对话引用。"
            return
        }
        do {
            try model.selectProjectDocuments(selectedIDs, conversationID: conversationID, profileID: profileID,
                expectedSelection: originalSelection, expectedProjectID: originalProjectID)
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
