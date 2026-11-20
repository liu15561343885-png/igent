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

    /// 累加两笔用量。
    ///
    /// 可选字段的语义要分开处理：
    /// - 缓存读/写、推理 token 是"可缺省的计数"——多数厂商根本不报。只要有一方报了，
    ///   另一方按 0 计；**双方都缺**才保持未知。否则一笔没报缓存就会毁掉整段总额。
    /// - `totalTokens` 是厂商自己给的总数，缺失就是真未知，不做推算。
    public static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            uncachedInputTokens: lhs.uncachedInputTokens + rhs.uncachedInputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            totalTokens: Optional.combine(lhs.totalTokens, rhs.totalTokens, +),
            cacheReadTokens: sum(lhs.cacheReadTokens, rhs.cacheReadTokens),
            cacheWriteTokens: sum(lhs.cacheWriteTokens, rhs.cacheWriteTokens),
            reasoningTokens: sum(lhs.reasoningTokens, rhs.reasoningTokens)
        )
    }

    /// 双方都缺 → 未知；否则缺失方按 0 计。
    static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        if lhs == nil, rhs == nil { return nil }
        return (lhs ?? 0) + (rhs ?? 0)
    }
}

extension Optional where Wrapped == Int {
    /// 两侧都有值才相加；任一缺失则整体缺失，避免把"未知"算成 0。
    static func combine(_ lhs: Int?, _ rhs: Int?, _ op: (Int, Int) -> Int) -> Int? {
        guard let lhs, let rhs else { return nil }
        return op(lhs, rhs)
    }
}
