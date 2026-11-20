import Foundation

public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case system
    case user
    case assistant
    case context
}

/// 适配器私有、但值得留存的少量元数据。不进内容块。
public struct ProviderMeta: Codable, Sendable, Equatable {
    /// 上游响应 id，用于排查与幂等重试。
    public var responseId: String?
    /// 厂商自己的结束原因原文，仅供诊断。
    public var nativeStopReason: String?

    public init(responseId: String? = nil, nativeStopReason: String? = nil) {
        self.responseId = responseId
        self.nativeStopReason = nativeStopReason
    }
}

/// 一条目录项。skill 目录用它广播给模型。
public struct SkillEntry: Codable, Sendable, Equatable {
    public var name: String
    public var description: String

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

/// 谁生产了这条消息。生产者与"是什么形态"解耦。
public enum MessageSource: Codable, Sendable, Equatable {
    case user
    case model(provider: String, model: String, meta: ProviderMeta?)
    case systemPrompt
    case webEvidence(query: String)
    case skillCatalog(entries: [SkillEntry])
    case skillInvocation(name: String)
    case compactionSummary(compactionID: UUID)
}

/// 压缩时可否丢弃正文。
public enum Retention: String, Codable, Sendable {
    /// 用户输入、助手回答、压缩摘要——永不静默丢弃。
    case durable
    /// 检索证据、skill 正文与目录——压缩时可丢，只留一行记录。
    case ephemeral
}

public struct Message: Codable, Sendable, Identifiable, Equatable {
    public var id: MessageID
    public var role: MessageRole
    public var blocks: [ContentBlock]
    public var source: MessageSource
    public var retention: Retention
    public var createdAt: Date

    public init(
        id: MessageID = UUID(),
        role: MessageRole,
        blocks: [ContentBlock],
        source: MessageSource,
        retention: Retention = .durable,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.source = source
        self.retention = retention
        self.createdAt = createdAt
    }

    /// 拼接全部可见文本。reasoning 不计入。
    public var visibleText: String {
        blocks
            .filter { if case .reasoning = $0 { return false } else { return true } }
            .map(\.plainText)
            .joined()
    }

    public var hasImage: Bool {
        blocks.contains { if case .image = $0 { return true } else { return false } }
    }
}
