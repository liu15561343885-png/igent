import CoreKit
import Foundation

/// Anthropic Messages 的流式帧解析。
///
/// Anthropic 用**命名事件**而不是单一线格式：`message_start` / `content_block_start` /
/// `content_block_delta` / `content_block_stop` / `message_delta` / `message_stop`。
/// 每块内容由客户端自行累积，因此这里会发 `blockEnd` 带上完整块。
public struct AnthropicStreamParser: Sendable {
    private var decoder = SSEDecoder()
    private var text: [Int: String] = [:]
    private var kinds: [Int: BlockType] = [:]
    private var currentBlock: Int?

    private var messageId: String?
    private var uncachedInputTokens = 0
    private var outputTokens: Int?
    private var cacheReadTokens: Int?
    private var cacheWriteTokens: Int?
    private var nativeStopReason: String?
    private var citationCounter = 0
    private var finishReason: FinishReason?
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

    // MARK: - 帧处理

    private mutating func handle(_ event: SSEEvent) -> [StreamChunk] {
        guard let name = event.event,
              let data = event.data.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else {
            return []
        }

        switch name {
        case "message_start":
            return handleMessageStart(object)
        case "content_block_start":
            return handleBlockStart(object)
        case "content_block_delta":
            return handleDelta(object)
        case "content_block_stop":
            return handleBlockStop(object)
        case "message_delta":
            return handleMessageDelta(object)
        case "message_stop":
            return terminal()
        case "error":
            return handleError(object)
        default:
            // ping 与其他保活事件。
            return []
        }
    }

    private mutating func handleMessageStart(_ object: [String: JSONValue]) -> [StreamChunk] {
        guard let message = object["message"]?.objectValue else { return [] }
        messageId = message["id"]?.stringValue
        if let usage = message["usage"]?.objectValue {
            // Anthropic 的 input_tokens **不含**缓存部分，本身即互斥计数。
            uncachedInputTokens = usage["input_tokens"]?.numberValue.map { Int($0) } ?? 0
            cacheReadTokens = usage["cache_read_input_tokens"]?.numberValue.map { Int($0) }
            cacheWriteTokens = usage["cache_creation_input_tokens"]?.numberValue.map { Int($0) }
        }
        return []
    }

    private mutating func handleBlockStart(_ object: [String: JSONValue]) -> [StreamChunk] {
        guard let index = object["index"]?.numberValue.map({ Int($0) }),
              let block = object["content_block"]?.objectValue,
              let rawType = block["type"]?.stringValue
        else {
            return []
        }
        let kind: BlockType
        switch rawType {
        case "thinking": kind = .reasoning
        case "text": kind = .text
        case "server_tool_use", "web_search_tool_result", "web_fetch_tool_result":
            // 服务端工具的调用与结果**一次性**到达（不增量），所以当帧就闭合。
            // 原样保留整块：多轮回传时必须一字不改，否则签名的页面会丢失。
            return [
                .blockStart(index: index, type: .provider),
                .blockEnd(index: index, block: .providerBlock(ProviderBlock(type: rawType, payload: .object(block))))
            ]
        default:
            // redacted_thinking 等未知块：记录但不产出内容。
            return []
        }
        kinds[index] = kind
        text[index] = ""
        currentBlock = index
        return [.blockStart(index: index, type: kind)]
    }

    private mutating func handleDelta(_ object: [String: JSONValue]) -> [StreamChunk] {
        guard let index = object["index"]?.numberValue.map({ Int($0) }),
              let delta = object["delta"]?.objectValue,
              let type = delta["type"]?.stringValue
        else {
            return []
        }

        switch type {
        case "text_delta":
            guard let value = delta["text"]?.stringValue, !value.isEmpty else { return [] }
            text[index, default: ""] += value
            return [.textDelta(index: index, text: value)]
        case "thinking_delta":
            guard let value = delta["thinking"]?.stringValue, !value.isEmpty else { return [] }
            text[index, default: ""] += value
            return [.reasoningDelta(index: index, text: value)]
        case "citations_delta":
            // 引用挂在当前文本块上。我们把它单独成一个块，UI 才能渲染来源卡。
            guard let citation = delta["citation"]?.objectValue,
                  let urlString = citation["url"]?.stringValue,
                  let url = URL(string: urlString)
            else { return [] }
            citationCounter += 1
            let index = 900 + citationCounter
            return [
                .blockStart(index: index, type: .citation),
                .blockEnd(index: index, block: .citation(
                    Citation(
                        index: citationCounter,
                        url: url,
                        title: citation["title"]?.stringValue
                    )
                ))
            ]

        case "signature_delta", "input_json_delta":
            // 签名与工具参数：前者无需展示，后者不声明工具时不会出现。
            return []
        default:
            return []
        }
    }

    private mutating func handleBlockStop(_ object: [String: JSONValue]) -> [StreamChunk] {
        guard let index = object["index"]?.numberValue.map({ Int($0) }),
              let kind = kinds[index]
        else {
            return []
        }
        let accumulated = text[index] ?? ""
        currentBlock = nil
        switch kind {
        case .text:
            return [.blockEnd(index: index, block: .text(accumulated))]
        case .reasoning:
            return [.blockEnd(index: index, block: .reasoning(accumulated))]
        default:
            return []
        }
    }

    private mutating func handleMessageDelta(_ object: [String: JSONValue]) -> [StreamChunk] {
        if let delta = object["delta"]?.objectValue, let raw = delta["stop_reason"]?.stringValue {
            nativeStopReason = raw
            finishReason = Self.map(raw)
        }
        if let usage = object["usage"]?.objectValue,
           let output = usage["output_tokens"]?.numberValue.map({ Int($0) }) {
            outputTokens = output
        }
        return []
    }

    private mutating func handleError(_ object: [String: JSONValue]) -> [StreamChunk] {
        let error = object["error"]?.objectValue
        let failure = LlmFailure(
            message: error?["message"]?.stringValue ?? "provider error",
            code: error?["type"]?.stringValue == "rate_limit_error" ? .rateLimit : .server
        )
        didFinish = true
        return [.finish(.error(failure), meta: meta())]
    }

    private mutating func terminal() -> [StreamChunk] {
        guard !didFinish else { return [] }
        didFinish = true
        var chunks: [StreamChunk] = []
        if let usage = usage() {
            chunks.append(.usage(usage))
        }
        chunks.append(.finish(finishReason ?? .stop, meta: meta()))
        return chunks
    }

    private func usage() -> TokenUsage? {
        guard uncachedInputTokens > 0 || outputTokens != nil else { return nil }
        return TokenUsage(
            uncachedInputTokens: uncachedInputTokens,
            outputTokens: outputTokens ?? 0,
            totalTokens: nil,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens
        )
    }

    private func meta() -> ProviderMeta? {
        guard messageId != nil || nativeStopReason != nil else { return nil }
        return ProviderMeta(responseId: messageId, nativeStopReason: nativeStopReason)
    }

    static func map(_ raw: String) -> FinishReason {
        switch raw {
        case "end_turn", "stop_sequence", "pause_turn": .stop
        case "max_tokens": .maxTokens
        case "refusal": .contentFilter(nil)
        default: .stop
        }
    }
}
