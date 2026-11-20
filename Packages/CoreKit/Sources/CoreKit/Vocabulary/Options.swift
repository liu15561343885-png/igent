import Foundation

public enum ReasoningEffort: String, Codable, Sendable, CaseIterable {
    case minimal
    case low
    case medium
    case high
}

/// 辅助调用的用途分类。适配器可据此路由到便宜模型，计量也分开统计。
public enum CallPurpose: String, Codable, Sendable, CaseIterable {
    /// 上下文压缩摘要。
    case compaction
    /// 会话标题生成。
    case sessionTitle
    /// 检索前的查询改写。
    case queryRewrite
    /// skill 自动路由。
    case skillRoute
}

/// 一次模型请求。厂商中立的完整入参。
public struct GenerateOptions: Sendable {
    public var provider: String
    public var model: String
    public var messages: [Message]
    /// 系统提示。适配器按 route 的 `systemStyle` 决定放到消息里还是顶层字段。
    public var system: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var stop: [String]?
    public var reasoning: ReasoningEffort?
    public var purpose: CallPurpose?
    /// 厂商私有参数逃生口，原样合并进请求体。
    public var extras: [String: JSONValue]

    public init(
        provider: String,
        model: String,
        messages: [Message],
        system: String? = nil,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stop: [String]? = nil,
        reasoning: ReasoningEffort? = nil,
        purpose: CallPurpose? = nil,
        extras: [String: JSONValue] = [:]
    ) {
        self.provider = provider
        self.model = model
        self.messages = messages
        self.system = system
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stop = stop
        self.reasoning = reasoning
        self.purpose = purpose
        self.extras = extras
    }
}
