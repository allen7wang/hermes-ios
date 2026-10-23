import SwiftUI
import UIKit

struct MessageProjectCapturePickerView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let source: MessageLibraryBatchSnapshot
    let onSaved: (UUID) -> Void
    @State private var capture: MessageProjectCapture?
    @State private var failure: String?
    private var available: Bool { model.activeProfileID == source.profileID && !model.needsRecovery && !model.isSending }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(source.profileName, systemImage: "externaldrive").foregroundStyle(HermesTheme.accent)
                    Text("将 \(source.items.count) 条消息汇编成一篇资料").font(.title3.bold())
                    Text("先明确选择目标项目，再检查并编辑完整文字。来源可跨项目；收藏备注不加入，图片只保留占位。不会自动引用资料或发送请求。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    if !available {
                        Text(model.isSending ? "请等待当前回复结束后再选择项目。" : "当前连接或存储状态已变化，请返回重新选择。")
                            .font(.subheadline).foregroundStyle(.orange)
                    }
                }.listRowBackground(HermesTheme.surface)
                Section("选择目标项目 · 初始不选中任何项目") {
                    if model.activeProfileID == source.profileID && model.projects.isEmpty {
                        Text("当前连接还没有项目，请先到“项目”页创建项目，再回来采集。")
                            .foregroundStyle(HermesTheme.muted)
                    }
                    if model.activeProfileID == source.profileID {
                        ForEach(model.projects) { project in
                            let count = project.documents.count
                            let characters = project.documents.reduce(0) { $0 + $1.body.count }
                            Button {
                                do { capture = try model.prepareMessageProjectCapture(source: source, projectID: project.id) }
                                catch { failure = error.localizedDescription }
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(project.name, systemImage: "folder").font(.headline)
                                    Text("\(count) / 20 篇 · \(characters.formatted()) / 200,000 正文字符")
                                        .font(.caption).foregroundStyle(HermesTheme.muted)
                                    if count >= ProjectDocument.collectionLimit || characters >= ProjectDocument.projectCharacterLimit {
                                        Text("资料库已满，请先整理空间。").font(.caption).foregroundStyle(.orange)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                            }.disabled(!available || count >= ProjectDocument.collectionLimit || characters >= ProjectDocument.projectCharacterLimit)
                                .accessibilityIdentifier("message-capture-project-\(project.id.uuidString)")
                        }
                    }
                }.listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("存为项目资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if capture == nil { ToolbarItem(placement: .cancellationAction) { Button("返回选择") { dismiss() } } }
            }
            .navigationDestination(isPresented: Binding(get: { capture != nil }, set: { if !$0 { capture = nil } })) {
                if let capture {
                    MessageProjectCaptureEditorView(capture: capture, onSaved: onSaved, onFinished: { dismiss() })
                }
            }
            .alert("暂时无法采集", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("知道了", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

struct MessageProjectCaptureEditorView: View {
    private enum Field: Hashable { case title, body }
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onSaved: (UUID) -> Void
    let onFinished: () -> Void
    @State private var capture: MessageProjectCapture
    @State private var title = ""
    @State private var bodyText = ""
    @State private var loaded = false
    @State private var buildError: String?
    @State private var failure: String?
    @State private var savedID: UUID?
    @State private var copied = false
    @State private var initialBody = ""
    @State private var initialTitle = ""
    @State private var confirmingDiscard = false
    @FocusState private var focusedField: Field?

    init(capture: MessageProjectCapture, onSaved: @escaping (UUID) -> Void, onFinished: @escaping () -> Void) {
        _capture = State(initialValue: capture)
        self.onSaved = onSaved
        self.onFinished = onFinished
    }

    private var dirty: Bool { loaded && (title != initialTitle || bodyText != initialBody) && savedID == nil }
    private var proposed: Result<ProjectDocument, Error> {
        Result {
            let document = try MessageProjectCaptureText.document(title: title, body: bodyText)
            try MessageProjectCaptureText.validateCapacity(document, in: capture.project)
            return document
        }
    }
    private var changeMessage: String? {
        do { try model.validateMessageProjectCapture(capture); return nil }
        catch { return error.localizedDescription }
    }
    private var canView: Bool {
        guard let savedID else { return false }
        return model.activeProfileID == capture.source.profileID && model.projects.contains { project in
            project.id == capture.project.id && project.documents.contains { $0.id == savedID }
        }
    }

    var body: some View {
        List {
            targetSection
            if let savedID {
                Section {
                    Label("已新增一篇独立资料", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("原消息、草稿与已有资料引用保留。新资料尚未用于聊天，请按需在对话中明确选择参考资料。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    NavigationLink("查看新资料") {
                        ProjectDocumentDetailView(projectID: capture.project.id, profileID: capture.source.profileID, documentID: savedID)
                    }.disabled(!canView).accessibilityIdentifier("message-capture-view-saved")
                    Button("完成", action: onFinished)
                }.listRowBackground(HermesTheme.surface)
            } else {
                inputSection
                actionSection
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("编辑采集资料").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(savedID == nil ? "返回项目" : "关闭") {
                    if dirty { confirmingDiscard = true }
                    else if savedID != nil { onFinished() }
                    else { dismiss() }
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedField = nil }.accessibilityLabel("收起键盘")
            }
        }
        .interactiveDismissDisabled(dirty)
        .task {
            guard !loaded, buildError == nil else { return }
            let source = capture.source
            let worker = Task.detached(priority: .userInitiated) { try MessageProjectCaptureText.initialBody(source) }
            do {
                let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, !loaded else { return }
                let name = MessageProjectCaptureText.initialTitle(source)
                initialTitle = name; initialBody = text; title = name; bodyText = text; loaded = true
            } catch {
                guard !Task.isCancelled else { return }
                buildError = error.localizedDescription
            }
        }
        .onChange(of: title) { _, _ in copied = false }
        .onChange(of: bodyText) { _, _ in copied = false }
        .confirmationDialog("放弃未保存的编辑？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("放弃编辑并返回", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        } message: { Text("可以先复制标题与正文。未保存输入不会自动成为聊天草稿。") }
        .alert("资料未保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("知道了", role: .cancel) { failure = nil }
        } message: { Text(failure ?? "") }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }

    private var targetSection: some View {
        Section("目标与来源") {
            Label(capture.source.profileName, systemImage: "externaldrive").foregroundStyle(HermesTheme.accent)
            Label(capture.project.name, systemImage: "folder").font(.title3.bold())
            Text("\(capture.source.items.count) 条来源消息 · 新增一篇资料")
                .font(.subheadline).foregroundStyle(HermesTheme.muted)
            let characters = capture.project.documents.reduce(0) { $0 + $1.body.count }
            Text("检查时已有 \(capture.project.documents.count) / 20 篇、\(characters.formatted()) / 200,000 正文字符")
                .font(.caption).foregroundStyle(HermesTheme.muted)
            if savedID == nil, let changeMessage {
                Label(changeMessage, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    .accessibilityIdentifier("message-capture-changed")
                Button("重新检查目标项目，保留编辑输入") {
                    do { capture = try model.prepareMessageProjectCapture(source: capture.source, projectID: capture.project.id) }
                    catch { failure = error.localizedDescription }
                }.disabled(model.isSending || model.needsRecovery).font(.subheadline)
                Text("若来源消息也已改变，需返回消息库重新选择；当前输入保留，可先复制。")
                    .font(.caption).foregroundStyle(HermesTheme.muted)
            }
        }.listRowBackground(HermesTheme.surface)
    }

    private var inputSection: some View {
        Section {
            if !loaded && buildError == nil { HStack { ProgressView(); Text("正在准备完整汇编…") } }
            if let buildError { Text(buildError).foregroundStyle(.orange).font(.subheadline) }
            TextField("资料标题", text: $title, axis: .vertical).lineLimit(1...3)
                .focused($focusedField, equals: .title)
                .accessibilityIdentifier("message-capture-title").disabled(!loaded)
            TextEditor(text: $bodyText).frame(height: 320).scrollContentBackground(.hidden)
                .focused($focusedField, equals: .body)
                .accessibilityLabel("资料完整正文").accessibilityIdentifier("message-capture-body").disabled(!loaded)
            Text("标题 \(title.trimmingCharacters(in: .whitespacesAndNewlines).count) / 80 · 正文 \(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).count.formatted()) / 20,000 字符")
                .font(.caption).foregroundStyle(HermesTheme.muted)
            if loaded {
                switch proposed {
                case .success(let document):
                    let total = capture.project.documents.reduce(0) { $0 + $1.body.count } + document.body.count
                    Text("保存后 \(capture.project.documents.count + 1) / 20 篇 · \(total.formatted()) / 200,000 正文字符")
                        .font(.caption).foregroundStyle(HermesTheme.accent)
                case .failure(let error):
                    Text(error.localizedDescription + " 完整预填仍保留，请手动精简；不会自动截断或拆分。")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("编辑完整文字")
        } footer: {
            Text("预填最多 100,000 字符，最终资料最多 20,000 字符。来源备注始终不加入；图片只有占位说明。保存沿用资料格式，会修剪标题正文首尾空白，内部正文保持原样。")
        }.listRowBackground(HermesTheme.surface)
    }

    private var actionSection: some View {
        Section {
            Button("保存为项目资料", systemImage: "text.badge.plus") {
                do {
                    let id = try model.saveMessageProjectCapture(capture, title: title, body: bodyText)
                    savedID = id; onSaved(id)
                } catch { failure = error.localizedDescription }
            }.disabled(!loaded || (try? proposed.get()) == nil || changeMessage != nil)
                .accessibilityIdentifier("message-capture-save")
            Button(copied ? "标题与正文已复制" : "复制标题与正文", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = title + "\n\n" + bodyText; copied = true
            }.disabled(!loaded).accessibilityIdentifier("message-capture-copy")
        } footer: {
            Text("保存前重新核对完整来源与目标项目；过期或写入失败不新增资料。输入只在当前页内保留，关闭页面或切换连接后不自动恢复，可先复制。来源消息、收藏、图片、对话草稿与引用保持原状，不自动引用或发送；生成回复期间暂停项目保存。")
        }.listRowBackground(HermesTheme.surface)
    }
}
