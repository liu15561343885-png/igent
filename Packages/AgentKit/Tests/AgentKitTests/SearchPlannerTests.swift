import CoreKit
import Foundation
import LLMKit
import XCTest
@testable import AgentKit

private struct JSONReplyAdapter: LlmAdapter {
    var profile: ProviderProfile
    var reply: String

    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(index: 0, text: reply))
            continuation.yield(.finish(.stop, meta: nil))
            continuation.finish()
        }
    }
}

final class SearchPlannerTests: XCTestCase {
    // MARK: - 解析

    func testParsesPlainJSON() {
        let plan = SearchPlanner.parse(#"{"search":true,"queries":["DeepSeek V4 发布","DeepSeek V4 价格"],"reason":"需要最新信息"}"#)
        XCTAssertEqual(plan?.shouldSearch, true)
        XCTAssertEqual(plan?.queries, ["DeepSeek V4 发布", "DeepSeek V4 价格"])
        XCTAssertEqual(plan?.reason, "需要最新信息")
    }

    /// 模型经常把 JSON 包在代码块里，前后还带说明。
    func testParsesJSONInsideFences() {
        let raw = """
        好的，下面是结果：
        ```json
        {"search": true, "queries": ["今日天气"]}
        ```
        希望有帮助。
        """
        XCTAssertEqual(SearchPlanner.parse(raw)?.queries, ["今日天气"])
    }

    func testSkipsWhenModelSaysNo() {
        let plan = SearchPlanner.parse(#"{"search":false,"queries":[]}"#)
        XCTAssertEqual(plan, .skip)
    }

    /// search 为 true 但没有查询词 → 视作不检索，别白跑一次搜索。
    func testTrueWithoutQueriesIsSkip() {
        XCTAssertEqual(SearchPlanner.parse(#"{"search":true,"queries":[]}"#), .skip)
    }

    func testCapsQueryCount() {
        let raw = #"{"search":true,"queries":["a","b","c","d","e"]}"#
        XCTAssertEqual(SearchPlanner.parse(raw)?.queries.count, 3)
    }

    func testRejectsGarbage() {
        XCTAssertNil(SearchPlanner.parse("我不知道"))
    }

    // MARK: - 调用

    func testPlansThroughRuntime() async throws {
        let runtime = LlmRuntime()
        _ = try await runtime.register(
            providers: ["gpt"],
            adapter: JSONReplyAdapter(
                profile: .openAICompatible(id: "gpt", name: "GPT", baseURL: "https://api.openai.com/v1"),
                reply: #"{"search":true,"queries":["量子计算 最新进展"]}"#
            )
        )
        let planner = SearchPlanner(runtime: runtime)
        let plan = await planner.plan(question: "量子计算最近有什么进展？", provider: "gpt", model: "gpt-4o")

        XCTAssertEqual(plan?.queries, ["量子计算 最新进展"])
    }

    /// 规划失败返回 nil，调用方退回原话检索。
    func testReturnsNilOnFailure() async throws {
        let runtime = LlmRuntime() // 未注册任何厂商
        let planner = SearchPlanner(runtime: runtime)
        let plan = await planner.plan(question: "问题", provider: "missing", model: "m")
        XCTAssertNil(plan)
    }
}
