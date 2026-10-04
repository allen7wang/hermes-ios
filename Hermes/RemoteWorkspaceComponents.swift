import SwiftUI

struct RemoteSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(HermesTheme.muted)
            TextField(prompt, text: $text)
                .font(.subheadline).textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(HermesTheme.muted).accessibilityLabel("清空搜索")
            }
        }
        .padding(12).background(HermesTheme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct RemoteLoadBanner: View {
    let message: String
    let hasRecords: Bool
    let disabled: Bool
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(hasRecords ? "刷新失败，保留上次记录" : "读取失败", systemImage: "wifi.exclamationmark")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(message).font(.caption).textSelection(.enabled)
            Button("重试", action: retry).disabled(disabled).buttonStyle(.borderless)
        }
        .padding(.vertical, 6).listRowBackground(HermesTheme.surface)
    }
}

struct RemoteJobStatusBadge: View {
    let job: RemoteJob
    var body: some View {
        Text(job.statusLabel).font(.caption.weight(.medium))
            .foregroundStyle(job.needsAttention ? Color.orange : job.isPaused ? HermesTheme.muted : HermesTheme.accent)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background((job.needsAttention ? Color.orange : HermesTheme.accent).opacity(0.12))
            .clipShape(Capsule())
    }
}
