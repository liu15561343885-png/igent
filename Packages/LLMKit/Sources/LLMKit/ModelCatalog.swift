import CoreKit
import Foundation

public struct ModelInfo: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var displayName: String?
    public var contextWindow: Int?

    public init(id: String, displayName: String? = nil, contextWindow: Int? = nil) {
        self.id = id
        self.displayName = displayName
        self.contextWindow = contextWindow
    }
}

public enum CatalogError: Error, Equatable {
    case invalidURL(String)
    case unexpectedShape(String)
    case badStatus(Int)
}

/// 从厂商端点拉取可用模型列表。
///
/// 目的很实际：少让用户手打模型名。手打错一个字符，报错会是 404，看起来像网络问题。
public enum ModelCatalog {
    public static func makeRequest(
        profile: ProviderProfile,
        apiKey: String
    ) throws -> URLRequest {
        guard let url = profile.url(forPath: "/models") else {
            throw CatalogError.invalidURL(profile.baseURL.absoluteString)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        RequestAuth.apply(profile.auth, apiKey: apiKey, to: &request)

        if profile.family == .anthropic {
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        for (key, value) in profile.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    public static func parse(family: ProviderFamily, data: Data) throws -> [ModelInfo] {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            throw CatalogError.unexpectedShape(String(decoding: data.prefix(200), as: UTF8.self))
        }

        switch family {
        case .gemini:
            // { "models": [ { "name": "models/gemini-2.5-flash", "displayName": "...", "inputTokenLimit": N } ] }
            guard let models = object["models"]?.arrayValue else {
                throw CatalogError.unexpectedShape("缺少 models 数组")
            }
            return models.compactMap { entry -> ModelInfo? in
                guard let raw = entry.objectValue?["name"]?.stringValue else { return nil }
                let id = raw.hasPrefix("models/") ? String(raw.dropFirst("models/".count)) : raw
                return ModelInfo(
                    id: id,
                    displayName: entry.objectValue?["displayName"]?.stringValue,
                    contextWindow: entry.objectValue?["inputTokenLimit"]?.numberValue.map { Int($0) }
                )
            }

        case .openAICompatible, .openAIResponses, .anthropic:
            // { "data": [ { "id": "...", "display_name"/"name": "...", "context_length": N } ] }
            guard let items = object["data"]?.arrayValue else {
                throw CatalogError.unexpectedShape("缺少 data 数组")
            }
            return items.compactMap { entry -> ModelInfo? in
                guard let id = entry.objectValue?["id"]?.stringValue else { return nil }
                let name = entry.objectValue?["display_name"]?.stringValue
                    ?? entry.objectValue?["name"]?.stringValue
                let window = entry.objectValue?["context_length"]?.numberValue
                    ?? entry.objectValue?["context_window"]?.numberValue
                return ModelInfo(id: id, displayName: name, contextWindow: window.map { Int($0) })
            }
        }
    }

    /// 拉取并排序。排序按 id 字典序，保证每次展示稳定。
    public static func list(
        profile: ProviderProfile,
        apiKey: String,
        session: URLSession = .shared
    ) async throws -> [ModelInfo] {
        let request = try makeRequest(profile: profile, apiKey: apiKey)
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw LlmFailure.from(
                status: http.statusCode,
                body: String(decoding: data.prefix(1000), as: UTF8.self)
            )
        }
        return try parse(family: profile.family, data: data).sorted { $0.id < $1.id }
    }
}
