import AgentKit
import CoreKit
import Foundation
import LLMKit
import AgentKit
import Observation
import StorageKit
import UIKit
import WebSeamKit

/// 应用级依赖装配。只在启动时创建一次。
@MainActor
@Observable
final class AppEnvironment {
    let store: SessionStore
    let runtime: LlmRuntime
    let orchestrator: TurnOrchestrator
    let keychain: Keychain
    /// 图片附件（内容寻址）。
    let attachments: AttachmentStore
    /// skill 注册表（扫 Documents/Skills）。
    let skillRegistry: SkillRegistry
    let compaction: CompactionService
    let titles: TitleService
    let planner: SearchPlanner
    /// 已加载 skill 的同步快照，供发送时拼 system。
    var skillDefinitions: [String: SkillDefinition] = [:]
    var skillSummaries: [SkillSummary] = []
    /// 所有厂商请求的旁路记录，供请求检查器展示。
    let requestLog = RequestLog()

    private(set) var profiles: [ProviderProfile] = []
    private(set) var bootError: String?
    private var registrations: [Registration] = []

    /// 当前选中的厂商与模型，跨会话记住。
    var activeProfileID: String? {
        didSet { UserDefaults.standard.set(activeProfileID, forKey: "activeProfileID") }
    }

    var activeModel: String {
        didSet { UserDefaults.standard.set(activeModel, forKey: "activeModel") }
    }

    /// 界面需要观察的变化点，UserDefaults 本身不参与 SwiftUI 的依赖追踪。
    var webSearchKind: String {
        didSet { UserDefaults.standard.set(webSearchKind, forKey: "webSearchKind") }
    }

    /// 图片厂商配置变化时自增，方便界面刷新（配置存在 UserDefaults 里，不参与观察）。
    var imageProviderRevision = 0
    /// 检索方式变化时自增，同上。
    var searchModeRevision = 0
    /// 文档解析方式变化时自增，同上。
    var documentPurposeRevision = 0

    /// 是否显示思维链、检索动作等中间过程。
    var showInternals: Bool {
        didSet { UserDefaults.standard.set(showInternals, forKey: "showInternals") }
    }

    /// 回答完成后是否自动收起思维链。关掉则保持展开，由用户手动折。
    var autoCollapseReasoning: Bool {
        didSet { UserDefaults.standard.set(autoCollapseReasoning, forKey: "autoCollapseReasoning") }
    }

    /// 输入框上方的用量气泡：是否显示、显示哪几项。
    var showUsageBubble: Bool {
        didSet { UserDefaults.standard.set(showUsageBubble, forKey: "showUsageBubble") }
    }

    var usageBubbleItems: Set<UsageBubbleItem> {
        didSet {
            UserDefaults.standard.set(
                usageBubbleItems.map(\.rawValue).sorted(),
                forKey: "usageBubbleItems"
            )
        }
    }

