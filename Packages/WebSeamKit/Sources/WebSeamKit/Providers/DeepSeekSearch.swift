import CoreKit
import Foundation

/// DeepSeek Search API（`POST /v1/tools/search`）。
///
/// 比通用搜索后端更适合喂给模型的原因：
/// - 每条结果带 `summary`（600–800 字，专门给模型读）和 `authority`（权威度 0–4）；
/// - 支持 `site:` `after:` `lang:` 这类查询算符，原样透传；
/// - 支持 `need_content`，一次请求就能带回正文，省掉抓取。
public struct DeepSeekSearchProvider: WebSearchProvider {
    public let id = "deepseek"
    public let apiKey: String
    /// 是否让服务端直接带回正文。开了就不用再走抓取。
    public var needContent: Bool
    private let session: URLSession

    public init(
        apiKey: String,
        needContent: Bool = false,
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.needContent = needContent
        self.session = session
    }

    func makeRequest(query: String, maxResults: Int) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/tools/search")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: JSONValue] = [
            "query": .string(query),
            "count": .number(Double(min(max(maxResults, 1), 50))),
            "need_content": .bool(needContent)
        ]
        // count 上限 50，超出会被 400 拒绝。
        body["query"] = .string(String(query.prefix(128)))
        request.httpBody = try? JSONEncoder().encode(JSONValue.object(body))
        return request
    }

    static func parse(_ data: Data) throws -> WebSearchResult {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            throw WebError.emptyBody
        }
        if let error = object["error"]?.objectValue {
            throw WebError.message(error["message"]?.stringValue ?? "search failed")
        }

        let results = object["results"]?.arrayValue ?? []
        let sources: [WebSource] = results.compactMap { item in
            guard let entry = item.objectValue,
                  let urlString = entry["url"]?.stringValue,
                  let url = URL(string: urlString)
            else { return nil }

            // summary 是给模型读的长摘要，snippet 是给界面看的短摘要。
            // 我们的 WebSource.snippet 会进上下文，所以优先取 summary。
            let summary = entry["summary"]?.stringValue ?? ""
            let snippet = entry["snippet"]?.stringValue
            return WebSource(
                url: url,
                title: entry["title"]?.stringValue,
                snippet: summary.isEmpty ? snippet : summary,
                publishedAt: entry["date"]?.stringValue
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

/// DeepSeek Fetch API（`POST /v1/tools/fetch`）：直接返回 Markdown。
///
/// 有它就不需要自己写 HTML 抽取了——服务端已经做了正文提取。
public struct DeepSeekFetchProvider: WebFetchProvider {
    public let apiKey: String
    private let session: URLSession

    public init(apiKey: String, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/v1/tools/fetch")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(
            JSONValue.object(["url": .string(url.absoluteString)])
        )
        return request
    }

    static func parse(_ data: Data, requested: URL) throws -> WebPage {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = root.objectValue
        else {
            throw WebError.emptyBody
        }
        if let error = object["error"]?.objectValue {
            throw WebError.message(error["message"]?.stringValue ?? "fetch failed")
        }
        let content = object["content"]?.stringValue ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WebError.emptyBody
        }
        return WebPage(
            url: requested,
            title: object["title"]?.stringValue,
            text: content
        )
    }

    public func fetch(_ url: URL) async throws -> WebPage {
        let (data, response) = try await session.data(for: makeRequest(url: url))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebError.badStatus(http.statusCode)
        }
        return try Self.parse(data, requested: url)
    }
}
