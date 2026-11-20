import CoreKit
import Foundation

/// OpenAI Chat Completions 系的请求体构造。
///
/// 覆盖：OpenAI 官方、DeepSeek、Moonshot、智谱、通义兼容模式、Groq、
/// OpenRouter、SiliconFlow、vLLM 等一切说法相同的端点。
public struct OpenAIRequestBuilder: Sendable {
    public let profile: ProviderProfile

    public init(profile: ProviderProfile) {
        self.profile = profile
    }

    /// - Parameter imageURL: 把图片引用译成 `data:` URL；返回 nil 表示这张图发不出去（能力不支持）。
    public func body(
        _ options: GenerateOptions,
        imageURL: (ImageAttachmentRef) -> String? = { _ in nil }
    ) -> JSONValue {
        var root: [String: JSONValue] = [:]
        root["model"] = .string(options.model)

        if options.stream {
            root["stream"] = .bool(true)
            if profile.capabilities.streamUsage {
                root["stream_options"] = .object(["include_usage": .bool(true)])
            }
        }

        var messages: [JSONValue] = []
        if let system = options.system, !system.isEmpty {
            messages.append(.object([
                "role": .string("system"),
                "content": .string(system)
            ]))
        }
        for message in options.messages {
            messages.append(wire(message, imageURL: imageURL))
        }
        root["messages"] = .array(messages)

        if let temperature = options.temperature {
            root["temperature"] = .number(temperature)
        }
        if let maxTokens = options.maxTokens {
            let field = profile.capabilities.usesMaxCompletionTokens
                ? "max_completion_tokens"
                : "max_tokens"
            root[field] = .number(Double(maxTokens))
        }
        if let stop = options.stop, !stop.isEmpty {
            root["stop"] = .array(stop.map { .string($0) })
        }
        for (key, value) in options.extras {
            root[key] = value
        }
        return .object(root)
    }

    private func wire(
        _ message: Message,
        imageURL: (ImageAttachmentRef) -> String?
    ) -> JSONValue {
        let role: String
        switch message.role {
        case .user, .context: role = "user"
        case .assistant: role = "assistant"
        case .system: role = "system"
        }

        let hasStructured = message.blocks.contains { block in
            switch block {
            case .image, .context: true
            default: false
            }
        }

        // 纯文本走字符串，报文最简单，也最不容易被兼容端点拒绝。
        if !hasStructured {
            let text = message.blocks.compactMap { block -> String? in
                if case let .text(value) = block { value } else { nil }
            }.joined()
            return .object([
                "role": .string(role),
                "content": .string(text)
            ])
        }

        var parts: [JSONValue] = []
        for block in message.blocks {
            switch block {
            case let .text(text):
                if !text.isEmpty {
                    parts.append(.object([
                        "type": .string("text"),
                        "text": .string(text)
                    ]))
                }
            case .reasoning:
                // 思维链不回灌历史：多数厂商会拒绝，少数会重复计费。
                continue
            case let .image(ref):
                if let url = imageURL(ref) {
                    parts.append(.object([
                        "type": .string("image_url"),
                        "image_url": .object(["url": .string(url)])
                    ]))
                }
            case let .context(evidence):
                parts.append(.object([
                    "type": .string("text"),
                    "text": .string(render(evidence))
                ]))
            case .citation:
                continue
            }
        }
        return .object([
            "role": .string(role),
            "content": .array(parts)
        ])
    }

    private func render(_ evidence: ContextEvidence) -> String {
        ContextRendering.render(evidence)
    }
}
