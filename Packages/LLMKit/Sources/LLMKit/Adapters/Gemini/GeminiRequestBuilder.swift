import CoreKit
import Foundation

/// Gemini `generateContent` 的请求体构造。
///
/// 与 OpenAI 系的差异：
/// 1. 角色是 `user` / `model`（不是 `assistant`）。
/// 2. 系统提示走 `systemInstruction.parts`。
/// 3. 内容按 `contents[].parts[]` 组织，图片用 `inlineData`。
public struct GeminiRequestBuilder: Sendable {
    public let profile: ProviderProfile

    public init(profile: ProviderProfile) {
        self.profile = profile
    }

    public func body(
        _ options: GenerateOptions,
        image: (ImageAttachmentRef) -> (mimeType: String, base64: String)? = { _ in nil }
    ) -> JSONValue {
        var root: [String: JSONValue] = [:]

        if let system = options.system, !system.isEmpty {
            root["systemInstruction"] = .object([
                "parts": .array([.object(["text": .string(system)])])
            ])
        }

        // Gemini 要求 user/model 严格交替：连续同角色会被 400 拒绝
        // （"Please ensure that multiturn requests alternate"）。
        // 这里与 Anthropic 一样合并相邻同角色，并补掉开头是 model 的情况。
        var contents: [JSONValue] = []
        var pendingRole: String?
        var pendingParts: [JSONValue] = []

        func flush() {
            guard let role = pendingRole, !pendingParts.isEmpty else { return }
            contents.append(.object([
                "role": .string(role),
                "parts": .array(pendingParts)
            ]))
            pendingRole = nil
            pendingParts = []
        }

        for message in options.messages where message.role != .system {
            guard let wire = wire(message, image: image),
                  let role = wire.objectValue?["role"]?.stringValue,
                  let parts = wire.objectValue?["parts"]?.arrayValue,
                  !parts.isEmpty
            else { continue }

            if role == pendingRole {
                pendingParts.append(contentsOf: parts)
            } else {
                flush()
                pendingRole = role
                pendingParts = parts
            }
        }
        flush()

        // 首条若是 model，补一条 user，否则同样是 400。
        if contents.first?.objectValue?["role"] == .string("model") {
            contents.insert(
                .object(["role": .string("user"), "parts": .array([.object(["text": .string("（继续）")])])]),
                at: 0
            )
        }
        root["contents"] = .array(contents)

        var config: [String: JSONValue] = [:]
        if let temperature = options.temperature {
            config["temperature"] = .number(temperature)
        }
        if let maxTokens = options.maxTokens ?? profile.capabilities.defaultMaxTokens {
            config["maxOutputTokens"] = .number(Double(maxTokens))
        }
        if let stop = options.stop, !stop.isEmpty {
            config["stopSequences"] = .array(stop.map { .string($0) })
        }
        if !config.isEmpty {
            root["generationConfig"] = .object(config)
        }

        for (key, value) in options.extras {
            root[key] = value
        }
        return .object(root)
    }

    private func wire(
        _ message: Message,
        image: (ImageAttachmentRef) -> (mimeType: String, base64: String)?
    ) -> JSONValue? {
        // Gemini 只认 user 与 model 两个角色；context 归入 user。
        let role = message.role == .assistant ? "model" : "user"
        var parts: [JSONValue] = []

        for block in message.blocks {
            switch block {
            case let .text(text):
                if !text.isEmpty {
                    parts.append(.object(["text": .string(text)]))
                }
            case let .image(ref):
                if let payload = image(ref) {
                    parts.append(.object([
                        "inlineData": .object([
                            "mimeType": .string(payload.mimeType),
                            "data": .string(payload.base64)
                        ])
                    ]))
                }
            case let .context(evidence):
                parts.append(.object(["text": .string(ContextRendering.render(evidence))]))
            case let .document(document):
                parts.append(.object(["text": .string(document.promptText)]))
            case .reasoning, .citation:
                // 思维链不回灌：Gemini 的 thought 部分带签名，自行拼接会破坏校验。
                continue
            case .providerBlock:
                // 厂商私有块只在同一厂商间回传，跨厂商时丢弃。
                continue
            }
        }

        guard !parts.isEmpty else { return nil }
        return .object([
            "role": .string(role),
            "parts": .array(parts)
        ])
    }
}
