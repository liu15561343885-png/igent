import LLMKit
import SwiftUI

/// 图片生成面板。生成结果直接落盘并作为一条助手消息写进当前会话。
struct ImageGenView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let model: ChatViewModel

    @State private var prompt = ""
    @State private var isGenerating = false
    @State private var errorText: String?

    private var canGenerate: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("描述你想要的画面…", text: $prompt, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("提示词")
                } footer: {
                    Text("描述越具体越好：主体、风格、构图、光线。中文通常也能work，但英文提示词效果更稳。")
                }

                Section {
                    TextField("图片模型", text: Binding(
                        get: { env.imageModel },
                        set: { env.imageModel = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                } header: {
                    Text("模型")
                } footer: {
                    Text("OpenAI 填 gpt-image-1 或 dall-e-3；Gemini 填 gemini-2.5-flash-image。用的是当前厂商的密钥。")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await generate() }
                    } label: {
                        HStack {
                            if isGenerating {
                                ProgressView().controlSize(.small)
                            }
                            Text(isGenerating ? "生成中…" : "生成")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(!canGenerate)
                } footer: {
                    Text("生成需要几十秒。关掉这个面板不会中断，结果会出现在对话里。")
                }
            }
            .navigationTitle("生成图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }

    private func generate() async {
        errorText = nil
        guard let adapter = env.makeImageAdapter() else {
            errorText = "当前厂商还没有配置密钥。"
            return
        }

        isGenerating = true
        defer { isGenerating = false }

        let ok = await model.generateImage(
            prompt: prompt,
            adapter: adapter,
            model: env.imageModel
        )
        if ok {
            prompt = ""
            dismiss()
        } else {
            errorText = model.lastError ?? "生成失败"
        }
    }
}
