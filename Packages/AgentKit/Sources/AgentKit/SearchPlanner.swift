import CoreKit
import Foundation
import LLMKit

/// 检索规划：先问模型「这个问题需不需要联网、该搜什么」，再由应用去执行。
///
/// 为什么不直接拿用户原话当查询词：一句长问题的检索价值很低，
/// 而搜索 API 的 query 还有长度上限。让模型把它改写成 1–3 条具体检索式，
/// 是同一套「无工具循环」架构下性价比最高的改进。
///
/// 注意：这**不是**工具调用。模型不产出 call，也不会拿到执行结果再决定下一步；
/// 它只做一次规划，执行与注入仍由应用完成。
public struct SearchPlan: Sendable, Equatable {
    public var shouldSearch: Bool
    public var queries: [String]
    /// 模型给的理由，仅用于界面提示与排查。
    public var reason: String?

    public init(shouldSearch: Bool, queries: [String], reason: String? = nil) {
        self.shouldSearch = shouldSearch
        self.queries = queries
        self.reason = reason
    }

    public static let skip = SearchPlan(shouldSearch: false, queries: [])
}

public actor SearchPlanner {
    private let runtime: LlmRuntime

    public init(runtime: LlmRuntime) {
        self.runtime = runtime
    }

    static let systemPrompt = """
    你是检索规划器。判断回答下面的问题是否需要联网检索。

    只输出 JSON，不要代码块、不要解释：
    {"search": true 或 false, "queries": ["..."], "reason": "一句话"}

    规则：
    - 需要时效性信息（新闻、价格、版本、人物近况）→ search 为 true。
    - 纯推理、写作、代码、常识 → search 为 false，queries 为空数组。
    - queries 用与问题相同的语种，1–3 条，每条不超过 40 字，必须具体（带实体名、年份等）。
    - 不要输出与上面示例不同的字段。
    """

    /// 规划失败时返回 nil，调用方退回"用用户原话检索"。
    public func plan(
        question: String,
        provider: String,
        model: String
    ) async -> SearchPlan? {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .skip }

        let options = GenerateOptions(
            provider: provider,
            model: model,
            messages: [
                Message(role: .user, blocks: [.text(String(trimmed.prefix(2000)))], source: .user)
            ],
            system: Self.systemPrompt,
            maxTokens: 160,
            purpose: .queryRewrite
        )

        var assembler = BlockAssembler()
        do {
            for try await chunk in await runtime.stream(options) {
                assembler.push(chunk)
            }
        } catch {
            return nil
        }
        let text = (try? assembler.blocks())?.answerText ?? ""
        return Self.parse(text)
    }

    /// 容忍模型加花边：代码块、前后说明文字。
    static func parse(_ raw: String) -> SearchPlan? {
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end
        else { return nil }

        let json = String(raw[start...end])
        guard let data = json.data(using: .utf8),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: data))?.objectValue
        else { return nil }

        let shouldSearch = object["search"].map { value in
            if case let .bool(flag) = value { flag } else { false }
        } ?? false

        let queries = (object["queries"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)

        // search 为 true 却没有可用查询词时，视作不检索，避免白跑一次搜索。
        guard shouldSearch, !queries.isEmpty else { return .skip }
        return SearchPlan(
            shouldSearch: true,
            queries: Array(queries),
            reason: object["reason"]?.stringValue
        )
    }
}
