import Foundation

/// 一次模型调用的 token 记账。
///
/// 计数**互斥**：`uncachedInputTokens` 只含未命中缓存的输入；缓存读/写单独计。
/// 计价输入 = 三者之和，见 `billedInputTokens`。
public struct TokenUsage: Codable, Sendable, Equatable {
    public var uncachedInputTokens: Int
    public var outputTokens: Int
    /// 厂商给出的完整总数；不可得时省略，不臆造。
    public var totalTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?

    public init(
        uncachedInputTokens: Int,
        outputTokens: Int,
        totalTokens: Int? = nil,
        cacheReadTokens: Int? = nil,
        cacheWriteTokens: Int? = nil,
        reasoningTokens: Int? = nil
    ) {
        self.uncachedInputTokens = uncachedInputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.reasoningTokens = reasoningTokens
    }

    /// 计价输入 = 未缓存输入 + 缓存读 + 缓存写。
    public var billedInputTokens: Int {
        uncachedInputTokens + (cacheReadTokens ?? 0) + (cacheWriteTokens ?? 0)
    }

    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            uncachedInputTokens: lhs.uncachedInputTokens + rhs.uncachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            totalTokens: Optional.combine(lhs.totalTokens, rhs.totalTokens, +),
            cacheReadTokens: Optional.combine(lhs.cacheReadTokens, rhs.cacheReadTokens, +),
            cacheWriteTokens: Optional.combine(lhs.cacheWriteTokens, rhs.cacheWriteTokens, +),
            reasoningTokens: Optional.combine(lhs.reasoningTokens, rhs.reasoningTokens, +)
        )
    }
}

extension Optional where Wrapped == Int {
    /// 两侧都有值才相加；任一缺失则整体缺失，避免把"未知"算成 0。
    static func combine(_ lhs: Int?, _ rhs: Int?, _ op: (Int, Int) -> Int) -> Int? {
        guard let lhs, let rhs else { return nil }
        return op(lhs, rhs)
    }
}
