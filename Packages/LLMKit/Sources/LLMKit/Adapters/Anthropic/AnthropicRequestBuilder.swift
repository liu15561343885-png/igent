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

        // Anthropic 要求 user/assistant 严格交替，连续同角色会被 400 拒绝。
        // 压缩后的摘要（context → user）后面紧跟用户原话时就会出现这种情况，
        // 所以这里把相邻同角色的内容合并成一条。
        var messages: [JSONValue] = []
        var pendingRole: String?
        var pendingBlocks: [JSONValue] = []

        func flush() {
            guard let role = pendingRole, !pendingBlocks.isEmpty else { return }
            messages.append(.object([
                "role": .string(role),
                "content": .array(pendingBlocks)
            ]))
            pendingRole = nil
            pendingBlocks = []
        }

        for message in options.messages where message.role != .system {
            guard let (role, blocks) = wire(message, image: image), !blocks.isEmpty else { continue }
            if role == pendingRole {
                pendingBlocks.append(contentsOf: blocks)
            } else {
                flush()
                pendingRole = role
                pendingBlocks = blocks
            }
        }
        flush()

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
    /// 返回角色与内容块。Anthropic 拒绝空 content 数组，所以没有可用块时返回 nil。
    private func wire(
        _ message: Message,
        image: (ImageAttachmentRef) -> (mediaType: String, base64: String)?
    ) -> (role: String, blocks: [JSONValue])? {
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
        return (role, blocks)
    }
}
