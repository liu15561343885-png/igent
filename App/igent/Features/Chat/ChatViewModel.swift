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
    /// 正在流式的思维链。生成时展开显示，结束后随消息折叠。
    private(set) var streamingReasoning = ""
    private(set) var isStreaming = false
    /// 已经收到首个 token 前显示"正在输入"。
    private(set) var isThinking = false
    private(set) var lastError: String?
    /// 最近一轮的用量与估算成本，用于输入框上方的状态条。
    private(set) var lastTurnUsage: TokenUsage?
    private(set) var lastTurnCost: Double?
    /// 会话累计用量与当前上下文占用，供输入框上方的信息气泡使用。
    private(set) var sessionUsage: TokenUsage?
    private(set) var contextTokens = 0

    var draft = ""
    /// 本轮是否先联网检索。
    var webSearchEnabled = false
    private(set) var isSearching = false
    /// 模型判断本轮不需要检索。
    private(set) var searchSkipped = false
    /// 手动指定的 skill（下一轮生效，发完即清）。
    var pendingSkill: SkillDefinition?
    /// 图片生成模式：输入框的下一句被当作绘图提示词。
    private(set) var imageMode = false
    private(set) var isGeneratingImage = false
    /// 待发送的图片（已归一化并落盘）。
    private(set) var pendingImage: ImageAttachmentRef?
    /// 待随下一条消息发送的文档。解析安排在发送时，选文件时不占网络。
    private(set) var pendingDocuments: [PendingDocument] = []
    private(set) var isParsingDocument = false
    /// 解析进度文案，供输入条显示。
    private(set) var parsingStatus: String?
    /// 回合序号。停止时的兜底逻辑靠它判断"是否已经开了新回合"，避免误清新回合的状态。
    private var turnCounter = 0
    /// 插话：打断当前回合后要接着发出去的那句话。
    private(set) var pendingInterjection: String?
    /// 生成中发送消息的语义：插话（打断改方向）或排队（本轮结束后再发）。
    /// 两者互斥，由设置层保证只开一个。
    enum StreamingInputMode: String, Sendable {
        case off
        case interject
        case queue
    }

    var streamingInputMode: StreamingInputMode = .off

    var interjectEnabled: Bool { streamingInputMode == .interject }
    var queueEnabled: Bool { streamingInputMode == .queue }

    struct QueuedMessage: Identifiable, Sendable, Equatable {
        let id = UUID()
        var text: String
    }

    /// 等待本轮结束后依次发出的消息。
    private(set) var queued: [QueuedMessage] = []
    /// 上一轮的参数。插话要原样重开一轮，不能用当前界面状态猜。
    private struct TurnInputs {
        var configuration: TurnOrchestrator.Configuration
        var webSearch: (any WebSearchProvider)?
        var webFetch: (any WebFetchProvider)?
        var research: WebResearch?
        var skills: [SkillDefinition]
        var serverTools: [ServerToolRequest]
    }
    private var lastInputs: TurnInputs?

    private let store: SessionStore
    private let orchestrator: TurnOrchestrator
    private let attachments: AttachmentStore
    private let planner: SearchPlanner
    /// 文档解析器。为 nil 表示没配 DeepSeek Key，附件入口应禁用。
    var documentRecognizer: (any DocumentRecognizer)?
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
        attachments: AttachmentStore,
        planner: SearchPlanner
    ) {
        self.sessionID = sessionID
        self.store = store
        self.orchestrator = orchestrator
        self.attachments = attachments
        self.planner = planner
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
            await refreshMetrics()
        } catch {
            lastError = "读取会话失败：\(error)"
        }
    }

    /// 刷新会话累计用量与上下文占用。成本与百分比都由界面按开关决定要不要显示。
    func refreshMetrics() async {
        sessionUsage = try? await store.totalUsage(for: sessionID)
        let projection = (try? await store.projection(for: sessionID)) ?? SurfaceProjection()
        contextTokens = TokenEstimator.estimate(projection.messages)

        // 重开 App 时还没有"本轮"概念，用最近一次落库的用量顶上，
        // 否则气泡要等到下一轮才有数字。
        if let record = try? await store.latestUsage(for: sessionID) {
            lastTurnUsage = record.usage
            let model = lastModel.isEmpty ? record.model : lastModel
            if !model.isEmpty {
                lastTurnCost = PriceTable.estimate(record.usage, model: model).amountUSD
            }
        }
    }

    func send(
        configuration: TurnOrchestrator.Configuration,
        webSearch: (any WebSearchProvider)? = nil,
        webFetch: (any WebFetchProvider)? = nil,
        research: WebResearch? = nil,
        skills: [SkillDefinition] = [],
        serverTools: [ServerToolRequest] = [],
        recognizer: (any DocumentRecognizer)? = nil
    ) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let image = pendingImage
        let documents = pendingDocuments

        // 正在生成时：插话走中断、排队走队列，两者都要原始参数重开一轮。
        if isStreaming {
            guard !text.isEmpty else { return }
            if queueEnabled {
                _ = enqueue(text)
            } else if interjectEnabled {
                _ = interject(text)
            }
            return
        }

        guard !text.isEmpty || image != nil || !documents.isEmpty, !isParsingDocument else {
            return
        }

        // 先校验再清空：解析器缺失时若先清空，用户打的字和附件就没了。
        if !documents.isEmpty, recognizer == nil {
            lastError = "没有配置文档解析所需的 DeepSeek Key"
            return
        }
        let documentRecognizer = recognizer

        draft = ""
        pendingImage = nil
        pendingDocuments = []
        lastError = nil

        guard !documents.isEmpty else {
            startTurn(
                text: text,
                image: image,
                documents: [],
                configuration: configuration,
                webSearch: webSearch,
                webFetch: webFetch,
                research: research,
                skills: skills,
                serverTools: serverTools
            )
            return
        }


        // 解析要花几秒到几十秒（扫描件更久），先把界面切到「解析中」，
        // 而不是让发送按钮看起来没反应。
        guard let documentRecognizer else { return }

        isParsingDocument = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            var queue = documents

            for index in queue.indices where queue[index].attachment == nil {
                self.parsingStatus = queue.count > 1
                    ? "正在解析 \(index + 1)/\(queue.count)…"
                    : "正在解析…"
                do {
                    let recognized = try await documentRecognizer.recognize(
                        data: queue[index].data,
                        filename: queue[index].name
                    )
                    queue[index].attachment = DocumentAttachment(
                        name: queue[index].name,
                        pageCount: recognized.pageCount,
                        text: recognized.text,
                        truncated: recognized.isTruncated
                    )
                } catch {
                    // 失败就整体中止，但把已解析的结果留在待发送列表里，
                    // 重试时不会重复解析、重复计费。
                    self.lastError = "「\(queue[index].name)」解析失败：\(error)"
                    self.pendingDocuments = queue
                    // 用户刚打的字和图片也要还回去，否则一次网络失败就白写了。
                    if self.draft.isEmpty { self.draft = text }
                    if self.pendingImage == nil { self.pendingImage = image }
                    self.isParsingDocument = false
                    self.parsingStatus = nil
                    return
                }
            }

            self.isParsingDocument = false
            self.parsingStatus = nil
            self.startTurn(
                text: text,
                image: image,
                documents: queue.compactMap(\.attachment),
                configuration: configuration,
                webSearch: webSearch,
                webFetch: webFetch,
                research: research,
                skills: skills,
                serverTools: serverTools
            )
        }
    }

    /// 真正发起一轮对话。文档解析完成后再调用，保证进来的只有已就绪的块。
    private func startTurn(
        text: String,
        image: ImageAttachmentRef?,
        documents: [DocumentAttachment],
        configuration: TurnOrchestrator.Configuration,
        webSearch: (any WebSearchProvider)?,
        webFetch: (any WebFetchProvider)?,
        research: WebResearch?,
        skills: [SkillDefinition],
        serverTools: [ServerToolRequest],
        interjected: Bool = false
    ) {
        turnCounter += 1
        lastInputs = TurnInputs(
            configuration: configuration,
            webSearch: webSearch,
            webFetch: webFetch,
            research: research,
            skills: skills,
            serverTools: serverTools
        )
        isStreaming = true
        isThinking = true
        searchSkipped = false
        streamingText = ""
        streamingReasoning = ""
        pending = ""
        lastFlush = .distantPast

        // 顺序：图片 → 文档 → 文字。模型先看材料，再读指令。
        var blocks: [ContentBlock] = []
        if let image { blocks.append(.image(image)) }
        blocks.append(contentsOf: documents.map { .document($0) })
        if !text.isEmpty { blocks.append(.text(text)) }

        // 立刻把用户消息显示出来，不等落库往返。
        messages.append(Message(role: .user, blocks: blocks, source: .user))

        let query = text.isEmpty ? (documents.first?.name ?? "图片") : text
        let useSearch = webSearchEnabled && (webSearch != nil || research != nil)

        // skill 是"指令"，注入 system 最合适：四族的 system 落点由 systemStyle 统一处理，
        // 不必为此新增内容块类型。代价是每轮 system 变化，前缀缓存会失效。
        var effective = configuration
        effective.system = SkillRenderer.system(skills)

        if interjected {
            // 插话不是新话题，是"改方向"。明说这一点，模型才不会把前半段当没发生过。
            effective.system = InterjectHint.system(base: effective.system)
        }
        effective.serverTools = serverTools
        pendingSkill = nil

        lastModel = effective.model
        streamTask = Task { [weak self] in
            guard let self else { return }
            var outgoing = blocks

            // 先检索再问模型：证据作为 context 块随本轮一起发出，
            // UI 上的用户气泡仍然只有文字/图片/文档。
            if useSearch {
                self.isSearching = true

                // 先让模型判断「要不要搜、搜什么」，再执行。
                // 失败就退回用户原话——检索能力不能因为规划挂了而失效。
                let plan = await self.planner.plan(
                    question: query,
                    provider: configuration.provider,
                    model: configuration.model
                )
                let queries = plan.map(\.queries) ?? [query]

                if queries.isEmpty {
                    self.searchSkipped = true
                } else if let research {
                    // 深度调研：DeepSeek 用服务端工具多跳检索，产出事实与来源。
                    if let brief = try? await research.research(question: query, queries: queries) {
                        // 调研的中间过程作为展示块随消息存下来（受"显示思考过程与联网动作"开关控制）。
                        // 类型是 research_step，不会回传给任何厂商。
                        outgoing.append(contentsOf: brief.steps.map { step in
                            .providerBlock(ProviderBlock(
                                type: "research_step",
                                payload: .object(["text": .string(step)])
                            ))
                        })
                        outgoing.append(.context(
                            brief.contextEvidence(query: queries.joined(separator: " / "))
                        ))
                    }
                } else if let provider = webSearch {
                    let outcome = await WebContextBuilder().build(
                        queries: queries,
                        search: provider,
                        fetcher: webFetch ?? HTTPFetcher()
                    )
                    outgoing.append(.context(outcome.evidence))
                }
                self.isSearching = false
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
    struct PendingDocument: Sendable, Equatable, Identifiable {
        var id = UUID()
        var name: String
        var data: Data
        /// 解析结果。多文件时其中一个失败，已解析好的不会被丢弃、也不会重复计费。
        var attachment: DocumentAttachment?
    }

    /// 选文件后先记在内存里，发送时才解析——避免选完就干等几十秒。
    func attachDocument(name: String, data: Data) {
        pendingDocuments.append(PendingDocument(name: name, data: data))
        lastError = nil
    }

    func removeDocument(id: UUID) {
        pendingDocuments.removeAll { $0.id == id }
    }

    func removeAllDocuments() {
        pendingDocuments.removeAll()
    }

    func takeDraft() -> String {
        let value = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        return value
    }

    func reportError(_ message: String) {
        lastError = message
    }

    /// 插话：打断当前生成，把这句话作为新指示接着发出去。
    ///
    /// 各家 API 都没有"边生成边追加指令"的能力，所以只能中断后重开一轮；
    /// 中断时编排器会把已产出的前缀落库（interrupted），模型因此仍能看到自己说到哪。
    @discardableResult
    func interject(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, isStreaming, !isParsingDocument, lastInputs != nil else {
            return false
        }
        pendingInterjection = trimmed
        draft = ""
        stop()
        return true
    }

    /// 排队：本轮结束后再发。不打断当前生成。
    @discardableResult
    func enqueue(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, queueEnabled else { return false }
        queued.append(QueuedMessage(text: trimmed))
        draft = ""
        return true
    }

    func removeQueued(id: UUID) {
        queued.removeAll { $0.id == id }
    }

    /// 一轮结束后，把队首发出去。每次只发一条：后面的要等这条的新一轮结束。
    private func flushQueue() {
        guard !isStreaming, let inputs = lastInputs, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        startTurn(
            text: next.text,
            image: nil,
            documents: [],
            configuration: inputs.configuration,
            webSearch: inputs.webSearch,
            webFetch: inputs.webFetch,
            research: inputs.research,
            skills: inputs.skills,
            serverTools: inputs.serverTools
        )
    }

    /// 把待发的插话接着发出去。
    private func flushInterjection() {
        guard let pending = pendingInterjection, let inputs = lastInputs else { return }
        pendingInterjection = nil
        startTurn(
            text: InterjectHint.userText(pending),
            image: nil,
            documents: [],
            configuration: inputs.configuration,
            webSearch: inputs.webSearch,
            webFetch: inputs.webFetch,
            research: inputs.research,
            skills: inputs.skills,
            serverTools: inputs.serverTools,
            interjected: true
        )
    }

    func stop() {
        if isParsingDocument {
            // 解析阶段直接掐断；已经选中的文件不再恢复（需要重新选）。
            streamTask?.cancel()
            streamTask = nil
            isParsingDocument = false
            parsingStatus = nil
            return
        }

        // 只取消**生产端**。消费端要收到 .finished 才会复位状态、
        // 并把已产出的前缀从库里取回来；直接取消消费端会让 isStreaming
        // 永远停在 true——输入条卡死，再也发不出消息。
        Task { await orchestrator.cancel(in: sessionID) }

        // 兜底：生产端若卡住不回 .finished，3 秒后强制复位。
        // 带上回合序号：这 3 秒里用户可能已经开了新回合，那就不该再动界面。
        let token = turnCounter
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.isStreaming, self.turnCounter == token else { return }
            self.isStreaming = false
            self.isThinking = false
            self.isSearching = false
            self.streamingText = ""
            self.streamingReasoning = ""
            self.pending = ""
            await self.reload()
            self.flushInterjection()
            self.flushQueue()
        }
    }

    private func consume(_ update: TurnUpdate) async {
        switch update {
        case .started:
            isThinking = true

        case let .chunk(chunk):
            if case let .reasoningDelta(_, text) = chunk {
                streamingReasoning += text
                isThinking = false
                return
            }
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
            streamingReasoning = ""
            // 落库失败时投影可能是空的，直接覆盖会让整段对话从界面上消失
            // （数据还在库里）。这时保留现有消息，等下次加载再对齐。
            if !result.projection.messages.isEmpty || messages.isEmpty {
                messages = result.projection.messages
            }
            lastTurnUsage = result.usage
            lastTurnCost = result.usage.flatMap {
                PriceTable.estimate($0, model: lastModel).amountUSD
            }
            if case let .error(failure) = result.finish {
                lastError = Self.describe(failure)
            }
            await refreshMetrics()
            streamTask = nil
            // 插话是在取消之后才发的：等这一轮的收尾（部分内容已落库）完成再开新回合。
            flushInterjection()
            flushQueue()
        }
    }

    #if DEBUG
    /// 仅用于截图验证流式中的输入条布局（无法在没有真实 Key 时进入流式状态）。
    func debugEnterStreaming(draft: String = "") {
        isStreaming = true
        isThinking = false
        streamingText = "正在整理资料，稍等一下。"
        self.draft = draft
        if !draft.isEmpty { self.draft = draft }
    }
    #endif

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
            // 提示词已经落库但界面没刷新，会出现"看不见的孤儿消息"——
            // 用户重打一遍就会多出一条，切会话时才暴露。
            await reload()
            return false
        } catch {
            lastError = "生成失败：\(error)"
            await reload()
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
        case .invalidRequest: "请求参数被拒绝"
        case .invalidCredential: "密钥无效或已过期"
        case .emptyResponse: "模型没有返回内容"
        case .imageTooLarge: "图片过大"
        case .unsupportedCapability: "该模型不支持这个功能"
        case .decodeFailed: "响应格式无法解析"
        case .server: "厂商服务异常"
        default: failure.message
        }
    }
}
