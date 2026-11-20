import CoreKit
import Foundation
import XCTest
@testable import WebSeamKit

final class HTMLTextExtractorTests: XCTestCase {
    func testStripsScriptAndStyle() {
        let html = """
        <html><head><title>标题</title><style>.a{color:red}</style></head>
        <body><script>alert(1)</script><p>正文第一段</p></body></html>
        """
        let result = HTMLTextExtractor.extract(html)
        XCTAssertEqual(result.title, "标题")
        XCTAssertFalse(result.text.contains("alert"))
        XCTAssertFalse(result.text.contains("color:red"))
        XCTAssertTrue(result.text.contains("正文第一段"))
    }

    func testBlockTagsBecomeNewlines() {
        let html = "<p>第一段</p><p>第二段</p>"
        XCTAssertEqual(HTMLTextExtractor.extract(html).text, "第一段\n第二段")
    }

    func testDecodesEntities() {
        let html = "<p>A &amp; B &lt;tag&gt; &quot;quoted&quot; &#39;s&#39;</p>"
        XCTAssertEqual(HTMLTextExtractor.extract(html).text, "A & B <tag> \"quoted\" 's'")
    }

    func testCollapsesWhitespace() {
        let html = "<p>很多    空格</p>\n\n\n<p>下一段</p>"
        XCTAssertEqual(HTMLTextExtractor.extract(html).text, "很多 空格\n\n下一段")
    }

    func testMissingTitle() {
        XCTAssertNil(HTMLTextExtractor.extract("<p>无标题</p>").title)
    }
}

// MARK: - 搜索供应商解析

final class SearchProviderTests: XCTestCase {
    func testTavilyParse() throws {
        let json = """
        {"answer":"简要答案","results":[
          {"title":"一","url":"https://a.test/1","content":"片段一"},
          {"title":"二","url":"https://b.test/2","content":"片段二"}
        ]}
        """
        let result = try TavilySearchProvider.parse(Data(json.utf8))
        XCTAssertEqual(result.answer, "简要答案")
        XCTAssertEqual(result.sources.map(\.url.absoluteString), ["https://a.test/1", "https://b.test/2"])
        XCTAssertEqual(result.sources.first?.snippet, "片段一")
    }

    func testTavilyRequestShape() throws {
        let provider = TavilySearchProvider(apiKey: "tvly-x")
        let request = provider.makeRequest(query: "今天天气", maxResults: 3)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tvly-x")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: body).objectValue)
        XCTAssertEqual(json["query"], .string("今天天气"))
        XCTAssertEqual(json["max_results"], .number(3))
    }

    func testBraveParse() throws {
        let json = """
        {"web":{"results":[
          {"title":"一","url":"https://a.test/1","description":"描述一"}
        ]}}
        """
        let result = try BraveSearchProvider.parse(Data(json.utf8))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.snippet, "描述一")
        XCTAssertNil(result.answer, "Brave 不给聚合答案")
    }

    func testBraveRequestShape() throws {
        let provider = BraveSearchProvider(apiKey: "brave-x")
        let request = provider.makeRequest(query: "swift 并发", maxResults: 4)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Subscription-Token"), "brave-x")
        XCTAssertTrue(request.url?.absoluteString.contains("count=4") ?? false)
    }

    /// 缺 url 的条目要跳过，不能产出半截来源。
    func testEntriesWithoutURLAreSkipped() throws {
        let json = #"{"results":[{"title":"坏"},{"title":"好","url":"https://ok.test"}]}"#
        let result = try TavilySearchProvider.parse(Data(json.utf8))
        XCTAssertEqual(result.sources.count, 1)
    }
}

// MARK: - 证据拼装

private struct StubSearch: WebSearchProvider {
    var id = "stub"
    var result: WebSearchResult
    var error: Error?

    func search(query: String, maxResults: Int) async throws -> WebSearchResult {
        if let error { throw error }
        return result
    }
}

private struct StubFetcher: WebFetchProvider {
    var pages: [String: WebPage]
    var failing: Set<String> = []

