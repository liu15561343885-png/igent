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
    /// 待发送的图片（已归一化并落盘）。
    private(set) var pendingImage: ImageAttachmentRef?

    private let store: SessionStore
    private let orchestrator: TurnOrchestrator
    private let attachments: AttachmentStore
    private var streamTask: Task<Void, Never>?

    /// 流式刷新节流：约 30fps，避免每 token 重建整个列表。
    private static let flushInterval: TimeInterval = 1.0 / 30.0
    private var pending = ""
    private var lastFlush = Date.distantPast

    init(
        sessionID: SessionID,
        store: SessionStore,
        orchestrator: TurnOrchestrator,
        attachments: AttachmentStore
    ) {
        self.sessionID = sessionID
        self.store = store
        self.orchestrator = orchestrator
        self.attachments = attachments
    }

    /// 接收用户从相册选的原始数据：归一化（EXIF 转正、限长边、转 JPEG）后落盘。
    func attach(_ data: Data) async {
        do {
            let normalized = try ImageNormalizer.normalize(data)
            pendingImage = try await attachments.save(normalized)
            lastError = nil
        } catch {
            lastError = "图片处理失败：\(error)"
        }
    }

    func removePendingImage() {
        pendingImage = nil
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
        let image = pendingImage
        guard !text.isEmpty || image != nil, !isStreaming else { return }

        // 图片放在文字前面：视觉模型通常先看图再读指令。
        var blocks: [ContentBlock] = []
        if let image { blocks.append(.image(image)) }
        if !text.isEmpty { blocks.append(.text(text)) }

        draft = ""
        pendingImage = nil
        lastError = nil
        isStreaming = true
        isThinking = true
        streamingText = ""
        pending = ""
        lastFlush = .distantPast

        // 立刻把用户消息显示出来，不等落库往返。
        messages.append(Message(role: .user, blocks: blocks, source: .user))

        streamTask = Task { [weak self] in
            guard let self else { return }
            let stream = await self.orchestrator.send(
                blocks,
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
