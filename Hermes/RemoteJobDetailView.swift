import SwiftUI

struct RemoteJobDetailView: View {
    @ObservedObject var workspace: RemoteWorkspaceModel
    let jobID: String
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var confirmingRun = false
    @State private var confirmingDelete = false

    private var job: RemoteJob? { workspace.jobs.first { $0.id == jobID } }

    var body: some View {
        Group {
            if let job {
                List {
                    if let error = workspace.jobDetailError {
                        RemoteLoadBanner(message: error, hasRecords: true, disabled: workspace.jobActionsDisabled) {
                            Task { await workspace.refreshJob(jobID) }
                        }
                    }
                    if let notice = workspace.notice {
                        Text(notice).font(.caption).foregroundStyle(HermesTheme.accent)
                    }
                    Section("任务") {
                        HStack(alignment: .top) {
                            Text(job.name).font(.headline).textSelection(.enabled)
                            Spacer()
                            RemoteJobStatusBadge(job: job)
                        }
                        Text(job.prompt?.isEmpty == false ? job.prompt! : "未提供任务说明")
                            .textSelection(.enabled)
                        LabeledContent("任务 ID", value: job.id).font(.caption).textSelection(.enabled)
                    }
                    Section {
                        LabeledContent("日程", value: job.scheduleDisplay ?? "未设置")
                        LabeledContent("下次运行", value: RemoteTimestamp.display(job.nextRunAt))
                        LabeledContent("上次运行", value: RemoteTimestamp.display(job.lastRunAt))
                        LabeledContent("上次结果", value: job.lastStatusLabel)
                    } header: { Text("运行时间与结果") } footer: {
                        Text("带时区的时间按设备时区（\(TimeZone.current.identifier)）显示；未提供时区的时间保留原文。日程仍按服务端时区执行。")
                    }
                    if let error = job.lastError, !error.isEmpty {
                        Section("最近错误") {
                            Text(error).font(.subheadline).foregroundStyle(.orange).textSelection(.enabled)
                        }
                    }
                    Section {
                        Button("编辑任务", systemImage: "pencil") { editing = true }
                        if job.state != "completed" && job.state != "error" {
                            Button(job.isPaused ? "恢复任务" : "暂停任务", systemImage: job.isPaused ? "play" : "pause") {
                                Task { await workspace.toggleJob(job) }
                            }
                        }
                        Button("立即运行", systemImage: "bolt") { confirmingRun = true }
                        Button("删除任务", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                    } header: { Text("管理") } footer: {
                        Text("操作会直接更新服务端任务。手动运行提交后，请刷新查看运行结果。")
                    }
                    .disabled(workspace.jobActionsDisabled)
                }
                .scrollContentBackground(.hidden)
                .refreshable { await workspace.refreshJob(jobID) }
                .sheet(isPresented: $editing) {
                    RemoteJobEditorView(job: job) { Task { await workspace.refreshJob(jobID) } }
                }
                .confirmationDialog("立即运行“\(job.name)”？", isPresented: $confirmingRun) {
                    Button("立即运行") { Task { await workspace.runJob(job) } }
                    Button("取消", role: .cancel) {}
                } message: { Text("此操作会在服务器上调度一次运行；已暂停的任务也会恢复。") }
                .confirmationDialog("删除“\(job.name)”？", isPresented: $confirmingDelete) {
                    Button("删除任务", role: .destructive) {
                        Task { if await workspace.deleteJob(job) { dismiss() } }
                    }
                    Button("取消", role: .cancel) {}
                } message: { Text("这会从服务器删除任务，并取消正在运行的任务。") }
            } else {
                ContentUnavailableView("任务已不在列表中", systemImage: "calendar.badge.exclamationmark",
                    description: Text("返回列表并刷新，以查看服务端当前的任务。"))
            }
        }
        .background(HermesTheme.background)
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if workspace.refreshingJobID == jobID || workspace.busyJobID == jobID { ProgressView() }
                else {
                    Button { Task { await workspace.refreshJob(jobID) } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(workspace.jobActionsDisabled).accessibilityLabel("刷新任务详情")
                }
            }
        }
        .task { await workspace.refreshJob(jobID) }
    }
}
