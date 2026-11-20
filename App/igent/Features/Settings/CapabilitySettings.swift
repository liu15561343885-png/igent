import CoreKit
import Foundation
import LLMKit
import StorageKit
import WebSeamKit

/// 联网检索的用户配置：用哪家、密钥在哪。
enum WebSearchKind: String, CaseIterable, Identifiable {
    case off
    case tavily
    case brave

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "关闭"
        case .tavily: "Tavily"
        case .brave: "Brave"
        }
    }
}

extension AppEnvironment {
    /// 网页检索的 provider。未配置密钥时返回 nil，界面据此禁用开关。
    func makeWebSearchProvider() -> (any WebSearchProvider)? {
        guard let kind = WebSearchKind(rawValue: webSearchKind), kind != .off else { return nil }
        let key = keychain.get(Keychain.account(for: "websearch")) ?? ""
        guard !key.isEmpty else { return nil }
        switch kind {
        case .tavily: return TavilySearchProvider(apiKey: key)
        case .brave: return BraveSearchProvider(apiKey: key)
        case .off: return nil
        }
    }

    var isWebSearchConfigured: Bool {
        makeWebSearchProvider() != nil
    }
}
