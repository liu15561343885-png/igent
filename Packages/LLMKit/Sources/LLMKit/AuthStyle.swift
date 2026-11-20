import CoreKit
import Foundation

/// 鉴权方式。厂商差异里最容易硬编码的一项，因此做成声明式。
///
/// 四种常见形态：
/// - `Authorization: Bearer <key>`（OpenAI、DeepSeek、OpenRouter…）
/// - `x-api-key: <key>`（Anthropic）
/// - `api-key: <key>`（Azure OpenAI）
/// - `x-goog-api-key: <key>`（Gemini）
public struct AuthStyle: Sendable, Equatable, Hashable, Codable {
    public enum Placement: String, Codable, Sendable {
        case header
        case query
    }

    public var placement: Placement
    public var field: String
    public var prefix: String?

    public init(placement: Placement, field: String, prefix: String? = nil) {
        self.placement = placement
        self.field = field
        self.prefix = prefix
    }

    public static let bearer = AuthStyle(placement: .header, field: "Authorization", prefix: "Bearer ")

    public static func apiKey(header: String) -> AuthStyle {
        AuthStyle(placement: .header, field: header)
    }

    /// 不推荐：密钥会进日志与代理记录。仅为兼容个别端点保留。
    public static func queryKey(param: String) -> AuthStyle {
        AuthStyle(placement: .query, field: param)
    }
}

enum RequestAuth {
    static func apply(_ style: AuthStyle, apiKey: String, to request: inout URLRequest) {
        switch style.placement {
        case .header:
            request.setValue((style.prefix ?? "") + apiKey, forHTTPHeaderField: style.field)
        case .query:
            guard let url = request.url,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { return }
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: style.field, value: apiKey))
            components.queryItems = items
            request.url = components.url
        }
    }
}
