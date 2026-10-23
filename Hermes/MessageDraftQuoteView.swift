import SwiftUI
import UIKit

struct MessageDraftQuoteReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let snapshot: MessageDraftQuoteSnapshot
    let onApplied: () -> Void
    let onShowDraft: () -> Void
    @State private var mode: PromptDraftMode
    @State private var reference: String?
    @State private var preparing = true
    @State private var buildError: String?
    @State private var failure: String?
    @State private var confirmingReplace = false
    @State private var applied = false
    @State private var copied = false

    init(snapshot: MessageDraftQuoteSnapshot, initialMode: PromptDraftMode = .append,
         onApplied: @escaping () -> Void, onShowDraft: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onApplied = onApplied
        self.onShowDraft = onShowDraft
        _mode = State(initialValue: initialMode)
    }

    private var result: Result<String, Error>? {
        reference.map { value in Result { try MessageDraftQuote.draft(current: snapshot.draftText, reference: value, mode: mode) } }
    }
    private var finalText: String? { try? result?.get() }
    private var changeMessage: String? {
        do { try model.validateMessageDraftQuote(snapshot); return nil }
        catch { return error.localizedDescription }
    }
    private var canShowDraft: Bool {
        model.activeProfileID == snapshot.source.profileID && model.draftKey == snapshot.draftKey
            && model.selectedID == snapshot.destination.conversationID && model.selectedConversation?.isArchived != true
    }

    var body: some View {
        NavigationStack {
            List {
                destinationSection
                if applied {
                    Section {
                        Label("引用已保存到目标草稿", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Text("尚未发送。返回目标对话，继续编辑并检查发送上下文。来源消息与收藏保持原状。")
                            .font(.subheadline).foregroundStyle(HermesTheme.muted)
                        Button("查看目标草稿", systemImage: "square.and.pencil") {
                            guard canShowDraft else { return }
                            onShowDraft(); dismiss()
                        }.disabled(!canShowDraft).accessibilityIdentifier("draft-quote-show-draft")
                        if !canShowDraft {
                            Text("当前对话已切换或归档，请从对话记录打开目标草稿。")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }.listRowBackground(HermesTheme.surface)
                } else {
                    modeSection
                    previewSection
                    actionSection
                }
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("消息引用检查").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(applied ? "完成" : "返回选择") { dismiss() } } }
            .task {
                let source = snapshot.source
                let worker = Task.detached(priority: .userInitiated) { try MessageDraftQuote.referenceText(source) }
                do {
                    let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }
                    reference = text; preparing = false
                } catch {
                    guard !Task.isCancelled else { return }
                    buildError = error.localizedDescription; preparing = false
                }
            }
            .onChange(of: mode) { _, _ in confirmingReplace = false; copied = false }
            .confirmationDialog("替换「\(snapshot.destination.title)」的草稿？", isPresented: $confirmingReplace, titleVisibility: .visible) {
                Button("确认替换草稿", role: .destructive) { apply(.replace) }
                Button("保留原草稿", role: .cancel) {}
            } message: {
                Text("将用已预览的引用替换 \(snapshot.draftText.count.formatted()) 字符原草稿，没有一键撤销。确认时会再次检查草稿和来源。")
            }
            .alert("引用未保存", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("知道了", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }

    private var destinationSection: some View {
        Section("目标本机草稿") {
            Label(snapshot.source.profileName, systemImage: "externaldrive").foregroundStyle(HermesTheme.accent)
            Text(snapshot.destination.title).font(.title3.bold())
            if let project = snapshot.destination.projectName {
                Label(project, systemImage: "folder").font(.caption).foregroundStyle(HermesTheme.muted)
            }
            Text("\(snapshot.source.items.count) 条来源消息 · 原草稿 \(snapshot.draftText.count.formatted()) 字符")
                .font(.subheadline).foregroundStyle(HermesTheme.muted)
            Text("只写入这里显示的进行中或新对话草稿，不切换来源对话、不自动发送。")
                .font(.caption).foregroundStyle(HermesTheme.muted)
        }.listRowBackground(HermesTheme.surface)
    }

    private var modeSection: some View {
        Section("写入方式") {
            Picker("写入方式", selection: $mode) {
                ForEach(PromptDraftMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("draft-quote-mode")
            Text(mode == .append ? "保留原草稿，在末尾空一行后追加完整引用。" : "用完整引用替换原草稿；原草稿非空时还需确认。")
                .font(.subheadline).foregroundStyle(HermesTheme.muted)
            if let changeMessage {
                Label(changeMessage, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                    .accessibilityIdentifier("draft-quote-changed")
                Text("此页保留打开时的预览。返回重新选择，获取最新来源与草稿；不会自动覆盖新输入。")
                    .font(.caption).foregroundStyle(HermesTheme.muted)
            }
        }.listRowBackground(HermesTheme.surface)
    }

    private var previewSection: some View {
        Section("检查完整内容") {
            if preparing { HStack { ProgressView(); Text("正在准备完整引用…").font(.subheadline) } }
            if let buildError { Text(buildError).foregroundStyle(.orange).font(.subheadline) }
            if let reference {
                DisclosureGroup("完整引用 · \(reference.count.formatted()) 字符") {
                    Text(reference).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
            DisclosureGroup("打开时的原草稿 · \(snapshot.draftText.count.formatted()) 字符") {
                Text(snapshot.draftText.isEmpty ? "（空草稿）" : snapshot.draftText).font(.subheadline).textSelection(.enabled)
            }
            if let result {
                switch result {
                case .success(let text):
                    DisclosureGroup("最终草稿 · \(text.count.formatted()) / 100,000 字符") {
                        Text(text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    }.accessibilityIdentifier("draft-quote-final-preview")
                case .failure(let error):
                    Text(error.localizedDescription).font(.subheadline).foregroundStyle(.orange)
                }
            }
            Text("完整引用按消息时间从新到旧排列，包含来源信息与完整正文，不包含收藏备注；图片只留占位，不附加图片文件。正文与引用标记都计入草稿上限，超限不会截断。")
                .font(.caption).foregroundStyle(HermesTheme.muted)
        }.listRowBackground(HermesTheme.surface)
    }

    private var actionSection: some View {
        Section {
            Button(mode == .append ? "确认追加到草稿" : "检查并替换草稿", systemImage: "text.quote") {
                if mode == .replace && !snapshot.draftText.isEmpty { confirmingReplace = true }
                else { apply(mode) }
            }.disabled(finalText == nil || changeMessage != nil).accessibilityIdentifier("draft-quote-apply")
            Button(copied ? "预览草稿已复制" : "复制预览草稿", systemImage: copied ? "checkmark" : "doc.on.doc") {
                guard let finalText else { return }
                UIPasteboard.general.string = finalText; copied = true
            }.disabled(finalText == nil).accessibilityIdentifier("draft-quote-copy")
        } footer: {
            Text("提交前核对来源、目标和原草稿全文；发生变化需重新检查。替换没有一键撤销，可先复制原草稿。保存不会停止正在生成的回复，现有待发送图片由聊天页保留；请在聊天页手动检查并发送。")
        }.listRowBackground(HermesTheme.surface)
    }

    private func apply(_ mode: PromptDraftMode) {
        do { try model.applyMessageDraftQuote(snapshot, mode: mode); applied = true; onApplied() }
        catch { failure = error.localizedDescription }
    }
}
