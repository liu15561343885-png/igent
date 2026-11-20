import AgentKit
import CoreKit
import Foundation
import LLMKit
import Observation
import StorageKit

/// 应用级依赖装配。只在启动时创建一次。
@MainActor
@Observable
final class AppEnvironment {
    let store: SessionStore
    let runtime: LlmRuntime
    let orchestrator: TurnOrchestrator
    let keychain: Keychain
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

    var activeProfile: ProviderProfile? {
        profiles.first { $0.id == activeProfileID }
    }

    init(databaseURL: URL) {
        keychain = Keychain()
        runtime = LlmRuntime()

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

        activeProfileID = UserDefaults.standard.string(forKey: "activeProfileID")
        activeModel = UserDefaults.standard.string(forKey: "activeModel") ?? ""
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
        await ensureSession()
        #if DEBUG
        await seedDemoConversationIfRequested()
        #endif
    }

    #if DEBUG
    /// 仅用于模拟器截图与界面迭代：`-seedDemoConversation` 启动参数会灌一段示例对话。
    private func seedDemoConversationIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains("-seedDemoConversation") else { return }

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
            (.assistant, "可以这样改：「该方案整体可行，主要顾虑在于成本偏高。」"),
            (.user, "再短一点"),
            (.assistant, "「方案可行，唯成本偏高。」")
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
            try? await store.append(event, to: session.id, surfaceOp: .append)
        }
        await open(session: session)
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
        currentSession = session
        let model = ChatViewModel(sessionID: session.id, store: store, orchestrator: orchestrator)
        await model.load()
        chat = model
    }

    func delete(session: SessionSummary) async {
        try? await store.delete(session.id)
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
            let adapter = AdapterFactory.make(profile: profile, apiKey: key, transport: transport)
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
