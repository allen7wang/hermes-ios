import SwiftUI

struct PromptTemplateEditRequest: Identifiable {
    let id = UUID()
    var templateID: UUID?
    var title = ""
    var body = ""
}

struct PromptLibraryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    let contextTitle: String
    let currentDraft: () -> String
    let onApply: (String, PromptDraftMode) throws -> Void
    @State private var query = ""
    @State private var onlyMine = false
    @State private var editing: PromptTemplateEditRequest?
    @State private var deleting: PromptTemplate?
    @State private var confirmingDeletion = false
    @State private var failure: String?

    private var mine: [PromptTemplate] {
        PromptTemplate.filtered(model.profiles.first { $0.id == profileID }?.templates ?? [], query: query)
    }
    private var examples: [PromptTemplate] { onlyMine ? [] : PromptTemplate.filtered(PromptTemplate.builtIns, query: query) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(model.profiles.first { $0.id == profileID }?.name ?? "连接") · \(contextTitle) · 套用后手动发送")
                        .font(.caption).foregroundStyle(HermesTheme.muted).lineLimit(2)
                    Picker("模板范围", selection: $onlyMine) {
                        Text("全部").tag(false)
                        Text("我的模板").tag(true)
                    }.pickerStyle(.segmented)
                }.padding(16)
                if mine.isEmpty && examples.isEmpty {
                    if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { ContentUnavailableView.search(text: query) }
                    else {
                        ContentUnavailableView("还没有自建模板", systemImage: "text.badge.plus",
                            description: Text("点按右上角“＋”创建模板，或在“全部”中复制内置示例。"))
                    }
                } else {
                    List {
                        if !mine.isEmpty {
                            Section("我的模板 · \(mine.count)") {
                                ForEach(mine) { template in
                                    row(template)
                                        .contextMenu {
                                            Button(template.pinned ? "取消置顶" : "置顶", systemImage: "pin") {
                                                perform { try model.togglePromptPin(template.id, profileID: profileID) }
                                            }
                                            Button("编辑模板", systemImage: "pencil") {
                                                editing = PromptTemplateEditRequest(templateID: template.id, title: template.title, body: template.body)
                                            }
                                            Button("删除模板", systemImage: "trash", role: .destructive) {
                                                deleting = template
                                                confirmingDeletion = true
                                            }
                                        }
                                }
                            }
                        }
                        if !examples.isEmpty {
                            Section("内置示例 · 可复制后修改") {
                                ForEach(examples) { template in
                                    row(template).contextMenu {
                                        Button("复制为我的模板", systemImage: "doc.on.doc") {
                                            editing = PromptTemplateEditRequest(title: template.title + "（副本）", body: template.body)
                                        }
                                    }
                                }
                            }
                        }
                    }.scrollContentBackground(.hidden)
                }
            }
            .background(HermesTheme.background)
            .navigationTitle("提示词模板").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模板名称或正文")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("新建模板", systemImage: "plus") { editing = PromptTemplateEditRequest() }
                        Button("从当前草稿创建", systemImage: "square.and.pencil") {
                            editing = PromptTemplateEditRequest(body: currentDraft())
                        }.disabled(currentDraft().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } label: { Image(systemName: "plus") }
                    .accessibilityLabel("创建提示词模板").disabled(model.needsRecovery)
                }
            }
            .sheet(item: $editing) { request in PromptTemplateEditorView(request: request, profileID: profileID) }
            .confirmationDialog("删除模板「\(deleting?.title ?? "")」？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                if let template = deleting {
                    Button("删除模板", role: .destructive) {
                        perform { try model.deletePromptTemplate(template.id, profileID: profileID) }
                        deleting = nil
                    }.accessibilityIdentifier("confirm-delete-template")
                }
                Button("取消", role: .cancel) { deleting = nil }
            } message: { Text("已套用到草稿的文字会保留。") }
            .alert("模板操作失败", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button("知道了", role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
        }
        .tint(HermesTheme.accent).preferredColorScheme(.dark)
    }

    private func row(_ template: PromptTemplate) -> some View {
        NavigationLink {
            PromptTemplateFillView(template: template, currentDraft: currentDraft) { text, mode in
                guard model.activeProfileID == profileID else { throw PromptError.changedContext }
                try onApply(text, mode)
                dismiss()
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(template.title).font(.headline)
                    if template.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(HermesTheme.accent).accessibilityLabel("已置顶") }
                }
                Text(template.body).font(.subheadline).foregroundStyle(HermesTheme.muted).lineLimit(3)
                if let variables = try? PromptRendering.variables(in: template.body), !variables.isEmpty {
                    Text("\(variables.count) 个变量 · " + variables.joined(separator: "、"))
                        .font(.caption).foregroundStyle(HermesTheme.accent).lineLimit(2)
                }
            }.padding(.vertical, 6)
        }.listRowBackground(HermesTheme.surface).accessibilityIdentifier("template-row-\(template.id)")
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() }
        catch { failure = error.localizedDescription }
    }
}

