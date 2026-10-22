import SwiftUI

struct ProjectReferenceReplacementView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    let profileID: UUID
    let sourceID: UUID
    @State private var targetID: UUID?
    @State private var selection: Set<UUID> = []
    @State private var query = ""
    @State private var review: ProjectReferenceReplacementReview?
    @State private var error: String?
    @State private var message: String?

    private var project: LocalProject? { model.activeProfileID == profileID ? model.projects.first { $0.id == projectID } : nil }
    private var source: ProjectDocument? { project?.documents.first { $0.id == sourceID } }
    private var targets: [ProjectDocument] { ProjectDocumentBatch.ordered((project?.documents ?? []).filter { $0.id != sourceID }) }
    private var target: ProjectDocument? { targets.first { $0.id == targetID } }
    private var records: [Conversation] {
        model.projectDocumentConversations(projectID: projectID, profileID: profileID)
            .filter { ($0.referenceDocumentIDs ?? []).contains(sourceID) }
            .sorted {
                let first = status($0).order, second = status($1).order
                return first == second ? $0.id.uuidString < $1.id.uuidString : first < second
            }
    }
    private var visible: [Conversation] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { text.isEmpty || $0.title.localizedStandardContains(text) }
    }
    private var unavailable: Bool { project == nil || source == nil || model.needsRecovery || model.isSending }
    private var allVisibleSelected: Bool { !visible.isEmpty && visible.allSatisfy { selection.contains($0.id) } }
    private var selectionIssue: String? {
        guard let target, let project else { return nil }
        for conversation in records where selection.contains(conversation.id) {
            do { _ = try ProjectReferenceReplacement.makeRow(conversation, sourceID: sourceID, targetID: target.id, project: project, profileID: profileID) }
            catch { return "「\(conversation.title)」：\(error.localizedDescription)" }
        }
        return nil
    }
    private var canReview: Bool { !unavailable && target != nil && !selection.isEmpty && selectionIssue == nil }

    var body: some View {
        NavigationStack {
            Group {
                if let source, let project, !model.needsRecovery {
                    List {
                        Section {
                            Label(project.name, systemImage: "folder").foregroundStyle(HermesTheme.accent)
                            Text("让新的资料，接上后续讨论。 ").font(.title2.bold())
                            Text("将所选对话当前保存的旧资料引用换为同项目中的另一篇资料。原资料、聊天消息和草稿保留，后续发送会使用更新后的选择。")
                                .font(.subheadline).foregroundStyle(HermesTheme.muted)
                            DisclosureGroup("旧资料：\(source.title)") {
                                Text(source.body).font(.subheadline).textSelection(.enabled)
                            }
                            if unavailable { Text("回复进行中或本机状态暂不可用，请返回检查后重试。").font(.caption).foregroundStyle(.orange) }
                            if let message { Label(message, systemImage: "checkmark.circle").font(.subheadline).foregroundStyle(.green) }
                        }.listRowBackground(HermesTheme.surface)
                        Section {
                            Picker("替换为", selection: $targetID) {
                                Text("请选择目标资料").tag(nil as UUID?)
                                ForEach(targets) { Text($0.title).tag(Optional($0.id)) }
                            }.disabled(unavailable || targets.isEmpty).accessibilityIdentifier("knowledge-replacement-target")
                            if let target {
                                DisclosureGroup("检查目标全文 · \(target.body.count.formatted()) 字符") {
                                    Text(target.body).font(.subheadline).textSelection(.enabled)
                                }
                            }
                            if targets.isEmpty { Text("请先在本项目保存另一篇资料。").font(.subheadline).foregroundStyle(HermesTheme.muted) }
                        } header: { Text("1 · 选择目标资料") } footer: {
                            Text("若目标已被某段对话选中，按替换结果中首次出现的位置保留一次；检查页会展示最终顺序。")
                        }.listRowBackground(HermesTheme.surface)
                        Section {
                            Text("已选 \(selection.count) / \(records.count) 段对话").font(.headline)
                                .accessibilityIdentifier("knowledge-replacement-count")
                            let hidden = selection.subtracting(visible.map(\.id)).count
                            if hidden > 0 { Text("另有 \(hidden) 段已选对话被搜索隐藏，仍会纳入检查。").font(.caption).foregroundStyle(.orange) }
                            HStack {
                                Button(allVisibleSelected ? "取消选择当前结果" : "选择当前结果") {
                                    let ids = Set(visible.map(\.id))
                                    if allVisibleSelected { selection.subtract(ids) } else { selection.formUnion(ids) }
                                    message = nil
                                }.disabled(unavailable || visible.isEmpty).accessibilityIdentifier("knowledge-replacement-select-visible")
                                Spacer()
                                Button("清空选择") { selection = []; message = nil }.disabled(selection.isEmpty)
                            }.font(.subheadline)
                            if records.isEmpty { Text("当前没有对话保存了这篇资料的引用。").font(.subheadline).foregroundStyle(HermesTheme.muted) }
                            if let selectionIssue { Text(selectionIssue).font(.subheadline).foregroundStyle(.orange) }
                        } header: { Text("2 · 明确选择对话") } footer: {
                            Text("列表包含进行中、归档和回收站，初始均未选择。只有明确选中的对话会更新；可取消超限项后继续。")
                        }.listRowBackground(HermesTheme.surface)
                        ForEach(ProjectDocumentUsage.Status.allCases, id: \.self) { state in
                            let rows = visible.filter { status($0) == state }
                            if !rows.isEmpty {
                                Section("\(state.title) · \(rows.count) 段") {
                                    ForEach(rows) { conversation in
                                        Button {
                                            if selection.contains(conversation.id) { selection.remove(conversation.id) }
                                            else { selection.insert(conversation.id) }
                                            message = nil
                                        } label: {
                                            HStack(alignment: .top, spacing: 12) {
                                                Image(systemName: selection.contains(conversation.id) ? "checkmark.circle.fill" : "circle")
                                                    .foregroundStyle(HermesTheme.accent)
                                                VStack(alignment: .leading, spacing: 7) {
                                                    Text(conversation.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                                    Text("当前选择 \((conversation.referenceDocumentIDs ?? []).count) 篇资料")
                                                        .font(.caption).foregroundStyle(HermesTheme.muted)
                                                }
                                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                        }.buttonStyle(.plain).disabled(unavailable)
                                            .accessibilityLabel("\(conversation.title)，\(selection.contains(conversation.id) ? "已选择" : "未选择")")
                                            .accessibilityIdentifier("knowledge-replacement-row-\(conversation.id)")
                                    }
                                }.listRowBackground(HermesTheme.surface)
                            }
                        }
                        Section {
                            Button("检查替换前后方案", systemImage: "list.bullet.rectangle") { prepare() }
                                .disabled(!canReview).accessibilityIdentifier("knowledge-replacement-preview")
                        } footer: {
                            Text("先检查完整顺序和字符量，再确认保存。此操作更新后续请求的引用；历史回复的文字及编号保持原样。")
                        }.listRowBackground(HermesTheme.surface)
                    }.listStyle(.insetGrouped).scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView("资料已改变", systemImage: "doc.badge.ellipsis",
                        description: Text("项目、资料、连接或本机存储状态已改变，请返回资料库检查。"))
                }
            }
            .background(HermesTheme.background).navigationTitle("替换资料引用").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索引用旧资料的对话标题")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
            .sheet(item: $review) { snapshot in
                ProjectReferenceReplacementReviewView(review: snapshot) {
                    review = nil; selection = []; message = "已替换 \(snapshot.rows.count) 段对话的资料引用"
                }
            }
            .alert("替换方案暂不可用", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .onChange(of: records.map(\.id)) { _, ids in selection.formIntersection(ids) }
            .onChange(of: model.activeProfileID) { _, _ in selection = []; targetID = nil; message = nil }
            .onChange(of: targetID) { _, _ in message = nil }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func status(_ conversation: Conversation) -> ProjectDocumentUsage.Status {
        conversation.isTrashed ? .trash : conversation.isArchived ? .archived : .active
    }
    private func prepare() {
        guard let targetID else { return }
        do { review = try model.previewProjectReferenceReplacement(sourceID: sourceID, targetID: targetID,
            conversationIDs: selection, projectID: projectID, profileID: profileID) }
        catch { self.error = error.localizedDescription }
    }
}

struct ProjectReferenceReplacementReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let review: ProjectReferenceReplacementReview
    let onApplied: () -> Void
    @State private var error: String?
    private var changeMessage: String? {
        do {
            let current = try model.previewProjectReferenceReplacement(sourceID: review.source.id, targetID: review.target.id,
                conversationIDs: Set(review.rows.map(\.conversationID)), projectID: review.projectID, profileID: review.profileID)
            guard current.projectName == review.projectName, current.documents == review.documents,
                  current.source == review.source, current.target == review.target, current.rows == review.rows else {
                return ProjectReferenceReplacementError.changed.localizedDescription
            }
            return nil
        } catch { return error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(review.projectName, systemImage: "folder").foregroundStyle(HermesTheme.accent)
                    Text("检查 \(review.rows.count) 段对话的引用更新").font(.title2.bold())
                    HStack(spacing: 12) {
                        ForEach(ProjectDocumentUsage.Status.allCases, id: \.self) { status in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(review.rows.filter { $0.status == status }.count)").font(.title3.weight(.semibold))
                                Text(status.title).font(.caption).foregroundStyle(HermesTheme.muted)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("只更新下列对话当前保存的资料选择。原资料、历史消息、收藏、草稿和日期保留；后续发送使用新选择，历史回复编号不会重写。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    if let changeMessage {
                        Label(changeMessage, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("knowledge-replacement-changed")
                    }
                }.listRowBackground(HermesTheme.surface)
                Section("资料快照") {
                    DisclosureGroup("旧资料 · \(review.source.title)") { Text(review.source.body).font(.subheadline).textSelection(.enabled) }
                    DisclosureGroup("新资料 · \(review.target.title)") { Text(review.target.body).font(.subheadline).textSelection(.enabled) }
                }.listRowBackground(HermesTheme.surface)
                ForEach(ProjectDocumentUsage.Status.allCases, id: \.self) { status in
                    let rows = review.rows.filter { $0.status == status }
                    if !rows.isEmpty {
                        Section(status.title) {
                            ForEach(rows) { row in
                                VStack(alignment: .leading, spacing: 14) {
                                    Text(row.title).font(.headline).textSelection(.enabled)
                                    ViewThatFits(in: .horizontal) {
                                        HStack(alignment: .top, spacing: 24) {
                                            selectionList(row.beforeIDs, title: "替换前").frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                                            selectionList(row.afterIDs, title: "替换后").frame(minWidth: 280, maxWidth: .infinity, alignment: .leading)
                                        }
                                        VStack(alignment: .leading, spacing: 16) {
                                            selectionList(row.beforeIDs, title: "替换前")
                                            selectionList(row.afterIDs, title: "替换后")
                                        }
                                    }
                                }.padding(.vertical, 8).accessibilityIdentifier("knowledge-replacement-plan-\(row.id)")
                            }
                        }.listRowBackground(HermesTheme.surface)
                    }
                }
                Section {
                    Button("确认替换 \(review.rows.count) 段对话的引用", systemImage: "arrow.triangle.2.circlepath") { apply() }
                        .disabled(changeMessage != nil).accessibilityIdentifier("knowledge-replacement-apply")
                } footer: {
                    Text("目标已在选择中时仅保留首次出现位置。每段对话最多 5 篇、50,000 正文字符；提交前重新检查，任一项不符则整批拒绝。可重新选择资料恢复引用，历史文字不会随之改变。")
                }.listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("引用替换检查").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回选择") { dismiss() } } }
            .alert("引用替换失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func selectionList(_ ids: [UUID], title: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(HermesTheme.accent)
            Text("\(ids.count) 篇 · \(ids.reduce(0) { sum, id in sum + (review.documents.first { $0.id == id }?.body.count ?? 0) }.formatted()) 正文字符")
                .font(.caption).foregroundStyle(HermesTheme.muted)
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                Text("[资料\(index + 1)] " + (review.documents.first { $0.id == id }?.title ?? "资料已改变"))
                    .font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func apply() {
        do { try model.applyProjectReferenceReplacement(review); onApplied(); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}
