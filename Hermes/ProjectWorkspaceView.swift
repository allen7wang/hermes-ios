import SwiftUI
import UniformTypeIdentifiers

private struct ProjectRoute: Hashable {
    let projectID: UUID
    let profileID: UUID
}

private struct ProjectEditorTarget: Identifiable {
    let id = UUID()
    let project: LocalProject?
    let profileID: UUID
}

struct ProjectWorkspaceView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var embedded = false
    var onOpen: (() -> Void)? = nil
    @State private var query = ""
    @State private var path: [ProjectRoute] = []
    @State private var editor: ProjectEditorTarget?

    private var visible: [LocalProject] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.projects.filter { text.isEmpty || $0.name.localizedStandardContains(text) || $0.summary.localizedStandardContains(text) }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        Label("HERMES / PROJECTS", systemImage: "square.stack.3d.up")
                            .font(.caption.weight(.semibold)).tracking(2).foregroundStyle(HermesTheme.accent)
                        Text("为长期的事，留一个工作区。")
                            .font(.title2.bold())
                        Text("把相关对话和共同指令放在一起。项目仅保存在本机，属于当前连接。")
                            .font(.subheadline).foregroundStyle(HermesTheme.muted)
                        HStack(spacing: 12) {
                            projectMetric("项目", count: model.projects.count)
                            projectMetric("项目对话", count: model.conversations.filter { $0.projectID != nil }.count)
                            projectMetric("未分配", count: model.conversations.filter { $0.projectID == nil }.count)
                        }
                        Button { editor = ProjectEditorTarget(project: nil, profileID: model.activeProfileID) } label: {
                            HStack { Label("创建项目", systemImage: "folder.badge.plus"); Spacer(); Image(systemName: "arrow.up.right") }
                                .font(.subheadline.weight(.semibold)).padding(14)
                                .foregroundStyle(HermesTheme.background)
                                .background(HermesTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain).disabled(model.needsRecovery || model.isSending || model.projects.count >= 100)
                            .accessibilityIdentifier("projects-create")
                        if model.projects.count >= 100 {
                            Text("当前连接已达到 100 个项目上限。可以编辑或解散已有项目。")
                                .font(.caption).foregroundStyle(HermesTheme.muted)
                        }
                    }.padding(.vertical, 8)
                }.listRowBackground(Color.clear).listRowSeparator(.hidden)

                Section("\(visible.count) 个项目 · \(model.activeProfileName)") {
                    if visible.isEmpty {
                        ContentUnavailableView(query.isEmpty ? "从一个项目开始" : "没有匹配的项目",
                            systemImage: "folder", description: Text(query.isEmpty ? "例如产品发布、学习计划或日常工作。已有对话也可以移动到项目。" : "试试项目名称或简介中的其他关键词。"))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(visible) { project in
                        NavigationLink(value: ProjectRoute(projectID: project.id, profileID: model.activeProfileID)) {
                            ProjectCard(project: project,
                                activeCount: model.conversations.filter { $0.projectID == project.id && !$0.isArchived }.count,
                                archivedCount: model.conversations.filter { $0.projectID == project.id && $0.isArchived }.count)
                        }.listRowBackground(HermesTheme.surface).accessibilityIdentifier("project-row-\(project.id)")
                    }
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("项目工作区").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索项目名称或简介")
            .toolbar {
                if !embedded { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
                ToolbarItem(placement: .primaryAction) {
                    Button { editor = ProjectEditorTarget(project: nil, profileID: model.activeProfileID) } label: { Image(systemName: "plus") }
                        .accessibilityLabel("创建项目").disabled(model.needsRecovery || model.isSending || model.projects.count >= 100)
                }
            }
            .navigationDestination(for: ProjectRoute.self) { route in
                ProjectDetailView(projectID: route.projectID, profileID: route.profileID) { openChat() }
            }
        }
        .sheet(item: $editor) { target in
            ProjectEditorView(project: target.project, profileID: target.profileID) { id in
                editor = nil
                path.append(ProjectRoute(projectID: id, profileID: target.profileID))
            }
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
        .onChange(of: model.activeProfileID) { _, _ in query = ""; path = []; editor = nil }
    }

    private func projectMetric(_ label: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(count)").font(.title2.weight(.semibold))
            Text(label).font(.caption).foregroundStyle(HermesTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(HermesTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
    private func openChat() { if let onOpen { onOpen() } else { dismiss() } }
}

private struct ProjectCard: View {
    let project: LocalProject
    let activeCount: Int
    let archivedCount: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(project.name, systemImage: "folder.fill").font(.headline).foregroundStyle(.white)
            if !project.summary.isEmpty { Text(project.summary).font(.subheadline).foregroundStyle(HermesTheme.muted).lineLimit(2) }
            HStack(spacing: 12) {
                Text("\(activeCount) 段进行中")
                Text("\(archivedCount) 段已归档")
                if !project.instructions.isEmpty { Image(systemName: "text.alignleft").accessibilityLabel("已设置项目指令") }
            }.font(.caption).foregroundStyle(HermesTheme.accent)
        }.padding(.vertical, 8)
    }
}

struct ProjectDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    let onOpen: () -> Void
    @State private var showingEditor = false
    @State private var confirmingDissolution = false
    @State private var trashPreview: Conversation?
    @State private var document: ConversationDocument?
    @State private var exporting = false
    @State private var error: String?

    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var records: [Conversation] { model.conversations.filter { $0.projectID == projectID } }
    private var active: [Conversation] { records.filter { !$0.isArchived } }
    private var archived: [Conversation] { records.filter(\.isArchived) }
    private var trashed: [Conversation] { model.trashedConversations.filter { $0.projectID == projectID } }
    private var unavailable: Bool { model.isSending || model.needsRecovery || model.activeProfileID != profileID }

    var body: some View {
        Group {
            if let project {
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 14) {
                            Label(project.name, systemImage: "folder.fill").font(.title2.bold()).foregroundStyle(HermesTheme.accent)
                            if !project.summary.isEmpty { Text(project.summary).font(.subheadline).textSelection(.enabled) }
                            HStack(spacing: 14) {
                                countLabel("进行中", count: active.count)
                                countLabel("已归档", count: archived.count)
                                countLabel("回收站", count: trashed.count)
                            }
                            Button { startConversation() } label: {
                                HStack { Label("在项目中新建对话", systemImage: "square.and.pencil"); Spacer(); Image(systemName: "arrow.up.right") }
                                    .font(.subheadline.weight(.semibold)).padding(14)
                                    .foregroundStyle(HermesTheme.background)
                                    .background(HermesTheme.accent, in: RoundedRectangle(cornerRadius: 12))
                            }.buttonStyle(.plain).disabled(unavailable).accessibilityIdentifier("project-new-conversation")
                            Text("创建后打开独立草稿，不会自动发送，也不会改动你当前对话的草稿。")
                                .font(.caption).foregroundStyle(HermesTheme.muted)
                        }.padding(.vertical, 8)
                    }.listRowBackground(Color.clear)
                    Section {
                        if project.instructions.isEmpty {
                            Label("尚未设置项目指令", systemImage: "text.alignleft").foregroundStyle(HermesTheme.muted)
                            Button("添加项目指令") { showingEditor = true }.disabled(unavailable)
                        } else {
                            DisclosureGroup("查看项目指令 · \(project.instructions.count) 字符") {
                                Text(project.instructions).font(.subheadline).textSelection(.enabled)
                            }
                        }
                        Text("项目指令会随本项目的每次本机对话请求发送。简介用于整理，不会自动发送。项目不会自动读取其他对话的消息。")
                            .font(.caption).foregroundStyle(HermesTheme.muted)
                    } header: { Text("共同指令") }.listRowBackground(HermesTheme.surface)
                    conversationSection("进行中 · \(active.count)", records: active)
                    conversationSection("已归档 · \(archived.count)", records: archived)
                    if !trashed.isEmpty {
                        Section {
                            DisclosureGroup("回收站中的 \(trashed.count) 段对话") {
                                ForEach(trashed) { conversation in
                                    Button { trashPreview = conversation } label: {
                                        Label(conversation.title, systemImage: "trash").foregroundStyle(HermesTheme.muted)
                                    }.accessibilityIdentifier("project-trash-row-\(conversation.id)")
                                }
                            }
                            Text("查看与恢复请使用对话回收站。回收站消息不会包含在项目 Markdown 导出中。")
                                .font(.caption).foregroundStyle(HermesTheme.muted)
                        }.listRowBackground(HermesTheme.surface)
                    }
                    Section {
                        Button("编辑项目", systemImage: "pencil") { showingEditor = true }.disabled(unavailable)
                            .accessibilityIdentifier("project-edit")
                        Button("导出项目对话 Markdown", systemImage: "square.and.arrow.up") { export(project) }.disabled(records.isEmpty)
                            .accessibilityIdentifier("project-export")
                        Button("解散项目", systemImage: "folder.badge.minus", role: .destructive) { confirmingDissolution = true }
                            .disabled(unavailable).accessibilityIdentifier("project-dissolve")
                    } footer: {
                        Text("Markdown 仅包含进行中和已归档的对话、标签及图片占位提示，不包含项目简介、项目指令或回收站。迁移附件请使用 JSON 备份。")
                    }.listRowBackground(HermesTheme.surface)
                }
                .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
                .navigationTitle(project.name).navigationBarTitleDisplayMode(.inline)
                .sheet(isPresented: $showingEditor) {
                    ProjectEditorView(project: project, profileID: profileID) { _ in showingEditor = false }
                }
                .confirmationDialog("解散「\(project.name)」？", isPresented: $confirmingDissolution, titleVisibility: .visible) {
                    Button("解散项目，保留所有对话", role: .destructive) {
                        perform { try model.deleteProject(projectID, profileID: profileID); dismiss() }
                    }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text("进行中、已归档和回收站中的对话都会改为未分配；消息、收藏、图片及每段对话的草稿会保留。项目简介与共同指令将删除。")
                }
            } else {
                ContentUnavailableView("项目已改变", systemImage: "folder.badge.questionmark", description: Text("项目可能已解散，或当前连接已切换。请返回项目列表。"))
                    .background(HermesTheme.background)
            }
        }
        .sheet(item: $trashPreview) { conversation in TrashConversationView(conversationID: conversation.id) }
        .fileExporter(isPresented: $exporting, document: document, contentType: ConversationDocument.markdownType,
                      defaultFilename: project.map { ConversationWorkbench.filename($0.name) + "-项目对话" } ?? "Hermes-项目对话") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        .alert("项目操作失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("知道了", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func countLabel(_ title: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(count)").font(.title3.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(HermesTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func conversationSection(_ title: String, records: [Conversation]) -> some View {
        Section(title) {
            if records.isEmpty { Text("这里还没有对话").font(.subheadline).foregroundStyle(HermesTheme.muted) }
            ForEach(records) { conversation in
                Button {
                    model.select(conversation.id)
                    onOpen()
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(conversation.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(HermesTheme.muted)
                        }
                        Text(conversation.messages.last.map { $0.content.isEmpty ? "[图片]" : $0.content } ?? "独立草稿 · 尚未发送消息")
                            .font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(2)
                        Text("\(conversation.messages.count) 条消息").font(.caption2).foregroundStyle(HermesTheme.muted)
                    }.foregroundStyle(.white).padding(.vertical, 5)
                }.disabled(model.isSending).accessibilityIdentifier("project-conversation-row-\(conversation.id)")
            }
        }.listRowBackground(HermesTheme.surface)
    }
    private func startConversation() {
        perform { _ = try model.startProjectConversation(projectID, profileID: profileID); onOpen() }
    }
    private func export(_ project: LocalProject) {
        document = ConversationDocument(text: ConversationWorkbench.markdown(records))
        exporting = true
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
}

private struct ProjectEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let project: LocalProject?
    let profileID: UUID
    let onSaved: (UUID) -> Void
    @State private var name = ""
    @State private var summary = ""
    @State private var instructions = ""
    @State private var loaded = false
    @State private var error: String?

    private var changedConnection: Bool { model.activeProfileID != profileID }
    private var canSave: Bool {
        !changedConnection && !model.needsRecovery && !model.isSending &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 60 &&
        !name.contains(where: { $0.isNewline }) && summary.count <= 2_000 && instructions.count <= 8_000
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("项目名称", text: $name).accessibilityIdentifier("project-name")
                    Text("\(name.count) / 60").font(.caption).foregroundStyle(name.count > 60 ? .orange : HermesTheme.muted)
                } header: { Text("名称") }.listRowBackground(HermesTheme.surface)
                Section {
                    TextEditor(text: $summary).frame(minHeight: 100).scrollContentBackground(.hidden)
                        .accessibilityLabel("项目简介").accessibilityIdentifier("project-summary")
                    Text("\(summary.count) / 2,000").font(.caption).foregroundStyle(summary.count > 2_000 ? .orange : HermesTheme.muted)
                } header: { Text("项目简介") } footer: {
                    Text("用于说明项目目标和背景，不会自动随消息发送。")
                }.listRowBackground(HermesTheme.surface)
                Section {
                    TextEditor(text: $instructions).frame(minHeight: 180).scrollContentBackground(.hidden)
                        .accessibilityLabel("项目共同指令").accessibilityIdentifier("project-instructions")
                    Text("\(instructions.count) / 8,000").font(.caption).foregroundStyle(instructions.count > 8_000 ? .orange : HermesTheme.muted)
                } header: { Text("项目共同指令") } footer: {
                    Text("每次本机项目对话请求都会带入这些指令，再带入该对话自己的额外指令。修改后仅影响后续请求。项目不会自动共享各段对话的历史。")
                }.listRowBackground(HermesTheme.surface)
                if changedConnection {
                    Text("当前连接已改变，请关闭后重新打开项目。")
                        .foregroundStyle(.orange).listRowBackground(HermesTheme.surface)
                }
            }
            .scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle(project == nil ? "创建项目" : "编辑项目").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            let id = try model.saveProject(id: project?.id, name: name, summary: summary, instructions: instructions, profileID: profileID)
                            onSaved(id)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!canSave).accessibilityIdentifier("project-save")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                name = project?.name ?? ""
                summary = project?.summary ?? ""
                instructions = project?.instructions ?? ""
            }
            .alert("项目保存失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

struct ProjectMoveTarget: Identifiable {
    let id = UUID()
    let conversationIDs: Set<UUID>
    let profileID: UUID
}

struct ProjectAssignmentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let target: ProjectMoveTarget
    var onSaved: (() -> Void)? = nil
    @State private var choice: ProjectFilter = .all
    @State private var loaded = false
    @State private var error: String?

    private var changedConnection: Bool { model.activeProfileID != target.profileID }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("选择 \(target.conversationIDs.count) 段对话的项目归属。消息、草稿、标签和归档状态都会保留。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                }.listRowBackground(Color.clear)
                Section {
                    option("未分配到项目", icon: "tray", value: .unassigned)
                    ForEach(model.projects) { project in option(project.name, icon: "folder", value: .project(project.id)) }
                }.listRowBackground(HermesTheme.surface)
                if model.projects.isEmpty {
                    Text("当前连接还没有项目。可以在项目工作区创建，再移动对话。")
                        .font(.caption).foregroundStyle(HermesTheme.muted).listRowBackground(Color.clear)
                }
                if changedConnection {
                    Text("当前连接已改变，请关闭后重新选择对话。")
                        .foregroundStyle(.orange).listRowBackground(HermesTheme.surface)
                }
            }
            .scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("移动到项目").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.disabled(choice == .all || changedConnection || model.isSending || model.needsRecovery)
                        .accessibilityIdentifier("project-assignment-save")
                }
            }
            .onAppear {
                guard !loaded else { return }
                loaded = true
                let records = model.conversations.filter { target.conversationIDs.contains($0.id) }
                if let first = records.first, records.allSatisfy({ $0.projectID == first.projectID }) {
                    choice = first.projectID.map(ProjectFilter.project) ?? .unassigned
                }
            }
            .alert("移动失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func option(_ title: String, icon: String, value: ProjectFilter) -> some View {
        Button { choice = value } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if choice == value { Image(systemName: "checkmark").foregroundStyle(HermesTheme.accent) }
            }.foregroundStyle(.white)
        }.accessibilityIdentifier(identifier(value))
    }
    private func identifier(_ value: ProjectFilter) -> String {
        switch value {
        case .all: "project-assign-all"
        case .unassigned: "project-assign-unassigned"
        case .project(let id): "project-assign-\(id)"
        }
    }
    private func save() {
        let projectID: UUID?
        switch choice { case .all: return; case .unassigned: projectID = nil; case .project(let id): projectID = id }
        do {
            try model.assignConversations(target.conversationIDs, toProject: projectID, profileID: target.profileID)
            onSaved?()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
