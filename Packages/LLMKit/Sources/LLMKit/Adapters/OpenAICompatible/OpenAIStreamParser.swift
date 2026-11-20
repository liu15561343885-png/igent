import CoreKit
import Foundation

/// OpenAI Chat Completions 的流式帧解析。
///
/// 输入是 SSE 帧，输出是 `StreamChunk`。块索引约定：正文 0，思维链 1。
/// 兼容 `delta.reasoning_content`（DeepSeek / Qwen）与 `delta.reasoning`（OpenRouter）。
public struct OpenAIStreamParser: Sendable {
    private var decoder = SSEDecoder()
    private var responseId: String?
    private var finishReason: FinishReason?
    private var nativeStopReason: String?
    private var pendingUsage: TokenUsage?
    private var didFinish = false
    /// 是否产出过实质性内容。用来识别"连接正常但没有内容"的空响应。
    private var sawContent = false

    public init() {}

    public mutating func feed(_ data: Data) -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        for event in decoder.feed(data) {
            chunks += handle(event)
        }
        markContent(chunks)
        return chunks
    }

    /// 流结束。补发 usage 与 finish（顺序由契约固定：usage 在前）。
    public mutating func finish() -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        for event in decoder.finish() {
            chunks += handle(event)
        }
        markContent(chunks)
        chunks += terminal()
        return chunks
    }

    // MARK: - 帧处理

    private mutating func handle(_ event: SSEEvent) -> [StreamChunk] {
        let payload = event.data.trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" {
            return terminal()
        }

        guard let data = payload.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else {
            return []
        }

        if responseId == nil, let id = object["id"]?.stringValue {
            responseId = id
        }

        if let error = object["error"]?.objectValue {
            let failure = LlmFailure(
                message: error["message"]?.stringValue ?? "provider error",
                code: .server
            )
            didFinish = true
            return [.finish(.error(failure), meta: meta())]
        }

        if let usage = object["usage"]?.objectValue, let parsed = Self.usage(usage) {
            pendingUsage = parsed
        }

        var chunks: [StreamChunk] = []
        if let choice = object["choices"]?.arrayValue?.first?.objectValue {
            if let delta = choice["delta"]?.objectValue {
                if let text = delta["content"]?.stringValue, !text.isEmpty {
                    chunks.append(.textDelta(index: 0, text: text))
                }
                let reasoning = delta["reasoning_content"]?.stringValue
                    ?? delta["reasoning"]?.stringValue
                if let reasoning, !reasoning.isEmpty {
                    chunks.append(.reasoningDelta(index: 1, text: reasoning))
                }
            }
            if let raw = choice["finish_reason"]?.stringValue {
                nativeStopReason = raw
                finishReason = Self.map(raw)
            }
        }
        return chunks
    }

    private mutating func markContent(_ chunks: [StreamChunk]) {
        for chunk in chunks {
            switch chunk {
            case let .textDelta(_, text), let .reasoningDelta(_, text):
                if !text.isEmpty { sawContent = true }
            case let .blockEnd(_, block):
                if !block.plainText.isEmpty { sawContent = true }
            default:
                break
            }
        }
    }

    private mutating func terminal() -> [StreamChunk] {
        guard !didFinish else { return [] }
        didFinish = true
        var chunks: [StreamChunk] = []
        if let usage = pendingUsage {
            chunks.append(.usage(usage))
            pendingUsage = nil
        }
        if finishReason == nil, !sawContent {
            // 200 + 一段 HTML、被代理截断、或服务端根本没按 SSE 回：
            // 以前这里会报 .stop，用户看到的是"发出去了但没有任何回复"。
            chunks.append(.finish(
                .error(LlmFailure(message: "服务端返回了空响应", code: .emptyResponse)),
                meta: meta()
            ))
        } else {
            chunks.append(.finish(finishReason ?? .stop, meta: meta()))
        }
        return chunks
    }

    private func meta() -> ProviderMeta? {
        guard responseId != nil || nativeStopReason != nil else { return nil }
        return ProviderMeta(responseId: responseId, nativeStopReason: nativeStopReason)
    }

    // MARK: - 映射

    static func map(_ raw: String) -> FinishReason {
        switch raw {
        case "stop", "end_turn", "stop_sequence": .stop
        case "length", "max_tokens": .maxTokens
        case "content_filter": .contentFilter(nil)
        // 不声明工具，理论上不会出现；出现也按正常结束处理，不伪造失败。
        default: .stop
        }
    }

    /// OpenAI 的 `prompt_tokens` **包含**缓存命中，必须减出去才是互斥计数。
    static func usage(_ object: [String: JSONValue]) -> TokenUsage? {
        let prompt = object["prompt_tokens"]?.numberValue.map { Int($0) }
        let completion = object["completion_tokens"]?.numberValue.map { Int($0) }
        guard let prompt, let completion else { return nil }

        let cached = object["prompt_tokens_details"]?.objectValue?["cached_tokens"]?.numberValue
            .map { Int($0) }
        let uncached = max(0, prompt - (cached ?? 0))

        return TokenUsage(
            uncachedInputTokens: uncached,
            outputTokens: completion,
            totalTokens: object["total_tokens"]?.numberValue.map { Int($0) },
            cacheReadTokens: cached
        )
    }
}
