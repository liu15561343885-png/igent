import CoreKit
import Foundation

public struct WebSearchResult: Sendable, Equatable {
    /// 供应商生成的摘要（Perplexity 一类会给），可能为空。
    public var answer: String?
    public var sources: [WebSource]

    public init(answer: String? = nil, sources: [WebSource]) {
        self.answer = answer
        self.sources = sources
    }
}

/// 搜索后端。一次一个查询，多条查询由上层拆。
public protocol WebSearchProvider: Sendable {
    var id: String { get }
    func search(query: String, maxResults: Int) async throws -> WebSearchResult
}

/// 抓回来的网页正文。
public struct WebPage: Sendable, Equatable {
    public var url: URL
    public var title: String?
    public var text: String

    public init(url: URL, title: String?, text: String) {
        self.url = url
        self.title = title
        self.text = text
    }
}

public protocol WebFetchProvider: Sendable {
    func fetch(_ url: URL) async throws -> WebPage
}

public enum WebError: Error, Equatable {
    case badStatus(Int)
    /// 服务端在响应体里给出的错误信息（这些 API 常以 200 + error 字段返回业务错误）。
    case message(String)
    case unsupportedContentType(String)
    case tooLarge
    case emptyBody
}
