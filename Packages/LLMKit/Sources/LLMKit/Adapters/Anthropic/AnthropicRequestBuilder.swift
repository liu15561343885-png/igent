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

        if !options.serverTools.isEmpty {
            root["tools"] = .array(options.serverTools.map { tool in
                .object([
                    "type": .string(tool.wireType),
                    "name": .string(tool.name)
                ])
            })
        }
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
        // Anthropic 的思考必须给预算，且要小于 max_tokens。
        if let effort = options.reasoning, profile.capabilities.reasoning {
            let ceiling = (options.maxTokens ?? profile.capabilities.defaultMaxTokens ?? 4096) - 512
            let budget = max(1024, min(Self.thinkingBudget(effort), max(1024, ceiling)))
            root["thinking"] = .object([
                "type": .string("enabled"),
                "budget_tokens": .number(Double(budget))
            ])
        }

        for (key, value) in options.extras {
            root[key] = value
        }
        return .object(root)
    }

    /// Anthropic 拒绝空 content 数组，因此没有可用块的 message 直接不发送。
    /// 推理强度 → 思考预算（token）。
    static func thinkingBudget(_ effort: ReasoningEffort) -> Int {
        switch effort {
        case .minimal: 1024
        case .low: 2048
        case .medium: 4096
        case .high: 8192
        }
    }

    /// 允许原样回传给厂商的块类型。其余类型的 providerBlock 只用于界面展示。
    static let replayableBlockTypes: Set<String> = [
        "server_tool_use", "web_search_tool_result", "web_fetch_tool_result"
    ]

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
            case let .providerBlock(block):
                // 只回传厂商真正认得的三种块；其余（如仅用于展示的 research_step）
                // 发出去会被当成未知类型拒绝。
                guard Self.replayableBlockTypes.contains(block.type) else { continue }
                // 原样回传：DeepSeek 把网页正文加密在 signature 里，
                // 改动或丢弃都会让"上一轮读过的那一页"从上下文里消失。
                blocks.append(block.payload)
            case let .document(document):
                blocks.append(.object([
                    "type": .string("text"),
                    "text": .string(document.promptText)
                ]))
            case .reasoning, .citation:
                continue
            }
        }

        guard !blocks.isEmpty else { return nil }
        return (role, blocks)
    }
}
