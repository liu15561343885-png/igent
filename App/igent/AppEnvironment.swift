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
    let attachments: AttachmentStore?
    /// skill 注册表（扫 Documents/Skills）。
    let skillRegistry: SkillRegistry
    let compaction: CompactionService
    let titles: TitleService
    let planner: SearchPlanner
    /// 生成中申请后台时间，避免切出去就断流。
    let backgroundKeeper = BackgroundKeeper()
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
        didSet {
            UserDefaults.standard.set(activeProfileID, forKey: "activeProfileID")
            // 换厂商后旧列表不再有意义。
            availableModels = []
            modelFetchError = nil
            guard oldValue != activeProfileID,
                  let profile = profiles.first(where: { $0.id == activeProfileID })
            else { return }
            // 换厂商却不换模型名，首次发送会把上一家的模型名发过去——直接 404。
            // 只有当前模型为空或明显不属于新厂商时才重置，避免覆盖用户手填的模型名。
            if activeModel.isEmpty || !activeModel.lowercased().contains(Self.modelHint(for: profile.family)) {
                activeModel = profile.defaultModel
            }
        }
    }

    var activeModel: String {
        didSet { UserDefaults.standard.set(activeModel, forKey: "activeModel") }
    }

    /// 界面需要观察的变化点，UserDefaults 本身不参与 SwiftUI 的依赖追踪。
    var webSearchKind: String {
        didSet {
            UserDefaults.standard.set(webSearchKind, forKey: "webSearchKind")
            refreshCapabilityFlags()
        }
    }

    /// 三个"功能是否可用"的布尔。
    ///
    /// 它们原本是计算属性，每次求值都要读钥匙串；而 ChatView 的 body 在流式时
    /// 每秒重算约 30 次，等于每秒 90 次 SecItemCopyMatching，是明确的掉帧源。
    /// 改成存储属性 + 在配置变更处显式刷新。
    private(set) var webSearchReady = false
    private(set) var imageGenerationReady = false
    private(set) var documentParsingReady = false

    func refreshCapabilityFlags() {
        webSearchReady = makeWebSearchProvider() != nil
        imageGenerationReady = !imageAPIKey.isEmpty && !imageSettings.model.isEmpty
        documentParsingReady = makeDocumentRecognizer() != nil
    }

    /// 以下三项是从 UserDefaults 搬进 @Observable 的。
    ///
    /// 以前它们是没有观察能力的计算属性 + 一个没人读的 `*Revision` 计数器：
    /// 改了设置界面不会重绘，因为 SwiftUI 观察不到 UserDefaults。
    /// 真正的修法是把它们变成存储属性，而不是加计数器。
    var imageSettings: ImageProviderSettings {
        didSet {
            let defaults = UserDefaults.standard
            defaults.set(imageSettings.family.rawValue, forKey: "imageProviderFamily")
            defaults.set(imageSettings.baseURL, forKey: "imageProviderBaseURL")
            defaults.set(imageSettings.model, forKey: "imageProviderModel")
            refreshCapabilityFlags()
        }
    }

    var searchMode: WebSearchMode {
        didSet { UserDefaults.standard.set(searchMode.rawValue, forKey: "webSearchMode") }
    }

    var documentPurpose: DocumentParsingPurpose {
        didSet {
            UserDefaults.standard.set(documentPurpose.rawValue, forKey: "documentPurpose")
            refreshCapabilityFlags()
        }
    }

    /// 是否显示思维链、检索动作等中间过程。
    var showInternals: Bool {
        didSet { UserDefaults.standard.set(showInternals, forKey: "showInternals") }
    }

    /// DEBUG：启动后自动发送的一句话（模拟器无法用脚本输入）。
    var pendingAutoSend: String?

    /// 从厂商拉到的模型列表（内存缓存）。切换厂商时清空。
    private(set) var availableModels: [ModelInfo] = []
    private(set) var isLoadingModels = false
    private(set) var modelFetchError: String?

    /// 拉取当前厂商的模型列表。打开模型气泡时按需调用，不在启动时白花一次请求。
    func refreshModels() async {
        guard let profile = activeProfile, !isLoadingModels else { return }
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            availableModels = try await ModelCatalog.list(
                profile: profile,
                apiKey: apiKey(for: profile)
            )
            modelFetchError = nil
        } catch let failure as LlmFailure {
            modelFetchError = "\(failure.code.rawValue)：\(failure.message)"
        } catch {
            modelFetchError = error.localizedDescription
        }
    }

    /// 思考强度（持久化）。nil = 不指定，由厂商默认。
    var reasoning: ReasoningEffort? {
        didSet {
            UserDefaults.standard.set(reasoning?.rawValue, forKey: "reasoningEffort")
            chat?.reasoning = reasoning
        }
    }

    /// 会话抽屉是否展开。放在外壳层，抽屉才能盖住导航栏。
    var showSessionDrawer = false

    /// 生成中发送消息的语义：关闭 / 插话 / 排队。两者互斥，由这里强制。
    var streamingInput: ChatViewModel.StreamingInputMode {
        didSet {
            UserDefaults.standard.set(streamingInput.rawValue, forKey: "streamingInput")
            chat?.streamingInputMode = streamingInput
        }
    }

    var interjectEnabled: Bool { streamingInput == .interject }
    var queueEnabled: Bool { streamingInput == .queue }

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
        // 两个目录都建不出来时不能直接崩：用户至少还能纯文本对话，
        // 崩溃则什么也做不了。存图失败的提示在调用点给出。
        attachments = (try? AttachmentStore(
            root: databaseURL.deletingLastPathComponent().appendingPathComponent("Attachments")
        )) ?? (try? AttachmentStore(
            root: FileManager.default.temporaryDirectory.appendingPathComponent("Attachments")
        ))
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
        reasoning = UserDefaults.standard.string(forKey: "reasoningEffort")
            .flatMap(ReasoningEffort.init(rawValue:))
        streamingInput = ChatViewModel.StreamingInputMode(
            rawValue: UserDefaults.standard.string(forKey: "streamingInput") ?? ""
        ) ?? .off
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
        let defaults = UserDefaults.standard
        imageSettings = ImageProviderSettings(
            family: defaults.string(forKey: "imageProviderFamily")
                .flatMap(ProviderFamily.init(rawValue:)) ?? .openAICompatible,
            baseURL: defaults.string(forKey: "imageProviderBaseURL")
                ?? ImageProviderSettings.default.baseURL,
            model: defaults.string(forKey: "imageProviderModel")
                ?? ImageProviderSettings.default.model
        )
        searchMode = WebSearchMode(
            rawValue: defaults.string(forKey: "webSearchMode") ?? ""
        ) ?? .deepResearch
        documentPurpose = DocumentParsingPurpose(
            rawValue: defaults.string(forKey: "documentPurpose") ?? ""
        ) ?? .textRecognition
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
        refreshCapabilityFlags()

        // didSet 只在用户改开关时触发；启动时要把已存的值真正应用到编排器上。
        await orchestrator.setPolicy(autoCompactionEnabled ? .default : nil)

        // 没有任何厂商时不建会话：RootView 靠 "无会话且无厂商" 判定首次引导，
        // 先建会话会让引导一闪而过。
        if !profiles.isEmpty {
            // 联调时强制开新会话：必须在 ensureSession 之前决定，
            // 否则视图会先用恢复的会话渲染一次，自动发送就落到旧会话里。
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-newSession") {
                await startNewSession()
            } else {
                await ensureSession()
            }
            #else
            await ensureSession()
            #endif
            await pruneEmptySessions()
        }
        await pruneOrphanAttachments()
        #if DEBUG
        await applyDevKeysIfRequested()
        await seedDemoConversationIfRequested()
        let args = ProcessInfo.processInfo.arguments
        // 模拟"引导页刚添加完厂商"这一步，用来复现空转圈。
        if args.contains("-addProvider") {
            await save(
                profile: ProviderProfile.openAICompatible(
                    id: "simtest",
                    name: "Sim Test",
                    baseURL: "https://api.openai.com/v1",
                    capabilities: Capabilities(vision: true, reasoning: true, streamUsage: true)
                ),
                apiKey: "sk-sim"
            )
        }
        if let index = args.firstIndex(of: "-autoSend"), index + 1 < args.count {
            pendingAutoSend = args[index + 1]
        }
        if args.contains("-autoSearch") {
            chat?.webSearchEnabled = true
        }
        if args.contains("-autoResearch") {
            searchMode = .deepResearch
        }
        if args.contains("-autoQuickSearch") {
            searchMode = .quick
        }
        if args.contains("-autoImage") {
            chat?.setImageMode(true)
        }
        // 模拟器应用能读宿主机绝对路径，方便联调附件链路。
        if let index = args.firstIndex(of: "-autoDocument"), index + 1 < args.count,
           let data = FileManager.default.contents(atPath: args[index + 1]) {
            let name = URL(fileURLWithPath: args[index + 1]).lastPathComponent
            chat?.attachDocument(name: name, data: data)
        }
        if let index = args.firstIndex(of: "-autoReasoning"), index + 1 < args.count {
            reasoning = ReasoningEffort(rawValue: args[index + 1])
        }
        if args.contains("-interject") {
            streamingInput = .interject
            chat?.streamingInputMode = .interject
        }
        // 联调插话：等首轮开始流式后，再塞一句话进去。
        if let index = args.firstIndex(of: "-autoInterject"), index + 1 < args.count {
            let text = args[index + 1]
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                _ = self?.chat?.interject(text)
            }
        }
        if let index = args.firstIndex(of: "-autoQueue"), index + 1 < args.count {
            let text = args[index + 1]
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(6))
                _ = self?.chat?.enqueue(text)
            }
        }
        if ProcessInfo.processInfo.arguments.contains("-queue") {
            streamingInput = .queue
            chat?.streamingInputMode = .queue
        }
        if ProcessInfo.processInfo.arguments.contains("-fakeStreaming") {
            let draft = ProcessInfo.processInfo.arguments.contains("-withDraft") ? "换个角度，别只讲发布" : ""
            chat?.debugEnterStreaming(draft: draft)
        }
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
                    baseURL: "https://api.openai.com/v1",
                    capabilities: Capabilities(vision: true, reasoning: true, streamUsage: true)
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
           let ref = try? await attachments?.save(normalized) {
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

        // 恢复最近一次**有内容**的会话。以前这里无条件新建，
        // 结果每次启动都换一个空会话，历史永远接不上。
        let recent = (try? await store.sessions()) ?? []
        for session in recent {
            let projection = try? await store.projection(for: session.id)
            if let projection, !projection.messages.isEmpty {
                await open(session: session)
                return
            }
        }
        await startNewSession()
    }

    /// 清掉没有任何事件、标题仍是"新对话"的空会话。
    /// 以前每次启动都会留一个，列表很快就全是空壳。
    func pruneEmptySessions() async {
        guard let recent = try? await store.sessions() else { return }
        for session in recent where session.title == "新对话" {
            guard session.id != currentSession?.id else { continue }
            guard let projection = try? await store.projection(for: session.id) else { continue }
            if projection.messages.isEmpty {
                try? await store.delete(session.id)
            }
        }
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
        model.streamingInputMode = streamingInput
        model.reasoning = reasoning
        await model.load()
        // await 期间用户可能已经切到别的会话；这时不能再覆盖 chat，
        // 否则界面显示的会话与 currentSession 会对不上（导出/统计会取错）。
        guard currentSession?.id == session.id else { return }
        chat = model
    }

    #if DEBUG
    /// 从 gitignored 的 `DevKeys.plist` 灌入真实密钥，便于联调。
    ///
    /// 只在 DEBUG + 启动参数 `-devKeys` 时启用；Release 构建里整段代码不存在。
    func applyDevKeysIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-devKeys"),
              let path = Bundle.main.path(forResource: "DevKeys", ofType: "plist"),
              let raw = NSDictionary(contentsOfFile: path) as? [String: Any]
        else { return }

        func value(_ key: String) -> String? {
            guard let text = raw[key] as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // 对话厂商
        if let key = value("chatKey") {
            let family = value("chatFamily").flatMap(ProviderFamily.init(rawValue:)) ?? .openAICompatible
            let baseURL = value("chatBaseURL") ?? "https://api.openai.com/v1"
            let model = value("chatModel") ?? ""
            if let profile = ProviderDraft(
                id: "dev",
                name: "Dev \(family.rawValue)",
                family: family,
                baseURL: baseURL,
                apiKey: key,
                isNew: true,
                serverToolsEnabled: family == .anthropic
            ).profile() {
                do {
                    try keychain.set(key, for: Keychain.account(for: profile.id))
                    try await store.saveProfile(profile)
                    activeProfileID = profile.id
                    if !model.isEmpty { activeModel = model }
                } catch {
                    bootError = "DevKeys 写入厂商失败：\(error)"
                }
            }
        }

        // DeepSeek：检索与 OCR 共用
        if let key = value("deepseekKey") {
            try? keychain.set(key, for: Keychain.account(for: Self.searchAccount(for: .deepseek)))
            webSearchKind = WebSearchKind.deepseek.rawValue
        }

        // 生图
        if let key = value("imageKey") {
            try? keychain.set(key, for: Keychain.account(for: "imageprovider"))
            imageSettings = ImageProviderSettings(
                family: .openAICompatible,
                baseURL: value("imageBaseURL") ?? ImageProviderSettings.default.baseURL,
                model: value("imageModel") ?? ImageProviderSettings.default.model
            )
        }

        await reloadProviders()
        refreshCapabilityFlags()
    }
    #endif

    /// 进入后台：正在生成时申请后台时间，并标记这一轮可能被系统中断。
    func didEnterBackground() {
        guard let chat else { return }
        chat.markBackgrounded()
        // 只要这一轮还开着就申请后台时间，不依赖 isStreaming 的瞬时值。
        guard chat.isStreaming else { return }
        backgroundKeeper.begin(reason: "turn")
    }

    /// 回到前台：还回后台时间；若这一轮已经死掉，给它两秒收尾再判定为中断。
    func willEnterForeground() {
        backgroundKeeper.end()
        chat?.recoverFromBackground()
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
        guard let attachments else { return }
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
                refreshCapabilityFlags()
            }
            await reloadProviders()
            if activeProfileID == nil { activeProfileID = profile.id }
            if activeModel.isEmpty { activeModel = profile.defaultModel }

            // 引导流程里没有会话：这里不补，界面会停在"有厂商但没 chat"的空转圈，
            // 只能杀进程重开。之前的症状就是这么来的。
            await ensureSession()
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
        guard let kind = WebSearchKind(rawValue: webSearchKind) else { return "" }
        return searchKey(for: kind)
    }

    func setWebSearchKey(_ value: String) {
        if value.isEmpty {
            keychain.delete(Keychain.account(for: "websearch"))
        } else {
            let kind = WebSearchKind(rawValue: webSearchKind) ?? .off
            try? keychain.set(value, for: Keychain.account(for: Self.searchAccount(for: kind)))
            refreshCapabilityFlags()
        }
    }

    func apiKey(for profile: ProviderProfile) -> String {
        keychain.get(Keychain.account(for: profile.id)) ?? ""
    }
}

extension AppEnvironment {
    /// 用模型名前缀判断"这个名字是不是这家的"，只用于切换厂商时的兜底重置。
    static func modelHint(for family: ProviderFamily) -> String {
        switch family {
        case .anthropic: "claude"
        case .gemini: "gemini"
        case .openAIResponses, .openAICompatible: "gpt"
        }
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
    func makeDocumentRecognizer() -> (any DocumentRecognizer)? {
        guard WebSearchKind(rawValue: webSearchKind) == .deepseek else { return nil }
        // OCR 是 DeepSeek 的工具接口，只认 DeepSeek 的 Key。
        let key = searchKey(for: .deepseek)
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
