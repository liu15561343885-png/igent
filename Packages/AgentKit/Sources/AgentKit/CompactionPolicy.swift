import CoreKit
import Foundation

/// 自动压缩策略。参数取法参考 DSH 的 `dsh-compaction-basic`：
/// 压力阈值看窗口比例、保留量也按比例算，另有一条"厂商报上下文溢出"的兜底恢复。
public struct CompactionPolicy: Sendable, Equatable {
    /// 压力超过窗口的多少比例就压。
    public var thresholdRatio: Double
    /// 保留尾部占窗口的比例（压缩后仍需留够上下文继续对话）。
    public var retainRatio: Double
    /// 少于这么多条消息时不做自动压缩。
    public var minimumMessages: Int
    /// 厂商返回 contextWindowExceeded 时，是否压缩后重试一次。
    public var overflowRecovery: Bool

    public init(
        thresholdRatio: Double = 0.80,
        retainRatio: Double = 0.16,
        minimumMessages: Int = 8,
        overflowRecovery: Bool = true
    ) {
        self.thresholdRatio = thresholdRatio
        self.retainRatio = retainRatio
        self.minimumMessages = minimumMessages
        self.overflowRecovery = overflowRecovery
    }

    public static let `default` = CompactionPolicy()

    /// 触发压缩的 token 数。为输出预留的空间要扣除，否则压缩刚好卡在边缘。
    public func thresholdTokens(contextWindow: Int, reservedOutput: Int) -> Int {
        let usable = max(1_000, contextWindow - reservedOutput)
        return Int(Double(usable) * thresholdRatio)
    }

    /// 至少要原样保留多少 token 的近期上下文。
    public func retainTokens(contextWindow: Int, reservedOutput: Int) -> Int {
        let usable = max(1_000, contextWindow - reservedOutput)
        return max(500, Int(Double(usable) * retainRatio))
    }

    public func shouldCompact(
        inputTokens: Int,
        messageCount: Int,
        contextWindow: Int,
        reservedOutput: Int
    ) -> Bool {
        guard messageCount >= minimumMessages else { return false }
        return inputTokens >= thresholdTokens(contextWindow: contextWindow, reservedOutput: reservedOutput)
    }

    /// 选出要压缩的区间：从最早的消息开始，一直压到"保留尾部够 retainTokens"为止。
    ///
    /// 返回的是**消息下标**（不含），调用方再映射成 seq。
    public func compactCount(messageTokens: [Int], retainTokens: Int, minimumMessages: Int) -> Int {
        // minimumMessages 管的是"这个会话够不够长"，不是"要压多少条"。
        guard messageTokens.count >= minimumMessages else { return 0 }

        var retained = 0
        var index = messageTokens.count - 1
        while index >= 0 {
            retained += messageTokens[index]
            if retained >= retainTokens { break }
            index -= 1
        }
        // 无论 token 预算多小，都必须留两条：压缩完一句上下文都不剩等于把会话清空。
        index = min(index, messageTokens.count - 2)

        guard index >= 1 else { return 0 }
        return index
    }
}
