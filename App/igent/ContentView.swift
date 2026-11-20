import CoreKit
import LLMKit
import SwiftUI

struct ContentView: View {
    @State private var coreProbe = "检测中…"
    @State private var llmProbe = "检测中…"
    @State private var familyProbe = "检测中…"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                row(title: "CoreKit", detail: coreProbe)
                row(title: "LLMKit", detail: llmProbe)
                row(title: "厂商", detail: familyProbe)

                Spacer()

                Text("P0 骨架：词汇 + 装配器 + SSE 解码器 + 四族适配器（含 Azure 变体）")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("igent")
        }
        .task {
            coreProbe = Self.coreCheck()
            llmProbe = await Self.llmCheck()
            familyProbe = Self.familyCheck()
        }
    }

    private func row(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.subheadline.weight(.medium))
            }
            Text(detail)
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    /// CoreKit：字节 → SSE 帧 → StreamChunk → 内容块。
    static func coreCheck() -> String {
        var decoder = SSEDecoder()
        let events = decoder.feed(Array("data: 你好，世界\n\n".utf8))
        guard let payload = events.first?.data else { return "SSE 解码失败" }

        var assembler = BlockAssembler()
        assembler.push(.textDelta(index: 0, text: payload))
        assembler.push(.usage(TokenUsage(uncachedInputTokens: 12, outputTokens: 4)))
        assembler.push(.finish(.stop, meta: nil))

        let blocks = (try? assembler.blocks()) ?? []
        return "SSE → \(events.count) 帧，装配 → \(blocks.count) 块：\(blocks.map(\.plainText).joined())"
    }

    /// LLMKit：用 Anthropic 适配器解析一段极小的录制流（不走网络）。
    static func llmCheck() async -> String {
        let transport = InlineTransport(data: Data("""
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_demo","usage":{"input_tokens":7,"output_tokens":1}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"适配器就绪"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

        event: message_stop
        data: {"type":"message_stop"}

        """.utf8))

        let adapter = AnthropicAdapter(apiKey: "demo", transport: transport)
        let options = GenerateOptions(
            provider: "anthropic",
            model: "claude-sonnet-4-5",
            messages: [Message(role: .user, blocks: [.text("你好")], source: .user)]
        )

        var assembler = BlockAssembler()
        do {
            for try await chunk in adapter.stream(options) {
                assembler.push(chunk)
            }
            let blocks = try assembler.blocks()
            let usage = assembler.usage
            return "Anthropic 流解析 → \(blocks.count) 块：\(blocks.map(\.plainText).joined()) "
                + "· in \(usage?.uncachedInputTokens ?? 0) / out \(usage?.outputTokens ?? 0)"
        } catch {
            return "解析失败：\(error)"
        }
    }
}

extension ContentView {
    /// 实例化四族适配器 + Azure 变体，确认全部可构造、路由可解析。
    static func familyCheck() -> String {
        let adapters: [any LlmAdapter] = [
            OpenAICompatibleAdapter(
                profile: .openAICompatible(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1"),
                apiKey: "demo"
            ),
            AnthropicAdapter(apiKey: "demo"),
            GeminiAdapter(apiKey: "demo"),
            OpenAIResponsesAdapter(apiKey: "demo"),
            OpenAICompatibleAdapter(
                profile: .azure(resource: "demo", deployment: "gpt-4o"),
                apiKey: "demo"
            )
        ]
        let names = adapters.map { $0.profile.name }
        return "\(adapters.count) 个就绪：" + names.joined(separator: " · ")
    }
}

/// 把一段内联字节当作网络分片回放。
private struct InlineTransport: StreamTransport {
    let data: Data

    func bytes(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            var index = data.startIndex
            while index < data.endIndex {
                let end = data.index(index, offsetBy: 7, limitedBy: data.endIndex) ?? data.endIndex
                continuation.yield(data[index..<end])
                index = end
            }
            continuation.finish()
        }
    }
}

#Preview {
    ContentView()
}
