import CoreKit
import Foundation
import LLMKit
import StorageKit

/// 把较早的历史压成一段要点，用一条消息替换掉原区间。
///
/// 实现完全复用事件日志的 `replace` 机制：压缩 = 追加一条带 replace 区间的消息。
/// 旧事件仍留在日志里，可回滚、可审计。
public actor CompactionService {
    public struct Request: Sendable {
        public var sessionID: SessionID
        public var provider: String
        public var model: String
        /// 手动压缩时强制保留的条数；nil 表示交给 policy 按 token 预算决定。
        public var keepRecentMessages: Int?
        public var policy: CompactionPolicy
        public var contextWindow: Int
        public var reservedOutput: Int

        public init(
            sessionID: SessionID,
            provider: String,
            model: String,
            keepRecentMessages: Int? = nil,
            policy: CompactionPolicy = .default,
            contextWindow: Int = 128_000,
            reservedOutput: Int = 4_096
        ) {
            self.sessionID = sessionID
            self.provider = provider
            self.model = model
            self.keepRecentMessages = keepRecentMessages
            self.policy = policy
            self.contextWindow = contextWindow
            self.reservedOutput = reservedOutput
        }
    }

    public struct Outcome: Sendable {
        public var shadowedCount: Int
        public var summary: String
        public var usage: TokenUsage?
    }

    public enum CompactionError: Error, Equatable {
        case emptySummary
    }

    private let store: SessionStore
    private let runtime: LlmRuntime

    public init(store: SessionStore, runtime: LlmRuntime) {
        self.store = store
        self.runtime = runtime
    }

    static let systemPrompt = """
    你是对话压缩器。把给定的历史对话压成要点，供后续对话继续使用。

    要求：
    - 保留：人物/项目名、数字、已做出的决定、未完成的事项、用户明确表达的偏好。
    - 丢弃：寒暄、重复、已经被推翻的内容。
    - 用第三人称陈述，不要写成"用户说……助手说……"的流水账。
    - 不超过 200 字。
    """

    public func compact(_ request: Request) async throws -> Outcome? {
        let projection = try await store.projection(for: request.sessionID)

        let compactCount: Int
        if let keep = request.keepRecentMessages {
            // 手动压缩：按条数保留，行为可预测。
            guard projection.messages.count > max(2, keep) else { return nil }
            compactCount = projection.messages.count - max(2, keep)
        } else {
            // 自动压缩：按 token 预算保留尾部。
            let tokens = projection.messages.map { TokenEstimator.estimate($0) }
            let retain = request.policy.retainTokens(
                contextWindow: request.contextWindow,
                reservedOutput: request.reservedOutput
            )
            compactCount = request.policy.compactCount(
                messageTokens: tokens,
                retainTokens: retain,
                minimumMessages: request.policy.minimumMessages
            )
            guard compactCount > 0 else { return nil }
        }

        let targets = Array(projection.messages.prefix(compactCount))
        let seqs = Array(projection.messageSeqs.prefix(compactCount))
        // 即便投影层的顺序假设被破坏，也不能生成 start > end 的区间——
        // 那种 replace 会静默失败，表现为"压缩过但上下文没变短"。
        guard let firstSeq = seqs.min(), let lastSeq = seqs.max() else { return nil }

        let transcript = Self.render(targets)
        let options = GenerateOptions(
            provider: request.provider,
            model: request.model,
            messages: [
                Message(role: .user, blocks: [.text(transcript)], source: .user)
            ],
            system: Self.systemPrompt,
            maxTokens: 512,
            purpose: .compaction
        )

        var assembler = BlockAssembler()
        var usage: TokenUsage?
        for try await chunk in await runtime.stream(options) {
            assembler.push(chunk)
            if case let .usage(value) = chunk { usage = value }
        }

        let summary = ((try? assembler.blocks())?.answerText ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw CompactionError.emptySummary }

        let summaryMessage = Message(
            role: .context,
            blocks: [.text("【此前对话的要点】\n\(summary)")],
            source: .compactionSummary(compactionID: UUID()),
            retention: .durable
        )
        try await store.append(
            .contextMessage(summaryMessage),
            to: request.sessionID,
            surfaceOp: .replace(startSeq: firstSeq, endSeq: lastSeq)
        )

        if let usage {
            try await store.logUsage(
                sessionID: request.sessionID,
                turn: nil,
                step: nil,
                provider: request.provider,
                model: request.model,
                purpose: .compaction,
                usage: usage
            )
        }

        return Outcome(shadowedCount: compactCount, summary: summary, usage: usage)
    }

    /// 把消息渲染成"用户：…／助手：…"，并限制总长度。
    static func render(_ messages: [Message], limit: Int = 8000) -> String {
        var lines: [String] = []
        for message in messages {
            let text = message.visibleText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            switch message.role {
            case .user: lines.append("用户：\(text)")
            case .assistant: lines.append("助手：\(text)")
            case .context: lines.append("（资料）\(text)")
            case .system: continue
            }
        }
        var joined = lines.joined(separator: "\n\n")
        if joined.count > limit {
            joined = String(joined.suffix(limit))
        }
        return joined
    }
}