    /// 自动压缩开关。改它会即时影响正在运行的编排器。
    var autoCompactionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoCompactionEnabled, forKey: "autoCompaction")
            let policy: CompactionPolicy? = autoCompactionEnabled ? .default : nil
            Task { await orchestrator.setPolicy(policy) }
        }
    }

    var activeProfile: ProviderProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    init(databaseURL: URL) {
        keychain = Keychain()
        runtime = LlmRuntime()
        attachments = (try? AttachmentStore(root: databaseURL.deletingLastPathComponent().appendingPathComponent("Attachments")))
            ?? (try! AttachmentStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("Attachments")))
        skillRegistry = SkillRegistry(
            provider: FileSystemSkillProvider(root: Self.skillsRoot)
        )
        do {
            let store = try SessionStore(url: databaseURL)
            self.store = store
            self.orchestrator = TurnOrchestrator(store: store, runtime: runtime)
        } catch {
            // 数据库打不开时仍然构造一个内存库，保证界面能起来并显示错误。
            let fallback = try! SessionStore.inMemory()
            self.store = fallback
            self.orchestrator = TurnOrchestrator(store: fallback, runtime: runtime)
            bootError = "数据库打开失败：\(error)"
        }

        // 依赖 store 的服务必须在 store 赋值之后构造。
        compaction = CompactionService(store: store, runtime: runtime)
        titles = TitleService(store: store, runtime: runtime)
        planner = SearchPlanner(runtime: runtime)

        autoCompactionEnabled = UserDefaults.standard.object(forKey: "autoCompaction") as? Bool ?? true
        showInternals = UserDefaults.standard.object(forKey: "showInternals") as? Bool ?? true
        autoCollapseReasoning = UserDefaults.standard.object(forKey: "autoCollapseReasoning") as? Bool ?? true
        showUsageBubble = UserDefaults.standard.object(forKey: "showUsageBubble") as? Bool ?? true
        if let raw = UserDefaults.standard.stringArray(forKey: "usageBubbleItems") {
            usageBubbleItems = Set(raw.compactMap(UsageBubbleItem.init(rawValue:)))
        } else {
            usageBubbleItems = Set(UsageBubbleItem.allCases)
        }
        activeProfileID = UserDefaults.standard.string(forKey: "activeProfileID")
        activeModel = UserDefaults.standard.string(forKey: "activeModel") ?? ""
        webSearchKind = UserDefaults.standard.string(forKey: "webSearchKind")
            ?? WebSearchKind.off.rawValue
    }

    private(set) var currentSession: SessionSummary?
    private(set) var chat: ChatViewModel?

    /// 启动流程：读配置 → 装配适配器 → 选默认厂商 → 开一个会话。
    func bootstrap() async {
        await reloadProviders()
        if activeProfile == nil {
            activeProfileID = profiles.first?.id
        }
        if activeModel.isEmpty {
            activeModel = activeProfile?.defaultModel ?? ""
        }
        await reloadSkills()

        // didSet 只在用户改开关时触发；启动时要把已存的值真正应用到编排器上。
        await orchestrator.setPolicy(autoCompactionEnabled ? .default : nil)

        // 没有任何厂商时不建会话：RootView 靠 "无会话且无厂商" 判定首次引导，
        // 先建会话会让引导一闪而过。
        if !profiles.isEmpty {
            await ensureSession()
        }
        await pruneOrphanAttachments()
        #if DEBUG
        await seedDemoConversationIfRequested()
        #endif
    }

    #if DEBUG
    /// 仅用于模拟器截图与界面迭代：`-seedDemoConversation` 启动参数会灌一段示例对话。
    private func seedDemoConversationIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemoConversation") else { return }

        if ProcessInfo.processInfo.arguments.contains("-hideInternals") {
            showInternals = false
        }

        // 让两个模式开关处于"可用"状态，方便截图与界面迭代。
        webSearchKind = WebSearchKind.tavily.rawValue
        setWebSearchKey("demo-key")
        setImageAPIKey("demo-key")

        let existing = (try? await store.profiles()) ?? []
        if existing.isEmpty {
            await save(
                profile: ProviderProfile.openAICompatible(
                    id: "demo",
                    name: "Demo 厂商",
                    baseURL: "https://api.openai.com/v1"
                ),
                apiKey: "sk-demo"
            )
            activeProfileID = "demo"
            activeModel = "gpt-4o-mini"
        }

        guard let session = try? await store.createSession(title: "示例对话") else { return }
        let lines: [(MessageRole, String)] = [
            (.user, "帮我把这段话改得书面一点：这个方案我觉得还行，就是有点贵。"),
            (.assistant, "可以这样改：\n\n**「该方案整体可行，主要顾虑在于成本偏高。」**\n\n如果要更克制一点，拆成两句：\n\n1. 方案整体可行\n2. 成本需要再压一压"),
            (.user, "用 Swift 写个流式刷新的节流"),
            (.assistant, "关键不是丢帧，是**合并**：\n\n```swift\nvar pending = \"\"\nvar lastFlush = Date.distantPast\n\nfunc push(_ token: String) {\n    pending += token\n    let now = Date()\n    if now.timeIntervalSince(lastFlush) >= 1.0 / 30.0 {\n        text += pending\n        pending = \"\"\n        lastFlush = now\n    }\n}\n```\n\n这样 200 token 的爆发会被压成约 6 次界面更新。")
        ]
        for (role, text) in lines {
            let message = Message(
                role: role,
                blocks: [.text(text)],
                source: role == .assistant
                    ? .model(provider: "demo", model: "gpt-4o-mini", meta: nil)
                    : .user
            )
            let event: SessionEvent = role == .assistant
                ? .assistantMessage(message, usage: nil, interrupted: false)
                : .userMessage(message)
            _ = try? await store.append(event, to: session.id, surfaceOp: .append)
        }
        // 一张带图的消息，用来验证视觉链路与气泡渲染。
        if let data = Self.demoImageData(),
           let normalized = try? ImageNormalizer.normalize(data),
           let ref = try? await attachments.save(normalized) {
            let question = Message(
                role: .user,
                blocks: [.image(ref), .text("这张图里写了什么？")],
                source: .user
            )
            _ = try? await store.append(.userMessage(question), to: session.id, surfaceOp: .append)

            let answer = Message(
                role: .assistant,
                blocks: [.text("图上是一块青绿色背景，中间用白色粗体写着 **igent**。")],
                source: .model(provider: "demo", model: "gpt-4o-mini", meta: nil)
            )
            _ = try? await store.append(
                .assistantMessage(answer, usage: nil, interrupted: false),
                to: session.id,
                surfaceOp: .append
            )
        }

        // 一条带"调研中间过程 + 来源"的消息，验证显示开关与引用渲染。
        let researchAsk = Message(
            role: .user,
            blocks: [.text("DeepSeek 最近发布了什么？")],
            source: .user
        )
        let evidence = ContextEvidence(
            query: "DeepSeek 2026年11月 发布",
            sources: [
                WebSource(url: URL(string: "https://api-docs.deepseek.com/guides/web_tools")!, title: "Web Tools"),
                WebSource(url: URL(string: "https://api-docs.deepseek.com/guides/search")!, title: "Search & Fetch")
            ],
            digest: "DeepSeek 在 2026 年 11 月开放了 Web Tools 与 Search/Fetch API。[1][2]",
            fetchedAt: Date(),
            truncated: false
        )
        let researchAnswer = Message(
            role: .assistant,
            blocks: [
                .providerBlock(ProviderBlock(type: "research_step", payload: .object(["text": .string("检索：DeepSeek 2026年11月 发布")]))),
                .providerBlock(ProviderBlock(type: "research_step", payload: .object(["text": .string("打开：api-docs.deepseek.com")]))),
                .providerBlock(ProviderBlock(type: "research_step", payload: .object(["text": .string("找到 5 条结果")]))),
                .context(evidence),
                .text("DeepSeek 在 2026 年 11 月开放了两套联网能力：对话里的服务端工具，以及独立的 Search/Fetch API [1][2]。"),
                .citation(Citation(index: 1, url: URL(string: "https://api-docs.deepseek.com/guides/web_tools")!, title: "Web Tools")),
                .citation(Citation(index: 2, url: URL(string: "https://api-docs.deepseek.com/guides/search")!, title: "Search & Fetch"))
            ],
            source: .model(provider: "demo", model: "gpt-4o-mini", meta: nil)
        )
        _ = try? await store.append(.userMessage(researchAsk), to: session.id, surfaceOp: .append)
        _ = try? await store.append(
            .assistantMessage(researchAnswer, usage: nil, interrupted: false),
            to: session.id,
            surfaceOp: .append
        )

        let docAsk = Message(
            role: .user,
            blocks: [
                .document(DocumentAttachment(
                    name: "季度报告.pdf",
                    pageCount: 3,
                    text: "本季度营收同比增长 18%，主要来自海外市场。"
                )),
                .text("这份文件讲了什么？")
            ],
            source: .user
        )
        let docAnswer = Message(
            role: .assistant,
            blocks: [.text("这季度营收同比涨了 18%，增量主要来自海外市场。")],
            source: .model(provider: "demo", model: "gpt-4o-mini", meta: nil)
        )
        _ = try? await store.append(.userMessage(docAsk), to: session.id, surfaceOp: .append)
        _ = try? await store.append(
            .assistantMessage(docAnswer, usage: nil, interrupted: false),
            to: session.id,
            surfaceOp: .append
        )

        try? await store.logUsage(
            sessionID: session.id,
            turn: 1,
            step: 1,
            provider: "demo",
            model: "gpt-4o-mini",
            purpose: nil,
            usage: TokenUsage(
                uncachedInputTokens: 1_840,
                outputTokens: 620,
                totalTokens: 2_460,
                cacheReadTokens: 3_200
            )
        )

        await open(session: session)
    }

    private static func demoImageData() -> Data? {
        let size = CGSize(width: 600, height: 400)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let text = "igent" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 84, weight: .bold),
                .foregroundColor: UIColor.white
            ]
            let textSize = text.size(withAttributes: attributes)
            text.draw(
                at: CGPoint(
                    x: (size.width - textSize.width) / 2,
                    y: (size.height - textSize.height) / 2
                ),
                withAttributes: attributes
            )
        }
        return image.pngData()
    }
    #endif

    func ensureSession() async {
        guard currentSession == nil else { return }
        await startNewSession()
    }

    func startNewSession() async {
        guard let session = try? await store.createSession(title: "新对话") else { return }
        await open(session: session)
    }

    func open(session: SessionSummary) async {
        if let previous = currentSession?.id, previous != session.id {
            await orchestrator.cancel(in: previous)
        }

        currentSession = session
        let model = ChatViewModel(
            sessionID: session.id,
            store: store,
            orchestrator: orchestrator,
            attachments: attachments,
            planner: planner
        )
        await model.load()
        chat = model
    }

    /// 清理没有被任何会话引用的图片文件。
    ///
    /// 图片内容寻址、跨会话共享，删会话时无法就地判断"还有人用吗"，
    /// 所以按引用集合反向清理；顺带收拾掉崩溃留下的半截文件。
    /// 启动时也跑一次，覆盖上次异常退出的残留。
    func pruneOrphanAttachments() async {
        // 数据库没打开时（内存兜底）引用集合必然是空的，
        // 此时清理等于把历史图片全部删掉——宁可这轮不清理。
        guard bootError == nil else { return }
        guard let paths = try? await store.referencedAttachmentPaths() else { return }
        // 10 分钟宽限：选图后尚未发送、或正在生成的图片还没有事件引用。
        _ = await attachments.prune(referenced: paths, minimumAge: 600)
    }

    func delete(session: SessionSummary) async {
        try? await store.delete(session.id)
        await pruneOrphanAttachments()
        if currentSession?.id == session.id {
            currentSession = nil
            chat = nil
            await startNewSession()
        }
    }

    func reloadProviders() async {
        for registration in registrations {
            await registration.dispose()
        }
        registrations.removeAll()

        do {
            profiles = try await store.profiles()
        } catch {
            bootError = "读取厂商配置失败：\(error)"
            return
        }

        for profile in profiles {
            let key = keychain.get(Keychain.account(for: profile.id)) ?? ""
            let transport = LoggingTransport(
                upstream: URLSessionTransport(),
                log: requestLog,
                label: profile.name
            )
            let adapter = AdapterFactory.make(
                profile: profile,
                apiKey: key,
                transport: transport,
                imageResolver: StorageImageResolver(store: attachments)
            )
            if let registration = try? await runtime.register(providers: [profile.id], adapter: adapter) {
                registrations.append(registration)
            }
        }
    }

    /// 新建或更新一条厂商配置，密钥进 Keychain。
    func save(profile: ProviderProfile, apiKey: String) async {
        do {
            try await store.saveProfile(profile)
            if apiKey.isEmpty {
                keychain.delete(Keychain.account(for: profile.id))
            } else {
                try keychain.set(apiKey, for: Keychain.account(for: profile.id))
            }
            await reloadProviders()
            if activeProfileID == nil { activeProfileID = profile.id }
            if activeModel.isEmpty { activeModel = profile.defaultModel }
        } catch {
            bootError = "保存失败：\(error)"
        }
    }

    func delete(profile: ProviderProfile) async {
        try? await store.deleteProfile(id: profile.id)
        keychain.delete(Keychain.account(for: profile.id))
        if activeProfileID == profile.id { activeProfileID = nil }
        await reloadProviders()
    }

    /// 检索服务的密钥走单独账号，避免与其他配置混淆。
    var apiKeyForWebSearch: String {
        keychain.get(Keychain.account(for: "websearch")) ?? ""
    }

    func setWebSearchKey(_ value: String) {
        if value.isEmpty {
            keychain.delete(Keychain.account(for: "websearch"))
        } else {
            try? keychain.set(value, for: Keychain.account(for: "websearch"))
        }
    }

    func apiKey(for profile: ProviderProfile) -> String {
        keychain.get(Keychain.account(for: profile.id)) ?? ""
    }
}

