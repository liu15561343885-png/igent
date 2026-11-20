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
    /// 模型上下文窗口。用于自动压缩的阈值判断；nil 表示未知（按 128k 处理）。
    public var contextWindow: Int?

    public init(
        vision: Bool = false,
        imageOut: Bool = false,
        nativeSearch: Bool = false,
        reasoning: Bool = false,
        streamUsage: Bool = true,
        usesMaxCompletionTokens: Bool = false,
        systemStyle: SystemStyle = .message,
        defaultMaxTokens: Int? = nil,
        contextWindow: Int? = nil
    ) {
        self.vision = vision
        self.imageOut = imageOut
        self.nativeSearch = nativeSearch
        self.reasoning = reasoning
        self.streamUsage = streamUsage
        self.usesMaxCompletionTokens = usesMaxCompletionTokens
        self.systemStyle = systemStyle
        self.defaultMaxTokens = defaultMaxTokens
        self.contextWindow = contextWindow
    }
}

/// 一条厂商路由的完整描述。UI 里"新增厂商"产出的就是这个结构。
public struct ProviderProfile: Sendable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var family: ProviderFamily
    public var baseURL: URL
    /// 相对 `baseURL` 的对话路径，例如 `/chat/completions`。
    public var chatPath: String
    public var capabilities: Capabilities
    public var auth: AuthStyle
    public var extraHeaders: [String: String]

    public init(
        id: String,
        name: String,
        family: ProviderFamily,
        baseURL: URL,
        chatPath: String,
        capabilities: Capabilities = Capabilities(),
        auth: AuthStyle = .bearer,
        extraHeaders: [String: String] = [:]
    ) {
        self.id = id
        self.name = name
        self.family = family
        self.baseURL = baseURL
        self.chatPath = chatPath
        self.capabilities = capabilities
        self.auth = auth
        self.extraHeaders = extraHeaders
    }

    /// 拼出实际请求地址。`chatPath` 支持两个占位：
    /// - `{model}`：把模型名嵌进路径（Gemini、Azure 部署名）
    /// - `?query`：路径后附带的查询串（Gemini 的 `alt=sse`、Azure 的 `api-version`）
    ///
    /// 不能用 `URL(string:relativeTo:)`：`chatPath` 以 "/" 开头时它会按主机根解析，
    /// 把 baseURL 里的路径前缀（如 `/v1`、`/openai/deployments/x`）整个丢掉。
    public func chatURL(for model: String) -> URL? {
        url(forPath: chatPath.replacingOccurrences(of: "{model}", with: model))
    }

    /// 把任意相对路径拼到 baseURL 上。路径前缀（`/v1`、`/openai/deployments/x`）必须保留。
    public func url(forPath path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }

        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var suffix = String(pieces[0])
        if !suffix.hasPrefix("/") { suffix = "/" + suffix }

        components.path = basePath + suffix
        if pieces.count > 1 {
            components.query = String(pieces[1])
        }
        return components.url
    }

    public var chatURL: URL? { chatURL(for: "") }

    /// 上下文窗口；厂商没声明时按 128k 估。
    public var contextWindow: Int { capabilities.contextWindow ?? 128_000 }
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

    static func openAIResponses(baseURL: String = "https://api.openai.com/v1") -> ProviderProfile {
        ProviderProfile(
            id: "openai-responses",
            name: "OpenAI Responses",
            family: .openAIResponses,
            baseURL: URL(string: baseURL)!,
            chatPath: "/responses",
            capabilities: Capabilities(
                vision: true, reasoning: true, streamUsage: true,
                systemStyle: .topLevel, contextWindow: 200_000
            )
        )
    }

    /// Gemini 把模型名放在路径里，并用 `alt=sse` 打开流式。
    static func gemini(baseURL: String = "https://generativelanguage.googleapis.com/v1beta") -> ProviderProfile {
        ProviderProfile(
            id: "gemini",
            name: "Google Gemini",
            family: .gemini,
            baseURL: URL(string: baseURL)!,
            chatPath: "/models/{model}:streamGenerateContent?alt=sse",
            capabilities: Capabilities(
                vision: true,
                reasoning: true,
                streamUsage: true,
                systemStyle: .systemInstruction,
                defaultMaxTokens: 8192,
                contextWindow: 1_048_576
            ),
            auth: .apiKey(header: "x-goog-api-key")
        )
    }

    /// Azure 的报文与 OpenAI Chat Completions **完全同构**，差异只有三处：
    /// 部署名进路径、`api-version` 进查询串、鉴权走 `api-key` 头。
    /// 因此它是配置而不是新适配器。
    static func azure(
        resource: String,
        deployment: String,
        apiVersion: String = "2024-10-21"
    ) -> ProviderProfile {
        ProviderProfile(
            id: "azure-\(deployment)",
            name: "Azure \(deployment)",
            family: .openAICompatible,
            baseURL: URL(string: "https://\(resource).openai.azure.com")!,
            chatPath: "/openai/deployments/\(deployment)/chat/completions?api-version=\(apiVersion)",
            capabilities: Capabilities(vision: true, streamUsage: true),
            auth: .apiKey(header: "api-key")
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
            ),
            auth: .apiKey(header: "x-api-key")
        )
    }
}
