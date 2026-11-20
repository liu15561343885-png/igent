import CoreKit
import Foundation

/// OpenAI Responses 的流式帧解析。
///
/// 事件名以 `response.` 开头，正文增量是 `response.output_text.delta`，
/// 思维链摘要走 `response.reasoning_summary_text.delta`，终态是 `response.completed`。
public struct OpenAIResponsesStreamParser: Sendable {
    private var decoder = SSEDecoder()
    private var responseId: String?
    private var pendingUsage: TokenUsage?
    private var finishReason: FinishReason?
    private var nativeStopReason: String?
    private var didFinish = false

    public init() {}

    public mutating func feed(_ data: Data) -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        for event in decoder.feed(data) {
            chunks += handle(event)
        }
        return chunks
    }

    public mutating func finish() -> [StreamChunk] {
        var chunks: [StreamChunk] = []
        for event in decoder.finish() {
            chunks += handle(event)
        }
        chunks += terminal()
        return chunks
    }

    private mutating func handle(_ event: SSEEvent) -> [StreamChunk] {
        guard let data = event.data.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else {
            return []
        }

        // 有的实现只给 data 里的 `type`，有的两者都给；以事件名为准、type 兜底。
        let name = event.event ?? object["type"]?.stringValue ?? ""

        switch name {
        case "response.created", "response.in_progress":
            captureResponse(object["response"]?.objectValue)
            return []

        case "response.output_text.delta":
            guard let delta = object["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.textDelta(index: 0, text: delta)]

        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = object["delta"]?.stringValue, !delta.isEmpty else { return [] }
            return [.reasoningDelta(index: 1, text: delta)]

        case "response.completed":
            captureResponse(object["response"]?.objectValue)
            return terminal()

        case "response.incomplete":
            captureResponse(object["response"]?.objectValue)
            finishReason = .maxTokens
            nativeStopReason = object["response"]?.objectValue?["incomplete_details"]?
                .objectValue?["reason"]?.stringValue
            return terminal()

        case "response.failed", "error":
            let error = object["response"]?.objectValue?["error"]?.objectValue
                ?? object["error"]?.objectValue
            let failure = LlmFailure(
                message: error?["message"]?.stringValue ?? "provider error",
                code: error?["code"]?.stringValue == "rate_limit_exceeded" ? .rateLimit : .server
            )
            didFinish = true
            return [.finish(.error(failure), meta: meta())]

        default:
            return []
        }
    }

    private mutating func captureResponse(_ response: [String: JSONValue]?) {
        guard let response else { return }
        if let id = response["id"]?.stringValue {
            responseId = id
        }
        if let usage = response["usage"]?.objectValue, let parsed = Self.usage(usage) {
            pendingUsage = parsed
        }
        if let raw = response["status"]?.stringValue {
            nativeStopReason = raw
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
        chunks.append(.finish(finishReason ?? .stop, meta: meta()))
        return chunks
    }

    private func meta() -> ProviderMeta? {
        guard responseId != nil || nativeStopReason != nil else { return nil }
        return ProviderMeta(responseId: responseId, nativeStopReason: nativeStopReason)
    }

    /// `input_tokens` 含缓存命中，与 Chat Completions 一致。
    static func usage(_ object: [String: JSONValue]) -> TokenUsage? {
        guard let input = object["input_tokens"]?.numberValue.map({ Int($0) }),
              let output = object["output_tokens"]?.numberValue.map({ Int($0) })
        else {
            return nil
        }
        let cached = object["input_tokens_details"]?.objectValue?["cached_tokens"]?
            .numberValue.map { Int($0) }

        return TokenUsage(
            uncachedInputTokens: max(0, input - (cached ?? 0)),
            outputTokens: output,
            totalTokens: object["total_tokens"]?.numberValue.map { Int($0) },
            cacheReadTokens: cached,
            reasoningTokens: object["output_tokens_details"]?.objectValue?["reasoning_tokens"]?
                .numberValue.map { Int($0) }
        )
    }
}
