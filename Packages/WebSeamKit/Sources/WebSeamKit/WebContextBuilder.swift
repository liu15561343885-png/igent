import CoreKit
import Foundation

/// 把"搜一次 → 抓几页 → 拼证据"合成一个可复用的组件。
///
/// 取舍：
/// - **并发抓取**，但限 3 页。再多的话首字延迟会明显变差，收益递减。
/// - **单页失败不影响整体**：抓不到就跳过，来源列表仍然保留（用户还能点开看）。
/// - 摘要只取 `maxCharactersPerPage`，总长度有个上限，避免把上下文吃干。
public struct WebContextBuilder: Sendable {
    public var maxResults: Int
    public var maxPages: Int
    public var maxCharactersPerPage: Int

    public init(
        maxResults: Int = 5,
        maxPages: Int = 3,
        maxCharactersPerPage: Int = 4000
    ) {
        self.maxResults = maxResults
        self.maxPages = maxPages
        self.maxCharactersPerPage = maxCharactersPerPage
    }

    public struct Outcome: Sendable {
        public var evidence: ContextEvidence
        /// 抓取失败的页面数量，UI 可以据此提示"部分来源未能打开"。
        public var failedFetches: Int
    }

    public func build(
        query: String,
        search: any WebSearchProvider,
        fetcher: any WebFetchProvider
    ) async -> Outcome {
        let result: WebSearchResult
        do {
            result = try await search.search(query: query, maxResults: maxResults)
        } catch {
            return Outcome(
                evidence: ContextEvidence(
                    query: query,
                    sources: [],
                    digest: "检索失败：\(error.localizedDescription)",
                    fetchedAt: Date(),
                    truncated: false
                ),
                failedFetches: 0
            )
        }

        let targets = Array(result.sources.prefix(maxPages))
        var pages: [WebPage?] = Array(repeating: nil, count: targets.count)

        await withTaskGroup(of: (Int, WebPage?).self) { group in
            for (index, source) in targets.enumerated() {
                group.addTask {
                    let page = try? await fetcher.fetch(source.url)
                    return (index, page)
                }
            }
            for await (index, page) in group {
                pages[index] = page
            }
        }

        var digest = ""
        var failed = 0
        for (index, source) in targets.enumerated() {
            let title = source.title ?? source.url.host() ?? source.url.absoluteString
            digest += "[\(index + 1)] \(title) — \(source.url.absoluteString)\n"
            if let page = pages[index] {
                let text = String(page.text.prefix(maxCharactersPerPage))
                digest += text
                if text.count < page.text.count { digest += "…" }
            } else {
                failed += 1
                // 抓不到正文时退回搜索摘要，至少给模型一点线索。
                digest += source.snippet ?? "（正文抓取失败）"
            }
            digest += "\n\n"
        }

        if let answer = result.answer, !answer.isEmpty {
            digest = "检索摘要：\(answer)\n\n" + digest
        }

        return Outcome(
            evidence: ContextEvidence(
                query: query,
                sources: targets,
                digest: digest.trimmingCharacters(in: .whitespacesAndNewlines),
                fetchedAt: Date(),
                truncated: result.sources.count > targets.count
            ),
            failedFetches: failed
        )
    }
}
