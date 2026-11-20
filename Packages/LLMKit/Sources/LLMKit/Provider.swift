import CoreKit
import Foundation

/// 协议族。适配器按族实现，厂商差异用 `ProviderProfile` 描述。
public enum ProviderFamily: String, Codable, Sendable, CaseIterable {
    case openAICompatible = "openai-compatible"
    case openAIResponses = "openai-responses"
    case anthropic
    case gemini
}

/// 系统提示放在哪里。同样是"OpenAI 兼容"，不同厂商也不一致。
public enum SystemStyle: String, Codable, Sendable {
    /// messages[0] role=system
    case message
    /// 顶层 system 字段（Anthropic）
    case topLevel
    /// systemInstruction.parts（Gemini）
    case systemInstruction
}

public struct Capabilities: Codable, Sendable, Equatable, Hashable {
    public var vision: Bool
    public var imageOut: Bool
    public var nativeSearch: Bool
    public var reasoning: Bool
    /// 流式是否回传 usage（OpenAI 需 `stream_options.include_usage`）。
    public var streamUsage: Bool
    /// 新模型用 `max_completion_tokens`，老模型用 `max_tokens`。
    public var usesMaxCompletionTokens: Bool
    public var systemStyle: SystemStyle
    /// 请求未指定输出上限时的默认值（Anthropic 的 `max_tokens` 必填）。
    public var defaultMaxTokens: Int?

    public init(
        vision: Bool = false,
        imageOut: Bool = false,
        nativeSearch: Bool = false,
        reasoning: Bool = false,
        streamUsage: Bool = true,
        usesMaxCompletionTokens: Bool = false,
        systemStyle: SystemStyle = .message,
        defaultMaxTokens: Int? = nil
    ) {
        self.vision = vision
        self.imageOut = imageOut
        self.nativeSearch = nativeSearch
        self.reasoning = reasoning
        self.streamUsage = streamUsage
        self.usesMaxCompletionTokens = usesMaxCompletionTokens
        self.systemStyle = systemStyle
        self.defaultMaxTokens = defaultMaxTokens
    }
}

/// 一条厂商路由的完整描述。UI 里"新增厂商"产出的就是这个结构。
public struct ProviderProfile: Sendable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var family: ProviderFamily
    public var baseURL: URL
    /// 相对 `baseURL` 的对话路径，例如 `/chat/completions`。
    public var chatPath: String
    public var capabilities: Capabilities
    public var extraHeaders: [String: String]

    public init(
        id: String,
        name: String,
        family: ProviderFamily,
        baseURL: URL,
        chatPath: String,
        capabilities: Capabilities = Capabilities(),
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.baseURL = baseURL
        self.chatPath = chatPath
        self.capabilities = capabilities
        self.extraHeaders = extraHeaders
    }

    /// 拼出实际请求地址。
    ///
    /// 不能用 `URL(string:relativeTo:)`：`chatPath` 以 "/" 开头时它会按主机根解析，
    /// 把 baseURL 里的路径前缀（如 `/v1`、`/openai/deployments/x`）整个丢掉。
    public var chatURL: URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        let suffix = chatPath.hasPrefix("/") ? chatPath : "/" + chatPath
        components.path = basePath + suffix
        return components.url
    }
}

public extension ProviderProfile {
    static func openAICompatible(
        id: String,
        name: String,
        baseURL: String,
        capabilities: Capabilities = Capabilities()
    ) -> ProviderProfile {
        ProviderProfile(
            id: id,
            name: name,
            family: .openAICompatible,
            baseURL: URL(string: baseURL)!,
            chatPath: "/chat/completions",
            capabilities: capabilities
        )
    }

    static func anthropic(baseURL: String = "https://api.anthropic.com/v1") -> ProviderProfile {
        ProviderProfile(
            id: "anthropic",
            name: "Anthropic",
            family: .anthropic,
            baseURL: URL(string: baseURL)!,
            chatPath: "/messages",
            capabilities: Capabilities(
                vision: true,
                reasoning: true,
                streamUsage: true,
                systemStyle: .topLevel,
                defaultMaxTokens: 4096
            )
        )
    }
}
