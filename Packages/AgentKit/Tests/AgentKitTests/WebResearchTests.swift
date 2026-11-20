import CoreKit
import Foundation
import LLMKit
import XCTest
@testable import AgentKit

private struct ResearchAdapter: LlmAdapter {
    let profile: ProviderProfile
    var blocks: [ContentBlock]
    var sendsTools: Box<[ServerToolRequest]>?

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ value: T) { self.value = value }
        var current: T { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ new: T) { lock.lock(); value = new; lock.unlock() }
    }

    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        sendsTools?.set(options.serverTools)
        return AsyncThrowingStream { continuation in
            for (index, block) in blocks.enumerated() {
                continuation.yield(.blockStart(index: index, type: block.type))
                continuation.yield(.blockEnd(index: index, block: block))
            }
            continuation.yield(.usage(TokenUsage(uncachedInputTokens: 120, outputTokens: 60)))
            continuation.yield(.finish(.stop, meta: nil))
            continuation.finish()
        }
    }
}

final class WebResearchTests: XCTestCase {
    private func searchCall(_ queries: [String]) -> ContentBlock {
        .providerBlock(ProviderBlock(
            type: "server_tool_use",
            payload: .object([
                "type": .string("server_tool_use"),
                "name": .string("deepseek_web_search"),
                "kind": .string("search"),
                "input": .object([
                    "action": .string("search"),
                    "queries": .array(queries.map { .string($0) })
                ])
            ])
        ))
    }

    private func searchResult(_ items: [(String, String)]) -> ContentBlock {
        .providerBlock(ProviderBlock(
            type: "web_search_tool_result",
            payload: .object([
                "type": .string("web_search_tool_result"),
                "content": .array(items.map { title, url in
                    .object(["title": .string(title), "url": .string(url)])
                })
            ])
        ))
    }

    func testCollectsFindingsSourcesAndToolCalls() throws {
        let blocks: [ContentBlock] = [
            searchCall(["DeepSeek V4"]),
            searchResult([("发布公告", "https://a.test/1"), ("价格", "https://b.test/2")]),
            .text("V4 于 2026 年 6 月发布 [1]。定价见 [2]。"),
            .citation(Citation(index: 1, url: URL(string: "https://a.test/1")!, title: "发布公告"))
        ]
        let brief = try WebResearch.brief(from: blocks, usage: nil)

        XCTAssertEqual(brief.toolCalls, 1)
        XCTAssertTrue(brief.findings.contains("2026 年 6 月"))
        XCTAssertEqual(brief.sources.count, 2, "两条搜索结果 + 一条引用，按 URL 去重后仍是 2")
        XCTAssertEqual(brief.sources.map(\.url.absoluteString), ["https://a.test/1", "https://b.test/2"])
    }

    /// 同一个来源在搜索结果和引用里各出现一次时不能重复。
    func testSourcesAreDeduplicated() throws {
        let blocks: [ContentBlock] = [
            searchResult([("标题", "https://a.test/1")]),
            .text("结论 [1]"),
            .citation(Citation(index: 1, url: URL(string: "https://a.test/1")!, title: "标题"))
        ]
        let brief = try WebResearch.brief(from: blocks, usage: nil)
        XCTAssertEqual(brief.sources.count, 1)
    }

    func testEmptyFindingsThrows() {
        XCTAssertThrowsError(try WebResearch.brief(from: [searchCall(["x"])], usage: nil)) { error in
            XCTAssertEqual(error as? WebResearchError, .emptyFindings)
        }
    }

    func testContextEvidenceHasNumberedSources() throws {
        let blocks: [ContentBlock] = [
            searchResult([("标题", "https://a.test/1")]),
            .text("事实 [1]")
        ]
        let brief = try WebResearch.brief(from: blocks, usage: nil)
        let evidence = brief.contextEvidence(query: "问题")

        XCTAssertEqual(evidence.sources.count, 1)
        XCTAssertTrue(evidence.digest.contains("事实 [1]"))
        XCTAssertTrue(evidence.digest.contains("[1] 标题 — https://a.test/1"))
    }

    /// 调研请求必须带上服务端工具，并打开 thinking 才能触发多跳。
    func testResearchSendsToolsAndThinking() async throws {
        let box = ResearchAdapter.Box<[ServerToolRequest]>([])
        let adapter = ResearchAdapter(
            profile: .anthropic(),
            blocks: [.text("事实")],
            sendsTools: box
        )
        let research = WebResearch(
            adapter: adapter,
            model: "deepseek-flash",
            serverTools: [.init(wireType: "deepseek_web_search"), .init(wireType: "deepseek_read_url")]
        )
        _ = try await research.research(question: "问", queries: ["查询"])

        XCTAssertEqual(box.current.map(\.wireType), ["deepseek_web_search", "deepseek_read_url"])
    }
}
