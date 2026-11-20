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
        /// 保留最近多少条消息不动。
        public var keepRecentMessages: Int
        /// 少于这个条数就不压，避免把短会话压成一句话。
        public var minimumMessages: Int

        public init(
            sessionID: SessionID,
            provider: String,
            model: String,
            keepRecentMessages: Int = 6,
            minimumMessages: Int = 12
        ) {
            self.sessionID = sessionID
            self.provider = provider
            self.model = model
            self.keepRecentMessages = keepRecentMessages
            self.minimumMessages = minimumMessages
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
        guard projection.messages.count >= request.minimumMessages else { return nil }

        let keep = max(2, request.keepRecentMessages)
        let compactCount = projection.messages.count - keep
        guard compactCount > 0 else { return nil }

        let targets = Array(projection.messages.prefix(compactCount))
        let seqs = Array(projection.messageSeqs.prefix(compactCount))
        guard let firstSeq = seqs.first, let lastSeq = seqs.last else { return nil }

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

        let summary = ((try? assembler.blocks()) ?? [])
            .map(\.plainText)
            .joined()
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