private struct PromptTemplateEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: PromptTemplateEditRequest
    let profileID: UUID
    @State private var title: String
    @State private var text: String
    @State private var failure: String?
    private enum Field: Hashable { case title, body }
    @FocusState private var focusedField: Field?

    init(request: PromptTemplateEditRequest, profileID: UUID) {
        self.request = request; self.profileID = profileID
        _title = State(initialValue: request.title); _text = State(initialValue: request.body)
    }

    private var validation: String? {
        do { try PromptTemplate(title: title, body: text).validate(); return nil }
        catch { return error.localizedDescription }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("例如：项目周报", text: $title).accessibilityIdentifier("prompt-template-name").focused($focusedField, equals: .title)
                } header: { Text("模板名称") } footer: { Text("\(title.count) / 60 字符") }
                Section {
                    TextField("请根据 {{主题}} …", text: $text, axis: .vertical)
                        .lineLimit(8...20).accessibilityIdentifier("prompt-template-body").focused($focusedField, equals: .body)
                } header: { Text("提示词正文") } footer: {
                    Text("\(text.count) / 10,000 字符。用 {{主题}} 标记变量；名称使用文字、数字或下划线，最多 20 个变量。双大括号为变量专用。")
                }
                if let names = try? PromptRendering.variables(in: text), !names.isEmpty {
                    Section("识别到的变量") { Text(names.joined(separator: "、")).foregroundStyle(HermesTheme.accent) }
                }
                if let message = failure ?? validation {
                    Section { Text(message).font(.footnote).foregroundStyle(HermesTheme.muted) }
                }
                Section { Text("保存在当前连接，随备份导出。变量填写值仅在套用后保存到草稿。").font(.footnote).foregroundStyle(HermesTheme.muted) }
            }
            .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).background(HermesTheme.background)
            .navigationTitle(request.templateID == nil ? "新建模板" : "编辑模板").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focusedField = nil }.accessibilityLabel("收起键盘")
                }
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        do {
                            try model.savePromptTemplate(id: request.templateID, title: title, body: text, profileID: profileID)
                            dismiss()
                        } catch { failure = error.localizedDescription }
                    }.disabled(validation != nil || model.needsRecovery)
                }
            }
        }.tint(HermesTheme.accent).preferredColorScheme(.dark)
    }
}

private struct PromptTemplateFillView: View {
    let template: PromptTemplate
    let currentDraft: () -> String
    let onApply: (String, PromptDraftMode) throws -> Void
    @State private var values: [String: String] = [:]
    @State private var mode: PromptDraftMode = .append
    @State private var confirmingReplace = false
    @State private var failure: String?
    @FocusState private var focusedVariable: String?
    private var variables: [String] { (try? PromptRendering.variables(in: template.body)) ?? [] }
    private var rendered: Result<String, Error> { Result { try PromptRendering.render(template.body, values: values) } }

    var body: some View {
        Form {
            if !variables.isEmpty {
                Section("填写变量") {
                    ForEach(variables, id: \.self) { name in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(HermesTheme.accent)
                            TextField("填写\(name)", text: Binding(get: { values[name] ?? "" }, set: { values[name] = $0 }), axis: .vertical)
                                .lineLimit(2...8).accessibilityLabel("模板变量：\(name)").focused($focusedVariable, equals: name)
                            if (values[name]?.count ?? 0) > PromptRendering.valueLimit {
                                Text("最多 10,000 字符").font(.caption).foregroundStyle(.orange)
                            }
                        }.padding(.vertical, 4)
                    }
                }
            }
            Section("套用预览") {
                switch rendered {
                case .success(let text):
                    Text(text).font(.subheadline).textSelection(.enabled).accessibilityIdentifier("prompt-preview")
                case .failure(let error):
                    Text(error.localizedDescription).font(.subheadline).foregroundStyle(HermesTheme.muted)
                }
            }
            Section {
                Picker("套用方式", selection: $mode) {
                    ForEach(PromptDraftMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented)
                Text(mode == .append ? "保留当前文字，在末尾追加提示词。" : "用预览文字替换当前草稿，已有文字需确认后才会替换。")
                    .font(.footnote).foregroundStyle(HermesTheme.muted)
                Button("套用到草稿", systemImage: "square.and.pencil") {
                    if mode == .replace && !currentDraft().isEmpty { confirmingReplace = true }
                    else { apply() }
                }.disabled((try? rendered.get()) == nil)
                Text("套用后返回对话；检查草稿，再手动发送。图片保持当前选择，模板本身不附带图片。")
                    .font(.footnote).foregroundStyle(HermesTheme.muted)
            }
            if let failure { Section { Text(failure).foregroundStyle(.orange) } }
            Section {
                DisclosureGroup("查看模板原文") { Text(template.body).font(.caption).foregroundStyle(HermesTheme.muted) }
            }
        }
        .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively).background(HermesTheme.background)
        .navigationTitle(template.title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { focusedVariable = nil }.accessibilityLabel("收起键盘")
            }
        }
        .confirmationDialog("替换当前草稿？", isPresented: $confirmingReplace, titleVisibility: .visible) {
            Button("确认替换", role: .destructive) { apply() }
            Button("取消", role: .cancel) {}
        } message: { Text("原草稿文字将被预览内容替换。") }
    }

    private func apply() {
        do { try onApply(rendered.get(), mode) }
        catch { failure = error.localizedDescription }
    }
}
