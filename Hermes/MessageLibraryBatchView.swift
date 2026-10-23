import SwiftUI
import UIKit

private struct PreparedMessageBatchText {
    let includeNotes: Bool
    let text: String
}

struct MessageLibraryBatchExportView: View {
    @Environment(\.dismiss) private var dismiss
    let snapshot: MessageLibraryBatchSnapshot
    @State private var includeNotes = false
    @State private var prepared: PreparedMessageBatchText?
    @State private var preparing = true
    @State private var buildError: String?
    @State private var exportedDocument: ConversationDocument?
    @State private var exporting = false
    @State private var error: String?
    @State private var copied = false
    private var currentText: String? { prepared?.includeNotes == includeNotes ? prepared?.text : nil }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(snapshot.profileName, systemImage: "externaldrive").foregroundStyle(HermesTheme.accent)
                    Text("\(snapshot.items.count) 条消息的完整文字").font(.title3.bold())
                    Text("按消息时间从新到旧排列。此页保留打开时的完整快照，后续修改需返回重新选择；恢复对话及附件请使用 JSON 备份。")
                        .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    Toggle("包含收藏备注", isOn: $includeNotes).accessibilityIdentifier("library-batch-export-notes")
                    Text("默认不包含备注。启用后，所选消息已有的非空备注会出现在文件和复制文字中。图片仅保留占位说明，不包含图片文件。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                    if preparing || currentText == nil && buildError == nil {
                        HStack { ProgressView().controlSize(.small); Text("正在准备完整汇编…").font(.caption) }
                    }
                    if let buildError { Label(buildError, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange) }
                }.listRowBackground(HermesTheme.surface)
                Section("检查所选消息") {
                    ForEach(MessageLibraryBatch.ordered(snapshot.items)) { item in
                        DisclosureGroup {
                            MessageBatchSnapshotBody(item: item, includeNotes: includeNotes)
                        } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.conversationTitle).font(.subheadline.weight(.semibold))
                                Text("\(item.roleLabel) · \(item.conversationArchived ? "已归档" : "进行中") · \(item.message.content.count.formatted()) 正文字符")
                                    .font(.caption).foregroundStyle(HermesTheme.muted)
                            }
                        }
                    }
                }.listRowBackground(HermesTheme.surface)
                if let currentText {
                    Section {
                        DisclosureGroup("查看完整 Markdown · \(currentText.count.formatted()) 字符") {
                            Text(currentText).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }.listRowBackground(HermesTheme.surface)
                }
                Section {
                    Button("导出 Markdown 文件", systemImage: "square.and.arrow.up") {
                        guard let currentText else { return }
                        exportedDocument = ConversationDocument(text: currentText); exporting = true
                    }.accessibilityIdentifier("library-batch-export-file")
                    Button(copied ? "完整汇编已复制" : "复制完整汇编", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        guard let currentText else { return }
                        UIPasteboard.general.string = currentText; copied = true
                    }.accessibilityIdentifier("library-batch-export-copy")
                } footer: {
                    Text("输出包含来源对话、项目、标签、角色、UTC 时间、归档状态及完整正文。连接配置、项目资料库正文与未选消息不会自动加入。")
                }.disabled(currentText == nil).listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("消息汇编检查").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回选择") { dismiss() } } }
            .task(id: includeNotes) {
                let snapshot = snapshot, notes = includeNotes
                preparing = true; buildError = nil; copied = false
                let worker = Task.detached(priority: .userInitiated) { try MessageLibraryBatch.markdown(snapshot, includeNotes: notes) }
                do {
                    let text = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                    guard !Task.isCancelled else { return }
                    prepared = PreparedMessageBatchText(includeNotes: notes, text: text); preparing = false
                } catch {
                    guard !Task.isCancelled else { return }
                    prepared = nil; preparing = false; buildError = error.localizedDescription
                }
            }
            .fileExporter(isPresented: $exporting, document: exportedDocument, contentType: ConversationDocument.markdownType,
                defaultFilename: ConversationWorkbench.filename(snapshot.profileName + "-消息汇编")) { result in
                if case .failure(let failure) = result, (failure as? CocoaError)?.code != .userCancelled { error = failure.localizedDescription }
            }
            .alert("导出失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

struct MessageLibraryBookmarkReviewView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let snapshot: MessageLibraryBatchSnapshot
    let operation: MessageLibraryBatchOperation
    let onApplied: (MessageLibraryBatchReport) -> Void
    @State private var confirmingRemoval = false
    @State private var error: String?
    private var report: MessageLibraryBatchReport { MessageLibraryBatch.report(snapshot.items, operation: operation) }
    private var changeMessage: String? {
        do {
            let current = try model.makeMessageLibraryBatch(snapshot.items.map(\.id), profileID: snapshot.profileID)
            return current.profileName == snapshot.profileName && current.items == snapshot.items ? nil : MessageLibraryBatchError.changed.localizedDescription
        } catch { return error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(snapshot.profileName, systemImage: "externaldrive").foregroundStyle(HermesTheme.accent)
                    Text(operation.title).font(.title2.bold())
                    HStack(spacing: 12) {
                        metric("所选消息", value: report.requested)
                        metric("将变更", value: report.changed)
                        metric("无需变更", value: report.unchanged)
                    }
                    if operation == .remove {
                        Text("取消收藏会同时移除 \(report.notesRemoved) 条非空收藏备注。原消息和图片保留；需要备注时，可先返回导出包含备注的汇编。")
                            .font(.subheadline).foregroundStyle(.orange)
                    } else {
                        Text("仅为尚未收藏的消息添加收藏。已有收藏日期和备注保留；不会重新排序对话、改动草稿或发送请求。")
                            .font(.subheadline).foregroundStyle(HermesTheme.muted)
                    }
                    if let changeMessage {
                        Label(changeMessage, systemImage: "exclamationmark.triangle").font(.subheadline).foregroundStyle(.orange)
                            .accessibilityIdentifier("library-batch-bookmarks-changed")
                    }
                }.listRowBackground(HermesTheme.surface)
                Section("检查消息与当前备注") {
                    ForEach(snapshot.items) { item in
                        DisclosureGroup {
                            MessageBatchSnapshotBody(item: item, includeNotes: true)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.conversationTitle).font(.subheadline.weight(.semibold))
                                Text("\(item.roleLabel) · \(item.conversationArchived ? "已归档" : "进行中") · \(item.message.bookmark == nil ? "未收藏" : "已收藏")")
                                    .font(.caption).foregroundStyle(HermesTheme.muted)
                                if let note = item.message.bookmark?.note, !note.isEmpty {
                                    Label(note, systemImage: "note.text").font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(2)
                                }
                            }
                        }
                    }
                }.listRowBackground(HermesTheme.surface)
                Section {
                    Button {
                        if operation == .remove && report.changed > 0 { confirmingRemoval = true } else { apply() }
                    } label: {
                        Label(operation.title, systemImage: operation == .add ? "bookmark" : "bookmark.slash")
                    }.foregroundStyle(operation == .remove ? .red : HermesTheme.accent)
                        .disabled(changeMessage != nil).accessibilityIdentifier("library-batch-bookmarks-apply")
                } footer: {
                    Text("提交前重新核对所有消息及来源元数据；任一所选内容改变，则整批停止并要求重新检查。生成期间可整理既有消息，当前聊天与草稿保持原状。")
                }.listRowBackground(HermesTheme.surface)
            }
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(HermesTheme.background)
            .navigationTitle("批量收藏检查").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回选择") { dismiss() } } }
            .confirmationDialog("取消 \(report.changed) 条消息的收藏？", isPresented: $confirmingRemoval, titleVisibility: .visible) {
                Button("取消收藏并移除备注", role: .destructive) { apply() }
                Button("保留收藏", role: .cancel) {}
            } message: { Text("会移除 \(report.notesRemoved) 条非空备注，原消息保留。此操作没有一键撤销。") }
            .alert("收藏整理失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(value)").font(.title3.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(HermesTheme.muted)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func apply() {
        do { let result = try model.changeMessageLibraryBookmarks(snapshot, operation: operation); onApplied(result); dismiss() }
        catch { self.error = error.localizedDescription }
    }
}

private struct MessageBatchSnapshotBody: View {
    let item: MessageLibraryItem
    let includeNotes: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.message.createdAt, format: .dateTime.year().month().day().hour().minute())
                .font(.caption).foregroundStyle(HermesTheme.muted)
            if let project = item.projectName { Label(project, systemImage: "folder").font(.caption).foregroundStyle(HermesTheme.accent) }
            if !item.conversationTags.isEmpty { Text(item.conversationTags.map { "#" + $0 }.joined(separator: " ")).font(.caption) }
            Text(item.message.content.isEmpty ? "（无文字正文）" : item.message.content).font(.subheadline).textSelection(.enabled)
            if item.message.imageID != nil {
                Label("图片未包含在汇编中，完整附件请使用 JSON 备份。", systemImage: "photo").font(.caption).foregroundStyle(HermesTheme.muted)
            }
            if includeNotes, let note = item.message.bookmark?.note, !note.isEmpty {
                Label("收藏备注", systemImage: "note.text").font(.subheadline.weight(.semibold))
                Text(note).font(.subheadline).textSelection(.enabled)
            }
        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