extension ProviderProfile {
    /// 新建配置时的建议模型名，省得每次都手打。
    var defaultModel: String {
        switch family {
        case .anthropic: "claude-sonnet-4-5"
        case .gemini: "gemini-2.5-flash"
        case .openAIResponses: "gpt-5"
        case .openAICompatible: "gpt-4o-mini"
        }
    }
}

// MARK: - 会话级操作：压缩 / 统计 / 导出 / 标题

struct SessionStats: Sendable {
    var usage: TokenUsage?
    var costUSD: Double?
    var messageCount: Int
    var model: String
}

extension AppEnvironment {
    /// 压缩较早的历史。返回被压掉的消息数，nil 表示不值得压。
    /// 文档解析复用 DeepSeek 的 Key：OCR 是 DeepSeek 的工具接口，按页计费。
    var isDocumentParsingConfigured: Bool { makeDocumentRecognizer() != nil }

    func makeDocumentRecognizer() -> (any DocumentRecognizer)? {
        guard WebSearchKind(rawValue: webSearchKind) == .deepseek else { return nil }
        let key = keychain.get(Keychain.account(for: "websearch")) ?? ""
        guard !key.isEmpty else { return nil }
        return DeepSeekOCRRecognizer(apiKey: key, purpose: documentPurpose.recognizerPurpose)
    }

