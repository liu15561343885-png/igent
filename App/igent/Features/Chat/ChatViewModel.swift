import AgentKit
import CoreKit
import Foundation
import LLMKit
import Observation
import StorageKit
import WebSeamKit

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
    /// 最近一轮的用量与估算成本，用于输入框上方的状态条。
    private(set) var lastTurnUsage: TokenUsage?
    private(set) var lastTurnCost: Double?

    var draft = ""
    /// 本轮是否先联网检索。
    var webSearchEnabled = false
    private(set) var isSearching = false
    /// 手动指定的 skill（下一轮生效，发完即清）。
    var pendingSkill: SkillDefinition?
    /// 图片生成模式：输入框的下一句被当作绘图提示词。
    private(set) var imageMode = false
    private(set) var isGeneratingImage = false
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
    private var lastModel = ""

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

    /// 压缩之后表面变了，需要重新读一遍投影。
    func reload() async {
        messages = (try? await store.projection(for: sessionID).messages) ?? messages
    }

    func load() async {
        do {
            messages = try await store.projection(for: sessionID).messages
        } catch {
            lastError = "读取会话失败：\(error)"
        }
    }

    func send(
        configuration: TurnOrchestrator.Configuration,
        webSearch: (any WebSearchProvider)? = nil,
        webFetch: (any WebFetchProvider)? = nil,
        skills: [SkillDefinition] = [],
        serverTools: [ServerToolRequest] = []
    ) {
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

        let query = text.isEmpty ? "图片" : text
        let useSearch = webSearchEnabled && webSearch != nil

        // skill 是"指令"，注入 system 最合适：四族的 system 落点由 systemStyle 统一处理，
        // 不必为此新增内容块类型。代价是每轮 system 变化，前缀缓存会失效。
        var effective = configuration
        effective.system = SkillRenderer.system(skills)
        effective.serverTools = serverTools
        pendingSkill = nil

        lastModel = effective.model
        streamTask = Task { [weak self] in
            guard let self else { return }
            var outgoing = blocks

            // 先检索再问模型：证据作为 context 块随本轮一起发出，
            // UI 上的用户气泡仍然只有文字/图片（context 不显示）。
            if useSearch, let provider = webSearch {
                self.isSearching = true
                let outcome = await WebContextBuilder().build(
                    query: query,
                    search: provider,
                    fetcher: webFetch ?? HTTPFetcher()
                )
                self.isSearching = false
                outgoing.append(.context(outcome.evidence))
            }

            let stream = await self.orchestrator.send(
                outgoing,
                in: self.sessionID,
                configuration: effective
            )
            for await update in stream {
                await self.consume(update)
            }
        }
    }

    /// 两个模式互斥：开一个就关另一个，避免"边检索边画图"这种没有意义的状态。
    func setWebSearch(_ enabled: Bool) {
        webSearchEnabled = enabled
        if enabled { imageMode = false }
    }

    func setImageMode(_ enabled: Bool) {
        imageMode = enabled
        if enabled { webSearchEnabled = false }
    }

    /// 取走输入框内容并清空（图片模式需要先拿到提示词）。
    func takeDraft() -> String {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        return value
    }

    func reportError(_ message: String) {
        lastError = message
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
            lastTurnUsage = result.usage
            lastTurnCost = result.usage.flatMap {
                PriceTable.estimate($0, model: lastModel).amountUSD
            }
            if case let .error(failure) = result.finish {
                lastError = Self.describe(failure)
            }
            streamTask = nil
        }
    }

    // MARK: - 图片生成

    /// 走独立的生成接口，不经过对话回合。
    @discardableResult
    func generateImage(
        prompt: String,
        adapter: any ImageGenerationAdapter,
        model: String
    ) async -> Bool {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isStreaming else { return false }
        lastError = nil

        isGeneratingImage = true
        defer { isGeneratingImage = false }

        do {
            let ask = Message(role: .user, blocks: [.text("生成图片：\(trimmed)")], source: .user)
            try await store.append(.userMessage(ask), to: sessionID, surfaceOp: .append)

            let generated = try await adapter.generate(
                ImageGenerationRequest(model: model, prompt: trimmed)
            )

            var refs: [ImageAttachmentRef] = []
            for image in generated {
                // 生成结果也走一遍归一化：不同厂商给的尺寸与格式都不统一。
                let normalized = try ImageNormalizer.normalize(image.data)
                refs.append(try await attachments.save(normalized))
            }
            guard !refs.isEmpty else { throw ImageGenerationError.emptyResponse }

            var blocks: [ContentBlock] = refs.map { .image($0) }
            blocks.append(.text("已生成 \(refs.count) 张图。"))

            let answer = Message(
                role: .assistant,
                blocks: blocks,
                source: .model(provider: "", model: model, meta: nil)
            )
            try await store.append(
                .assistantMessage(answer, usage: nil, interrupted: false),
                to: sessionID,
                surfaceOp: .append
            )
            messages = try await store.projection(for: sessionID).messages
            return true
        } catch let failure as LlmFailure {
            lastError = Self.describe(failure)
            return false
        } catch {
            lastError = "生成失败：\(error)"
            return false
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
