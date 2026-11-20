import CoreKit
import Foundation

/// Anthropic Messages API 的请求体构造。
///
/// 与 OpenAI 系的三处硬差异：
/// 1. `max_tokens` **必填**（这里用 profile 默认值兜底）。
/// 2. `system` 是顶层字段，不是一条 message。
/// 3. `content` 必须是 blocks 数组，纯文本也要写成 `[{"type":"text",...}]`。
public struct AnthropicRequestBuilder: Sendable {
    public let profile: ProviderProfile

    public init(profile: ProviderProfile) {
        self.profile = profile
    }

    public func body(
        _ options: GenerateOptions,
        image: (ImageAttachmentRef) -> (mediaType: String, base64: String)? = { _ in nil }
    ) -> JSONValue {
        var root: [String: JSONValue] = [:]
        root["model"] = .string(options.model)
        root["max_tokens"] = .number(Double(options.maxTokens ?? profile.capabilities.defaultMaxTokens ?? 4096))
        root["stream"] = .bool(options.stream)

        if let system = options.system, !system.isEmpty {
            root["system"] = .string(system)
        }

        var messages: [JSONValue] = []
        for message in options.messages where message.role != .system {
            if let wire = wire(message, image: image) {
                messages.append(wire)
            }
        }
        root["messages"] = .array(messages)

        if let temperature = options.temperature {
            root["temperature"] = .number(temperature)
        }
        if let stop = options.stop, !stop.isEmpty {
            root["stop_sequences"] = .array(stop.map { .string($0) })
        }
        for (key, value) in options.extras {
            root[key] = value
        }
        return .object(root)
    }

    /// Anthropic 拒绝空 content 数组，因此没有可用块的 message 直接不发送。
    private func wire(
        _ message: Message,
        image: (ImageAttachmentRef) -> (mediaType: String, base64: String)?
    ) -> JSONValue? {
        let role = message.role == .assistant ? "assistant" : "user"
        var blocks: [JSONValue] = []

        for block in message.blocks {
            switch block {
            case let .text(text):
                if !text.isEmpty {
                    blocks.append(.object([
                        "type": .string("text"),
                        "text": .string(text)
                    ]))
                }
            case let .image(ref):
                if let payload = image(ref) {
                    blocks.append(.object([
                        "type": .string("image"),
                        "source": .object([
                            "type": .string("base64"),
                            "media_type": .string(payload.mediaType),
                            "data": .string(payload.base64)
                        ])
                    ]))
                }
            case let .context(evidence):
                blocks.append(.object([
                    "type": .string("text"),
                    "text": .string(ContextRendering.render(evidence))
                ]))
            case .reasoning, .citation:
                continue
            }
        }

        guard !blocks.isEmpty else { return nil }
        return .object([
            "role": .string(role),
            "content": .array(blocks)
        ])
    }
}
