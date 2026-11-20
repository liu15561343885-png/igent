import CoreKit
import LLMKit
import SwiftUI

struct ProviderSettingsView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var editing: ProviderDraft?

    var body: some View {
        NavigationStack {
            Form {
                if env.profiles.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "还没有厂商",
                            systemImage: "key.horizontal",
                            description: Text("添加一个厂商，填上你自己的 API Key 就能开始对话。")
                        )
                    }
                }

                Section("厂商") {
                    ForEach(env.profiles, id: \.id) { profile in
                        Button {
                            editing = ProviderDraft(profile: profile, apiKey: env.apiKey(for: profile))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(profile.name)
                                        .foregroundStyle(.primary)
                                    Text(profile.baseURL.absoluteString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if env.activeProfileID == profile.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        let targets = offsets.map { env.profiles[$0] }
                        Task {
                            for profile in targets {
                                await env.delete(profile: profile)
                            }
                        }
                    }
                }

                if let active = env.activeProfile {
                    Section {
                        TextField("模型", text: Binding(
                            get: { env.activeModel },
                            set: { env.activeModel = $0 }
                        ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    } header: {
                        Text("当前使用")
                    } footer: {
                        Text("对话将发往 \(active.name)。模型名按厂商文档填写，例如 gpt-4o-mini、claude-sonnet-4-5、gemini-2.5-flash。")
                    }
                }

                Section {
                    Button {
                        editing = ProviderDraft.new()
                    } label: {
                        Label("添加厂商", systemImage: "plus.circle.fill")
                    }
                }

                if let error = env.bootError {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editing) { draft in
                ProviderEditorView(draft: draft)
            }
        }
    }
}

// MARK: - 草稿

struct ProviderDraft: Identifiable {
    let id: String
    var name: String
    var family: ProviderFamily
    var baseURL: String
    var apiKey: String
    var isNew: Bool

    static func new() -> ProviderDraft {
        ProviderDraft(
            id: UUID().uuidString,
            name: "新厂商",
            family: .openAICompatible,
            baseURL: "https://api.openai.com/v1",
            apiKey: "",
            isNew: true
        )
    }

    init(profile: ProviderProfile, apiKey: String) {
        id = profile.id
        name = profile.name
        family = profile.family
        baseURL = profile.baseURL.absoluteString
        self.apiKey = apiKey
        isNew = false
    }

    init(id: String, name: String, family: ProviderFamily, baseURL: String, apiKey: String, isNew: Bool) {
        self.id = id
        self.name = name
        self.family = family
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.isNew = isNew
    }

    /// 由表单字段生成可入库的 profile。路径与鉴权按协议族决定。
    func profile() -> ProviderProfile? {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) else { return nil }
        let capabilities: Capabilities
        let chatPath: String
        let auth: AuthStyle
        switch family {
        case .openAICompatible:
            chatPath = "/chat/completions"
            auth = .bearer
            capabilities = Capabilities(vision: true, streamUsage: true)
        case .openAIResponses:
            chatPath = "/responses"
            auth = .bearer
            capabilities = Capabilities(vision: true, reasoning: true, streamUsage: true, systemStyle: .topLevel)
        case .anthropic:
            chatPath = "/messages"
            auth = .apiKey(header: "x-api-key")
            capabilities = Capabilities(
                vision: true, reasoning: true, streamUsage: true,
                systemStyle: .topLevel, defaultMaxTokens: 4096
            )
        case .gemini:
            chatPath = "/models/{model}:streamGenerateContent?alt=sse"
            auth = .apiKey(header: "x-goog-api-key")
            capabilities = Capabilities(
                vision: true, reasoning: true, streamUsage: true,
                systemStyle: .systemInstruction, defaultMaxTokens: 8192
            )
        }
        return ProviderProfile(
            id: id,
            name: name,
            family: family,
            baseURL: url,
            chatPath: chatPath,
            capabilities: capabilities,
            auth: auth
        )
    }
}

// MARK: - 编辑

struct ProviderEditorView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProviderDraft
    @State private var revealKey = false

    init(draft: ProviderDraft) {
        _draft = State(initialValue: draft)
    }

    private var canSave: Bool {
        !draft.name.trimmingCharacters(in: .whitespaces).isEmpty
            && URL(string: draft.baseURL) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名称", text: $draft.name)
                    Picker("协议族", selection: $draft.family) {
                        Text("OpenAI 兼容").tag(ProviderFamily.openAICompatible)
                        Text("OpenAI Responses").tag(ProviderFamily.openAIResponses)
                        Text("Anthropic").tag(ProviderFamily.anthropic)
                        Text("Gemini").tag(ProviderFamily.gemini)
                    }
                } footer: {
                    Text("绝大多数国产与聚合厂商都兼容 OpenAI 协议，选第一项即可。Azure 也选第一项，把地址填成 https://<resource>.openai.azure.com 并在模型里写部署名。")
                }

                Section("端点") {
                    TextField("Base URL", text: $draft.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    if revealKey {
                        TextField("API Key", text: $draft.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField("API Key", text: $draft.apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("显示密钥", isOn: $revealKey)
                } footer: {
                    Text("密钥只存在这台设备的钥匙串里，不进数据库、不进日志。")
                }

                if draft.isNew {
                    Section {
                        Text("保存后还需要在设置里填写模型名，才能开始对话。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(draft.isNew ? "添加厂商" : "编辑厂商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private func save() {
        guard let profile = draft.profile() else { return }
        Task {
            await env.save(profile: profile, apiKey: draft.apiKey)
            env.activeProfileID = profile.id
            dismiss()
        }
    }
}
