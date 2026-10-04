import SwiftUI
import UniformTypeIdentifiers

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else { throw BackupError.invalidFile }
        data = contents
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct BackupView: View {
    @EnvironmentObject private var model: AppModel
    @State private var document: BackupDocument?
    @State private var exporting = false
    @State private var importing = false
    @State private var pendingArchive: BackupArchive?
    @State private var preview: BackupImportReport?
    @State private var busy = false
    @State private var feedback: String?
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                Label("将你的记录保存为备份", systemImage: "externaldrive.fill")
                    .foregroundStyle(HermesTheme.accent)
                Text("包含所有连接的本机对话、图片和文字草稿，以及连接名称、地址和模型。")
                    .font(.subheadline).foregroundStyle(HermesTheme.muted)
            }
            .listRowBackground(HermesTheme.surface)

            Section {
                Button {
                    Task {
                        busy = true
                        await Task.yield()
                        do {
                            let archive = try model.makeBackup()
                            let data = try await Task.detached { try archive.encoded() }.value
                            document = BackupDocument(data: data)
                            exporting = true
                        } catch { show(error) }
                        busy = false
                    }
                } label: { Label("导出备份到文件", systemImage: "square.and.arrow.up") }
                Button { importing = true } label: { Label("从文件导入备份", systemImage: "square.and.arrow.down") }
                if busy { ProgressView("正在处理备份…") }
            } footer: {
                Text("备份不包含连接的 API 密钥。文件含有聊天内容，请保存到你信任的位置。单个备份最多 64 MB。")
            }
            .disabled(busy || model.isSending)
            .listRowBackground(HermesTheme.surface)

            if let archive = pendingArchive, let preview {
                Section("待导入的备份") {
                    LabeledContent("备份时间") { Text(archive.createdAt, format: .dateTime.year().month().day().hour().minute()) }
                    LabeledContent("连接", value: "\(archive.profiles.count) 个")
                    LabeledContent("本机对话", value: "\(archive.conversations.count) 段")
                    LabeledContent("图片", value: "\(archive.images.count) 张")
                    Text(preview.description).font(.subheadline)
                    Text(model.needsRecovery
                         ? "本机数据无法读取。恢复前会在设备上保留原文件副本，再用备份恢复记录。新导入的连接需要重新填写密钥。"
                         : "现有对话和草稿优先保留。新导入的连接会标注“已导入”，使用前需要重新填写密钥。服务端记录由服务器保存。")
                        .font(.footnote).foregroundStyle(HermesTheme.muted)
                    Button(model.needsRecovery ? "保留原文件并恢复备份" : "确认合并导入") {
                        busy = true
                        do {
                            let report = try model.importBackup(archive)
                            feedback = "恢复完成。" + report.description
                            failed = false
                            pendingArchive = nil
                            self.preview = nil
                        } catch { show(error) }
                        busy = false
                    }
                    .disabled(busy || model.isSending)
                    Button("取消导入", role: .cancel) { pendingArchive = nil; self.preview = nil }
                        .disabled(busy)
                }
                .listRowBackground(HermesTheme.surface)
            }
            if let feedback {
                Section {
                    Label(feedback, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle.fill")
                        .font(.subheadline).foregroundStyle(failed ? Color.orange : Color.green)
                }
                .listRowBackground(HermesTheme.surface)
            }
            if model.isSending {
                Section { Text("回复完成或停止后，即可导入或导出备份。").font(.footnote) }
                    .listRowBackground(HermesTheme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(HermesTheme.background)
        .navigationTitle("备份与恢复")
        .navigationBarTitleDisplayMode(.inline)
        .tint(HermesTheme.accent)
        .interactiveDismissDisabled(busy)
        .fileExporter(isPresented: $exporting, document: document, contentType: .json,
                      defaultFilename: "Hermes-Backup-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash)))") { result in
            switch result {
            case .success: feedback = "备份已保存。"; failed = false
            case .failure(let error): show(error)
            }
            document = nil
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            pendingArchive = nil
            preview = nil
            feedback = nil
            Task {
                busy = true
                defer { busy = false }
                do {
                    let url = try result.get()
                    let archive = try await Task.detached {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        return try BackupArchive.read(from: url)
                    }.value
                    preview = try model.previewImport(archive)
                    pendingArchive = archive
                } catch { show(error) }
            }
        }
    }

    private func show(_ error: Error) {
        failed = true
        feedback = error.localizedDescription
    }
}
