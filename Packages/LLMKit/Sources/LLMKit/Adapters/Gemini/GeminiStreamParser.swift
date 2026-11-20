import CoreKit
import Foundation

/// Gemini 的流式帧解析。
///
/// 与另外两族不同，Gemini 的每个 `data:` 都是一个**完整的** `GenerateContentResponse`，
/// 没有事件名、没有 `[DONE]`。思维链靠 part 上的 `"thought": true` 区分。
public struct GeminiStreamParser: Sendable {
    private var decoder = SSEDecoder()
    private var pendingUsage: TokenUsage?
    private var finishReason: FinishReason?
    private var nativeStopReason: String?
    private var responseId: String?
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

    public mutating func finish() -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        for event in decoder.finish() {
            chunks += handle(event)
        }
        markContent(chunks)
        chunks += terminal()
        return chunks
    }

    private mutating func handle(_ event: SSEEvent) -> [StreamChunk] {
        guard let data = event.data.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else {
            return []
        }

        if responseId == nil, let id = object["responseId"]?.stringValue {
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

        if let usage = object["usageMetadata"]?.objectValue, let parsed = Self.usage(usage) {
            pendingUsage = parsed
        }

        var chunks: [StreamChunk] = []

        // 被安全策略拦截的提示词不会返回 candidates，只有 promptFeedback。
        // 不读它的话这里就是"正常结束但零内容"，用户什么也看不到。
        if let feedback = object["promptFeedback"]?.objectValue,
           let block = feedback["blockReason"]?.stringValue,
           finishReason == nil {
            nativeStopReason = block
            finishReason = .contentFilter(block)
        }

        if let candidate = object["candidates"]?.arrayValue?.first?.objectValue {
            let parts = candidate["content"]?.objectValue?["parts"]?.arrayValue ?? []
            for part in parts {
                let partObject = part.objectValue
                guard let text = partObject?["text"]?.stringValue, !text.isEmpty else { continue }
                if partObject?["thought"] == .bool(true) {
                    chunks.append(.reasoningDelta(index: 1, text: text))
                } else {
                    chunks.append(.textDelta(index: 0, text: text))
                }
            }
            if let raw = candidate["finishReason"]?.stringValue {
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

    static func map(_ raw: String) -> FinishReason {
        switch raw {
        case "STOP": .stop
        case "MAX_TOKENS": .maxTokens
        case "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII":
            .contentFilter(raw)
        default: .stop
        }
    }

    /// `promptTokenCount` 含缓存命中（与 OpenAI 一致），减出去才是互斥计数。
    static func usage(_ object: [String: JSONValue]) -> TokenUsage? {
        guard let prompt = object["promptTokenCount"]?.numberValue.map({ Int($0) }) else {
            return nil
        }
        let cached = object["cachedContentTokenCount"]?.numberValue.map { Int($0) }
        let output = object["candidatesTokenCount"]?.numberValue.map { Int($0) } ?? 0

        return TokenUsage(
            uncachedInputTokens: max(0, prompt - (cached ?? 0)),
            outputTokens: output,
            totalTokens: object["totalTokenCount"]?.numberValue.map { Int($0) },
            cacheReadTokens: cached,
            reasoningTokens: object["thoughtsTokenCount"]?.numberValue.map { Int($0) }
        )
    }
}
