import SwiftUI

struct RemoteJobEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let job: RemoteJob?
    let onSave: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    @State private var schedule = "every 1h"
    @State private var saving = false
    @State private var errorMessage: String?

    private var fields: [String: String] {
        let values = ["name": name.trimmingCharacters(in: .whitespacesAndNewlines),
                      "prompt": prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                      "schedule": schedule.trimmingCharacters(in: .whitespacesAndNewlines)]
        guard let job else { return values }
        let original = ["name": job.name, "prompt": job.prompt ?? "", "schedule": job.editableSchedule]
        return values.filter { original[$0.key] != $0.value }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 200 &&
        (job != nil || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && prompt.count <= 5000 &&
        !schedule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !fields.isEmpty && !saving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("任务") {
                    TextField("名称", text: $name)
                    TextField("让 Hermes 做什么", text: $prompt, axis: .vertical).lineLimit(3...10)
                    Text("名称最多 200 字，任务说明最多 5000 字。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }
                Section("运行时间") {
                    TextField("every 1h", text: $schedule)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("示例：every 1h、every day at 9am、0 9 * * *、in 30m。具体时间按 Hermes 服务端时区计算。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }
                Section {
                    Text(job == nil ? "任务由 Hermes 服务端调度。" : "保存后会更新服务端任务；修改日程会重新计算下次运行时间。")
                        .font(.caption).foregroundStyle(HermesTheme.muted)
                }
            }
            .disabled(saving)
            .scrollContentBackground(.hidden)
            .background(HermesTheme.background)
            .navigationTitle(job == nil ? "新建定时任务" : "编辑定时任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await save() } } label: {
                        if saving { ProgressView() } else { Text(job == nil ? "创建" : "保存") }
                    }.disabled(!canSave)
                }
            }
            .tint(HermesTheme.accent)
            .alert("保存失败", isPresented: Binding(
                get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(saving)
        .onAppear {
            if let job { name = job.name; prompt = job.prompt ?? ""; schedule = job.editableSchedule }
        }
    }

    private func save() async {
        guard canSave else { return }
        let changedFields = fields
        saving = true
        defer { saving = false }
        do {
            let client = HermesClient(settings: model.settings)
            if let job {
                _ = try await client.updateJob(job.id, fields: changedFields)
            } else {
                _ = try await client.createJob(name: changedFields["name"]!, schedule: changedFields["schedule"]!,
                                               prompt: changedFields["prompt"]!)
            }
            onSave()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
