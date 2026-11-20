import AgentKit
import CoreKit
import Foundation
import LLMKit
import StorageKit
import WebSeamKit

/// 联网检索的用户配置：用哪家、密钥在哪。
enum WebSearchKind: String, CaseIterable, Identifiable {
    case off
    case deepseek
    case tavily
    case brave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .deepseek: "DeepSeek"
        case .tavily: "Tavily"
        case .brave: "Brave"
        }
    }
}

extension AppEnvironment {
    /// 检索密钥的钥匙串账号。按厂商分开存——共用一个槽位时，
    /// 从 Tavily 切到 Brave 会把 Tavily 的 Key 发给 Brave。
    static func searchAccount(for kind: WebSearchKind) -> String {
        "websearch." + kind.rawValue
    }

    /// 读取检索密钥：先找本厂商的槽位，再回退到旧的共用槽位（老版本存的位置）。
    func searchKey(for kind: WebSearchKind) -> String {
        if let scoped = keychain.get(Keychain.account(for: Self.searchAccount(for: kind))),
           !scoped.isEmpty {
            return scoped
        }
        return keychain.get(Keychain.account(for: "websearch")) ?? ""
    }

    /// 网页检索的 provider。未配置密钥时返回 nil，界面据此禁用开关。
    func makeWebSearchProvider() -> (any WebSearchProvider)? {
        guard let kind = WebSearchKind(rawValue: webSearchKind), kind != .off else { return nil }
        let key = searchKey(for: kind)
        guard !key.isEmpty else { return nil }
        switch kind {
        case .deepseek: return DeepSeekSearchProvider(apiKey: key)
        case .tavily: return TavilySearchProvider(apiKey: key)
        case .brave: return BraveSearchProvider(apiKey: key)
        case .off: return nil
        }
    }

    /// 抓取后端。用 DeepSeek 时走它的 Fetch API（直接返回 Markdown，
    /// 服务端已做正文抽取）；其他后端仍用本地 HTML 抽取。
    func makeWebFetchProvider() -> any WebFetchProvider {
        let kind = WebSearchKind(rawValue: webSearchKind) ?? .off
        if kind == .deepseek {
            let key = searchKey(for: .deepseek)
            if !key.isEmpty { return DeepSeekFetchProvider(apiKey: key) }
        }
        return HTTPFetcher()
    }
}

/// 联网检索的两种执行方式。
enum WebSearchMode: String, CaseIterable, Identifiable {
    /// 应用侧一次性检索：搜一次、抓前几页、把原文塞进上下文。
    case quick
    /// 深度调研：先让 DeepSeek 用服务端工具多跳检索，产出带编号的事实，再交给主模型回答。
    case deepResearch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "快速检索（原文注入）"
        case .deepResearch: "深度调研（DeepSeek 多跳）"
        }
    }
}

extension AppEnvironment {
    var searchMode: WebSearchMode {
        get {
            WebSearchMode(rawValue: UserDefaults.standard.string(forKey: "webSearchMode") ?? "")
                ?? .deepResearch
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "webSearchMode")
            searchModeRevision += 1
        }
    }

    /// 深度调研需要一个 DeepSeek 的 Anthropic 兼容端点 + 服务端工具。
    func makeWebResearch() -> WebResearch? {
        guard WebSearchKind(rawValue: webSearchKind) == .deepseek else { return nil }
        let key = keychain.get(Keychain.account(for: "websearch")) ?? ""
        guard !key.isEmpty else { return nil }

        let tools = [
            ServerToolRequest(wireType: "deepseek_web_search"),
            ServerToolRequest(wireType: "deepseek_read_url")
        ]
        let profile = ProviderProfile(
            id: "deepseek-research",
            name: "DeepSeek 调研",
            family: .anthropic,
            baseURL: URL(string: "https://api.deepseek.com/anthropic/v1")!,
            chatPath: "/messages",
            capabilities: Capabilities(
                vision: false,
                reasoning: true,
                streamUsage: true,
                systemStyle: .topLevel,
                defaultMaxTokens: 1500,
                contextWindow: 128_000,
                serverTools: tools
            ),
            auth: .apiKey(header: "x-api-key")
        )
        return WebResearch(
            adapter: AnthropicAdapter(profile: profile, apiKey: key),
            model: "deepseek-flash",
            serverTools: tools
        )
    }
}
