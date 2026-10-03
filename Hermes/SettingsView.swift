import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL = ""
    @State private var apiKey = ""
    @State private var modelName = "hermes-agent"
    @State private var isTesting = false
    @State private var feedback: String?
    @State private var connected = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("你的 Agent 运行在自己的服务器上", systemImage: "server.rack")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(HermesTheme.accent)
                    Text("在 Hermes Agent 中启用 API Server，然后填写手机可访问的地址。远程连接请使用 HTTPS。")
                        .font(.system(size: 13))
                        .foregroundStyle(HermesTheme.muted)
                }
                .listRowBackground(HermesTheme.surface)

                Section("连接") {
                    TextField("https://example.com/v1", text: $serverURL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityLabel("服务地址")
                    SecureField("API_SERVER_KEY", text: $apiKey)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("API 密钥")
                    TextField("hermes-agent", text: $modelName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel("模型名称")
                }
                .listRowBackground(HermesTheme.surface)

                Section {
                    Button {
                        Task { await saveAndTest() }
                    } label: {
                        HStack {
                            Spacer()
                            if isTesting { ProgressView().padding(.trailing, 8) }
                            Text(isTesting ? "正在连接…" : "保存并测试连接")
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(isTesting || serverURL.isEmpty || apiKey.isEmpty)
                }
                .listRowBackground(HermesTheme.raised)

                if let feedback {
                    Section {
                        Label(feedback, systemImage: connected ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(connected ? Color.green : Color.orange)
                            .font(.system(size: 13))
                    }
                    .listRowBackground(HermesTheme.surface)
                }

                Section("在 Mac 上启用") {
                    Text("在 ~/.hermes/.env 中设置 API_SERVER_ENABLED=true 和 API_SERVER_KEY，然后运行 hermes gateway。默认服务端口是 8642。")
                        .font(.system(size: 13))
                        .textSelection(.enabled)
                }
                .listRowBackground(HermesTheme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(HermesTheme.background)
            .navigationTitle("连接设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .tint(HermesTheme.accent)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            serverURL = model.settings.serverURL
            apiKey = model.settings.apiKey
            modelName = model.settings.model
        }
    }

    private func saveAndTest() async {
        isTesting = true
        feedback = nil
        connected = false
        let connection = ConnectionSettings(
            serverURL: serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            model: modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        do {
            let models = try await HermesClient(settings: connection).availableModels()
            var saved = connection
            if !models.contains(saved.model), let first = models.first {
                saved.model = first
                modelName = first
            }
            try model.saveSettings(saved)
            model.recordConnectionTest(success: true)
            connected = true
            feedback = "连接成功，当前模型：\(saved.model)"
        } catch {
            // Preserve the address and key so the user can adjust the server and retry.
            do { try model.saveSettings(connection) }
            catch { feedback = error.localizedDescription; isTesting = false; return }
            model.recordConnectionTest(success: false)
            feedback = error.localizedDescription
        }
        isTesting = false
    }
}
