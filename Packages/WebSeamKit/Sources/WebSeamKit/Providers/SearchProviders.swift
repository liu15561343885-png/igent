import CoreKit
import Foundation

/// Tavily 搜索。
///
/// 请求：`POST https://api.tavily.com/search`
/// 鉴权：`Authorization: Bearer tvly-...`
/// 响应：`{ "answer": "...", "results": [{ "title", "url", "content" }] }`
public struct TavilySearchProvider: WebSearchProvider {
    public let id = "tavily"
    public let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func makeRequest(query: String, maxResults: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: JSONValue] = [
            "query": .string(query),
            "max_results": .number(Double(maxResults)),
            "include_answer": .bool(true),
            "search_depth": .string("basic")
        ]
        request.httpBody = try? JSONEncoder().encode(JSONValue.object(body))
        return request
    }

    static func parse(_ data: Data) throws -> WebSearchResult {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            throw WebError.emptyBody
        }
        let answer = object["answer"]?.stringValue
        let results = object["results"]?.arrayValue ?? []

        let sources: [WebSource] = results.compactMap { item in
            guard let entry = item.objectValue,
                  let urlString = entry["url"]?.stringValue,
                  let url = URL(string: urlString)
            else { return nil }
            return WebSource(
                url: url,
                title: entry["title"]?.stringValue,
                snippet: entry["content"]?.stringValue
            )
        }
        return WebSearchResult(answer: answer, sources: sources)
    }

    public func search(query: String, maxResults: Int) async throws -> WebSearchResult {
        let (data, response) = try await session.data(for: makeRequest(query: query, maxResults: maxResults))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebError.badStatus(http.statusCode)
        }
        return try Self.parse(data)
    }
}

/// Brave Web Search。
///
/// 请求：`GET https://api.search.brave.com/res/v1/web/search?q=...&count=N`
/// 鉴权：`X-Subscription-Token: ...`
/// 响应：`{ "web": { "results": [{ "title", "url", "description" }] } }`
public struct BraveSearchProvider: WebSearchProvider {
    public let id = "brave"
    public let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func makeRequest(query: String, maxResults: Int) -> URLRequest {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(maxResults))
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiKey, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }

    static func parse(_ data: Data) throws -> WebSearchResult {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            throw WebError.emptyBody
        }
        let results = object["web"]?.objectValue?["results"]?.arrayValue ?? []

        let sources: [WebSource] = results.compactMap { item in
            guard let entry = item.objectValue,
                  let urlString = entry["url"]?.stringValue,
                  let url = URL(string: urlString)
            else { return nil }
            return WebSource(
                url: url,
                title: entry["title"]?.stringValue,
                snippet: entry["description"]?.stringValue
            )
        }
        return WebSearchResult(sources: sources)
    }

    public func search(query: String, maxResults: Int) async throws -> WebSearchResult {
        let (data, response) = try await session.data(for: makeRequest(query: query, maxResults: maxResults))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebError.badStatus(http.statusCode)
        }
        return try Self.parse(data)
    }
}
