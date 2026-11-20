import CoreKit
import Foundation
import XCTest
@testable import WebSeamKit

final class DeepSeekSearchTests: XCTestCase {
    func testRequestShape() throws {
        let provider = DeepSeekSearchProvider(apiKey: "sk-x")
        let request = provider.makeRequest(query: "DeepSeek V4", maxResults: 5)

        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: body).objectValue)
        XCTAssertEqual(json["query"], .string("DeepSeek V4"))
        XCTAssertEqual(json["count"], .number(5))
        XCTAssertEqual(json["need_content"], .bool(false))
    }

    /// count 上限 50，超出会被服务端 400。
    func testCountIsClamped() throws {
        let provider = DeepSeekSearchProvider(apiKey: "k")
        let request = provider.makeRequest(query: "x", maxResults: 999)
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: body).objectValue)
        XCTAssertEqual(json["count"], .number(50))
    }

    func testParsesResults() throws {
        let json = """
        {"results":[
          {"rerank_score":2.4,"title":"标题","url":"https://a.test/1",
           "snippet":"短摘要","summary":"长摘要，给模型读的内容。",
           "content":"","site_name":"站点","date":"2026-06-01T00:00:00+00:00","authority":3}
        ]}
        """
        let result = try DeepSeekSearchProvider.parse(Data(json.utf8))
        XCTAssertEqual(result.sources.count, 1)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(source.url.absoluteString, "https://a.test/1")
        XCTAssertEqual(source.title, "标题")
        // 进上下文的是 summary，不是 snippet
        XCTAssertEqual(source.snippet, "长摘要，给模型读的内容。")
        XCTAssertEqual(source.publishedAt, "2026-06-01T00:00:00+00:00")
    }

    func testFallsBackToSnippetWhenSummaryMissing() throws {
        let json = #"{"results":[{"title":"t","url":"https://a.test","snippet":"短"}]}"#
        let result = try DeepSeekSearchProvider.parse(Data(json.utf8))
        XCTAssertEqual(result.sources.first?.snippet, "短")
    }

    func testEmptyResultsIsNotAnError() throws {
        let result = try DeepSeekSearchProvider.parse(Data(#"{"results":[]}"#.utf8))
        XCTAssertTrue(result.sources.isEmpty)
    }

    func testErrorBodyThrows() {
        let json = #"{"error":{"message":"invalid query","type":"invalid_request_error"}}"#
        XCTAssertThrowsError(try DeepSeekSearchProvider.parse(Data(json.utf8)))
    }

    // MARK: - Fetch

    func testFetchRequestShape() throws {
        let provider = DeepSeekFetchProvider(apiKey: "sk-y")
        let request = provider.makeRequest(url: URL(string: "https://example.com/a")!)
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/fetch")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: body).objectValue)
        XCTAssertEqual(json["url"], .string("https://example.com/a"))
    }

    func testFetchParsesMarkdown() throws {
        // 用 ## 包裹：Markdown 里的 "# 标题" 会让单 # 的原始字符串提前结束。
        let json = ##"{"title":"示例页","content":"# 标题\n\n正文内容"}"##
        let page = try DeepSeekFetchProvider.parse(
            Data(json.utf8),
            requested: URL(string: "https://example.com/a")!
        )
        XCTAssertEqual(page.title, "示例页")
        XCTAssertTrue(page.text.contains("# 标题"))
        XCTAssertEqual(page.url.absoluteString, "https://example.com/a")
    }

    func testFetchRejectsEmptyContent() {
        XCTAssertThrowsError(
            try DeepSeekFetchProvider.parse(
                Data(#"{"title":"t","content":"   "}"#.utf8),
                requested: URL(string: "https://a.test")!
            )
        )
    }
}
