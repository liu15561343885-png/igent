import CoreKit
import Foundation
import LLMKit

/// 一次调研的结果：事实 + 来源。
public struct ResearchBrief: Sendable {
    /// 模型给出的调研正文（含 [n] 编号）。
    public var findings: String
    public var sources: [WebSource]
    public var usage: TokenUsage?
    /// 调研过程中实际发生的服务端工具调用次数（搜索 / 开页 / 页内查找）。
    public var toolCalls: Int
    /// 中间过程的人话描述，供界面展示（受"显示思考过程与联网动作"开关控制）。
    public var steps: [String]

    /// 转成注入用的证据块。
    public func contextEvidence(query: String) -> ContextEvidence {
        var digest = findings
        if !sources.isEmpty {
            digest += "\n\n来源："
            for (index, source) in sources.enumerated() {
                let title = source.title ?? source.url.host() ?? source.url.absoluteString
                digest += "\n[\(index + 1)] \(title) — \(source.url.absoluteString)"
            }
        }
        return ContextEvidence(
            query: query,
            sources: sources,
            digest: digest,
            fetchedAt: Date(),
            truncated: false
        )
    }
}

public enum WebResearchError: Error, Equatable {
    case emptyFindings
}

/// 「调研员」：借 DeepSeek 的服务端工具做多跳检索，产出事实与来源，
/// 再交给主对话模型（例如 GPT）写最终答案。
///
/// 为什么这样能到"DeepSeek 主对话"的程度：
/// 多跳发生在**调研这一跳里**——DeepSeek 自己搜索、开页、页内查找，最多约 20 步。
/// 主模型拿到的不是"三页原文"，而是"已经核实过、带编号的事实"。
/// 代价是多一次模型调用，且主模型不再参与后续检索决策。
public struct WebResearch: Sendable {
    private let adapter: any LlmAdapter
    private let model: String
    private let serverTools: [ServerToolRequest]
    private let maxTokens: Int

    public init(
        adapter: any LlmAdapter,
        model: String,
        serverTools: [ServerToolRequest],
        maxTokens: Int = 1500
    ) {
        self.adapter = adapter
        self.model = model
        self.serverTools = serverTools
        self.maxTokens = maxTokens
    }

    static let systemPrompt = """
    你是调研助手。请联网查证下面的问题，只输出事实。

    要求：
    - 每条事实尽量带日期、数字、出处；不确定的不要写。
    - 每个结论后用 [n] 标注来源编号。
    - 不要写建议、不要客套、不要复述任务、不要输出思考过程。
    """

    public func research(question: String, queries: [String]) async throws -> ResearchBrief {
        let focus = queries.isEmpty
            ? question
            : queries.map { "「\($0)」" }.joined(separator: "、")

        let prompt = """
        调研任务：\(question)

        重点查证：\(focus)
        """

        let options = GenerateOptions(
            provider: adapter.profile.id,
            model: model,
            messages: [Message(role: .user, blocks: [.text(prompt)], source: .user)],
            system: Self.systemPrompt,
            maxTokens: maxTokens,
            purpose: .webResearch,
            serverTools: serverTools,
            // DeepSeek 的「深度思考搜索」需要显式打开 thinking，
            // 才会在推理过程中反复搜索 / 开页 / 页内查找。
            extras: ["thinking": .object(["type": .string("enabled")])]
        )

        var assembler = BlockAssembler()
        var usage: TokenUsage?
        for try await chunk in adapter.stream(options) {
            assembler.push(chunk)
            if case let .usage(value) = chunk { usage = value }
        }

        let blocks = (try? assembler.blocks()) ?? []
        return try Self.brief(from: blocks, usage: usage)
    }

    /// 把服务端工具的调用翻译成一行行可读的步骤。
    static func steps(from blocks: [ContentBlock]) -> [String] {
        var result: [String] = []
        for block in blocks {
            guard case let .providerBlock(payload) = block else { continue }
            let object = payload.payload.objectValue
            switch payload.type {
            case "server_tool_use":
                let input = object?["input"]?.objectValue
                switch input?["action"]?.stringValue ?? "" {
                case "search":
                    let queries = input?["queries"]?.arrayValue?
                        .compactMap { $0.stringValue }.joined(separator: " / ") ?? ""
                    result.append(queries.isEmpty ? "联网检索" : "检索：\(queries)")
                case "open_page":
                    result.append("打开：\(host(of: input?["url"]?.stringValue))")
                case "find_in_page":
                    result.append("页内查找：「\(input?["pattern"]?.stringValue ?? "")」")
                case "read_link":
                    result.append("读取：\(host(of: input?["url"]?.stringValue))")
                default:
                    continue
                }
            case "web_search_tool_result":
                let count = object?["content"]?.arrayValue?.count ?? 0
                result.append("找到 \(count) 条结果")
            case "web_fetch_tool_result":
                let title = object?["content"]?.objectValue?["title"]?.stringValue ?? ""
                result.append(title.isEmpty ? "已读取页面" : "已读取：\(title)")
            default:
                continue
            }
        }
        return result
    }

    private static func host(of urlString: String?) -> String {
        guard let urlString, let host = URL(string: urlString)?.host() else {
            return urlString ?? "页面"
        }
        return host
    }

    static func brief(from blocks: [ContentBlock], usage: TokenUsage?) throws -> ResearchBrief {
        var findings = ""
        var sources: [WebSource] = []
        var seen = Set<String>()
        var toolCalls = 0

        for block in blocks {
            switch block {
            case let .text(text):
                findings += text
            case let .citation(citation):
                if seen.insert(citation.url.absoluteString).inserted {
                    sources.append(WebSource(url: citation.url, title: citation.title))
                }
            case let .providerBlock(payload):
                switch payload.type {
                case "server_tool_use":
                    toolCalls += 1
                case "web_search_tool_result":
                    for item in payload.payload.objectValue?["content"]?.arrayValue ?? [] {
                        guard let urlString = item.objectValue?["url"]?.stringValue,
                              let url = URL(string: urlString),
                              seen.insert(urlString).inserted
                        else { continue }
                        sources.append(WebSource(
                            url: url,
                            title: item.objectValue?["title"]?.stringValue,
                            snippet: item.objectValue?["snippet"]?.stringValue
                        ))
                    }
                default:
                    break
                }
            default:
                continue
            }
        }

        let trimmed = findings.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WebResearchError.emptyFindings }
        return ResearchBrief(
            findings: trimmed,
            sources: sources,
            usage: usage,
            toolCalls: toolCalls,
            steps: steps(from: blocks)
        )
    }
}
