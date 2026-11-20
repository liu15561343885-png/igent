import AgentKit
import CoreKit
import Foundation
import Observation
import StorageKit

/// 一个会话的界面状态与回合驱动。
@MainActor
@Observable
final class ChatViewModel {
    let sessionID: SessionID

    private(set) var messages: [Message] = []
    /// 正在流式的助手草稿。空串表示没有在流。
    private(set) var streamingText = ""
    private(set) var isStreaming = false
    /// 已经收到首个 token 前显示"正在输入"。
    private(set) var isThinking = false
    private(set) var lastError: String?

    var draft = ""

    private let store: SessionStore
    private let orchestrator: TurnOrchestrator
    private var streamTask: Task<Void, Never>?

    /// 流式刷新节流：约 30fps，避免每 token 重建整个列表。
    private static let flushInterval: TimeInterval = 1.0 / 30.0
    private var pending = ""
    private var lastFlush = Date.distantPast

    init(sessionID: SessionID, store: SessionStore, orchestrator: TurnOrchestrator) {
        self.sessionID = sessionID
        self.store = store
        self.orchestrator = orchestrator
    }

    func load() async {
        do {
            messages = try await store.projection(for: sessionID).messages
        } catch {
            lastError = "读取会话失败：\(error)"
        }
    }

    func send(configuration: TurnOrchestrator.Configuration) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }

        draft = ""
        lastError = nil
        isStreaming = true
        isThinking = true
        streamingText = ""
        pending = ""
        lastFlush = .distantPast

        // 立刻把用户消息显示出来，不等落库往返。
        messages.append(Message(role: .user, blocks: [.text(text)], source: .user))

        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.orchestrator.send(
                text,
                in: self.sessionID,
                configuration: configuration
            )
            for await update in stream {
                await self.consume(update)
            }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
        Task { await orchestrator.cancel() }
    }

    private func consume(_ update: TurnUpdate) async {
        switch update {
        case .started:
            isThinking = true

        case let .chunk(chunk):
            guard case let .textDelta(_, text) = chunk else { return }
            isThinking = false
            pending += text
            let now = Date()
            if now.timeIntervalSince(lastFlush) >= Self.flushInterval {
                streamingText += pending
                pending = ""
                lastFlush = now
            }

        case let .finished(result):
            if !pending.isEmpty {
                streamingText += pending
                pending = ""
            }
            isStreaming = false
            isThinking = false
            streamingText = ""
            messages = result.projection.messages
            if case let .error(failure) = result.finish {
                lastError = Self.describe(failure)
            }
            streamTask = nil
        }
    }

    private static func describe(_ failure: LlmFailure) -> String {
        switch failure.code {
        case .auth: "密钥无效或已过期"
        case .rateLimit: "请求过于频繁，稍后再试"
        case .quota: "额度已用尽"
        case .contextWindowExceeded: "上下文超出模型上限"
        case .noAdapter: "这家厂商还没配置好"
        case .network: "网络连接失败"
        case .contentFilter: "内容被安全策略拦截"
        case .cancelled: "已取消"
        default: failure.message
        }
    }
}