    func fetch(_ url: URL) async throws -> WebPage {
        if failing.contains(url.absoluteString) { throw WebError.badStatus(500) }
        guard let page = pages[url.absoluteString] else { throw WebError.emptyBody }
        return page
    }
}

final class WebContextBuilderTests: XCTestCase {
    private func source(_ index: Int) -> WebSource {
        WebSource(url: URL(string: "https://site\(index).test/a")!, title: "站点\(index)", snippet: "摘要\(index)")
    }

    func testBuildsNumberedDigest() async {
        let search = StubSearch(result: WebSearchResult(sources: [source(1), source(2)]))
        let fetcher = StubFetcher(pages: [
            "https://site1.test/a": WebPage(url: URL(string: "https://site1.test/a")!, title: "站点1", text: "正文一"),
            "https://site2.test/a": WebPage(url: URL(string: "https://site2.test/a")!, title: "站点2", text: "正文二")
        ])

        let outcome = await WebContextBuilder().build(query: "测试", search: search, fetcher: fetcher)
        XCTAssertTrue(outcome.evidence.digest.contains("[1] 站点1 — https://site1.test/a"))
        XCTAssertTrue(outcome.evidence.digest.contains("正文一"))
        XCTAssertTrue(outcome.evidence.digest.contains("[2] 站点2"))
        XCTAssertEqual(outcome.failedFetches, 0)
        XCTAssertEqual(outcome.evidence.sources.count, 2)
    }

    /// 抓取失败时退回搜索摘要，来源仍保留。
    func testFailedFetchFallsBackToSnippet() async {
        let search = StubSearch(result: WebSearchResult(sources: [source(1)]))
        let fetcher = StubFetcher(pages: [:], failing: ["https://site1.test/a"])

        let outcome = await WebContextBuilder().build(query: "测试", search: search, fetcher: fetcher)
        XCTAssertEqual(outcome.failedFetches, 1)
        XCTAssertTrue(outcome.evidence.digest.contains("摘要1"))
        XCTAssertEqual(outcome.evidence.sources.count, 1)
    }

    func testLimitsPageCount() async {
        let sources = (1...5).map { source($0) }
        let search = StubSearch(result: WebSearchResult(sources: sources))
        let fetcher = StubFetcher(pages: [:])

        let outcome = await WebContextBuilder(maxPages: 3).build(query: "测试", search: search, fetcher: fetcher)
        XCTAssertEqual(outcome.evidence.sources.count, 3)
        XCTAssertTrue(outcome.evidence.truncated)
    }

    func testProviderAnswerIsPrepended() async {
        let search = StubSearch(result: WebSearchResult(answer: "一句话结论", sources: [source(1)]))
        let fetcher = StubFetcher(pages: [:])
        let outcome = await WebContextBuilder().build(query: "测试", search: search, fetcher: fetcher)
        XCTAssertTrue(outcome.evidence.digest.hasPrefix("检索摘要：一句话结论"))
    }

    /// 搜索失败也要产出可用的证据对象（内容是失败原因），不能抛崩。
    func testSearchFailureProducesEmptyEvidence() async {
        let search = StubSearch(result: WebSearchResult(sources: []), error: WebError.badStatus(401))
        let outcome = await WebContextBuilder().build(query: "测试", search: search, fetcher: StubFetcher(pages: [:]))
        XCTAssertTrue(outcome.evidence.sources.isEmpty)
        XCTAssertTrue(outcome.evidence.digest.contains("检索失败"))
    }

    func testLongPageIsTruncated() async {
        let longText = String(repeating: "字", count: 500)
        let search = StubSearch(result: WebSearchResult(sources: [source(1)]))
        let fetcher = StubFetcher(pages: [
            "https://site1.test/a": WebPage(url: URL(string: "https://site1.test/a")!, title: "站点1", text: longText)
        ])
        let outcome = await WebContextBuilder(maxCharactersPerPage: 100)
            .build(query: "测试", search: search, fetcher: fetcher)
        XCTAssertTrue(outcome.evidence.digest.contains("…"))
        XCTAssertLessThan(outcome.evidence.digest.count, longText.count)
    }
}
