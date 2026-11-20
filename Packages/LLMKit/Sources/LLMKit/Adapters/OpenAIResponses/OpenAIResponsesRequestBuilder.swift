import CoreKit
import Foundation

/// OpenAI Responses API 的请求体构造。
///
/// 与 Chat Completions 的三处差异：
/// 1. 系统提示是顶层 `instructions`。
/// 2. 历史放进 `input` 数组（不是 `messages`）。
/// 3. 输出上限叫 `max_output_tokens`。
public struct OpenAIResponsesRequestBuilder: Sendable {
    public let profile: ProviderProfile

    public init(profile: ProviderProfile) {
        self.profile = profile
    }

    public func body(
        _ options: GenerateOptions,
        imageURL: (ImageAttachmentRef) -> String? = { _ in nil }
    ) -> JSONValue {
        var root: [String: JSONValue] = [:]
        root["model"] = .string(options.model)

        if let system = options.system, !system.isEmpty {
            root["instructions"] = .string(system)
        }

        var input: [JSONValue] = []
        for message in options.messages where message.role != .system {
            if let item = wire(message, imageURL: imageURL) {
                input.append(item)
            }
        }
        root["input"] = .array(input)

        if options.stream {
            root["stream"] = .bool(true)
        }
        if let temperature = options.temperature {
            root["temperature"] = .number(temperature)
        }
        if let maxTokens = options.maxTokens {
            root["max_output_tokens"] = .number(Double(maxTokens))
        }
        for (key, value) in options.extras {
            root[key] = value
        }
        return .object(root)
    }

    private func wire(
        _ message: Message,
        imageURL: (ImageAttachmentRef) -> String?
    ) -> JSONValue? {
        let role = message.role == .assistant ? "assistant" : "user"

        var parts: [JSONValue] = []
        var hasImage = false
        for block in message.blocks {
            switch block {
            case let .text(text):
                if !text.isEmpty {
                    parts.append(.object([
                        "type": .string(role == "assistant" ? "output_text" : "input_text"),
                        "text": .string(text)
                    ]))
                }
            case let .image(ref):
                if let url = imageURL(ref) {
                    hasImage = true
                    parts.append(.object([
                        "type": .string("input_image"),
                        "image_url": .string(url)
                    ]))
                }
            case let .context(evidence):
                parts.append(.object([
                    "type": .string("input_text"),
                    "text": .string(ContextRendering.render(evidence))
                ]))
            case let .document(document):
                parts.append(.object([
                    "type": .string("input_text"),
                    "text": .string(document.promptText)
                ]))
            case .reasoning, .citation:
                continue
            case .providerBlock:
                // 厂商私有块只在同一厂商间回传，跨厂商时丢弃。
                continue
            }
        }

        guard !parts.isEmpty else { return nil }

        // 纯文本用字符串形式，报文最简单；带图必须用内容数组。
        if !hasImage, parts.count == 1, let text = parts[0].objectValue?["text"] {
            return .object([
                "role": .string(role),
                "content": text
            ])
        }
        return .object([
            "role": .string(role),
            "content": .array(parts)
        ])
    }
}