    func compactCurrentSession() async -> Int? {
        guard let chat = chat, let profile = activeProfile else { return nil }
        // 手动压缩按固定条数保留，行为可预测；自动压缩才按 token 预算。
        let outcome = try? await compaction.compact(
            .init(
                sessionID: chat.sessionID,
                provider: profile.id,
                model: activeModel,
                keepRecentMessages: 6,
                contextWindow: profile.contextWindow
            )
        )
        guard let outcome else { return nil }
        await chat.reload()
        return outcome.shadowedCount
    }

    func currentStats() async -> SessionStats? {
        guard let chat else { return nil }
        let usage = try? await store.totalUsage(for: chat.sessionID)
        let projection = (try? await store.projection(for: chat.sessionID)) ?? SurfaceProjection()
        return SessionStats(
            usage: usage,
            costUSD: usage.flatMap { PriceTable.estimate($0, model: activeModel).amountUSD },
            messageCount: projection.messages.count,
            model: activeModel
        )
    }

    func exportCurrentSession() async -> String? {
        guard let session = currentSession else { return nil }
        let projection = (try? await store.projection(for: session.id)) ?? SurfaceProjection()
        let usage = try? await store.totalUsage(for: session.id)
        return SessionExporter.markdown(
            session: session,
            messages: projection.messages,
            totalUsage: usage
        )
    }

    /// 首轮对话结束后自动起标题。已经在用自定义标题就跳过。
    func generateTitleIfNeeded(sessionID: SessionID) async {
        guard let profile = activeProfile else { return }
        guard let projection = try? await store.projection(for: sessionID) else { return }
        // 只在首轮之后触发：消息太多说明早就该起过名了（多半是失败过）。
        guard projection.messages.count <= 4 else { return }
        guard projection.messages.contains(where: { $0.role == .assistant }) else { return }

        if let title = await titles.generateTitle(
            sessionID: sessionID,
            provider: profile.id,
            model: activeModel
        ) {
            if let current = currentSession, current.id == sessionID {
                currentSession?.title = title
            }
        }
    }
}
