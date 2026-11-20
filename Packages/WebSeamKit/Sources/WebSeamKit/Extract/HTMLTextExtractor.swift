import CoreKit
import Foundation

/// 把 HTML 压成可读正文。
///
/// 不追求 Readability 的精度——聊天场景只要"主要段落大致对"就够了。
/// 但三件事必须做对：去掉脚本样式、块级标签转换行、解码常见实体。
public enum HTMLTextExtractor {
    public static func extract(_ html: String) -> (title: String?, text: String) {
        let title = firstMatch(in: html, pattern: "(?is)<title[^>]*>(.*?)</title>")
            .map { decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        var body = html

        // 整段删除的标签：内容留着只会污染正文。
        for tag in ["script", "style", "noscript", "svg", "iframe", "head"] {
            body = body.replacingOccurrences(
                of: "(?is)<\(tag)[^>]*>.*?</\(tag)>",
                with: " ",
                options: .regularExpression
            )
        }

        // 块级标签断开，否则整页会挤成一行。
        body = body.replacingOccurrences(
            of: "(?i)</(p|div|li|tr|h[1-6]|section|article|br|blockquote|pre)>",
            with: "\n",
            options: .regularExpression
        )
        body = body.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)

        // 去掉所有剩余标签。
        body = body.replacingOccurrences(of: "(?s)<[^>]+>", with: " ", options: .regularExpression)
        body = decodeEntities(body)

        // 收敛空白：连续空格进一个，连续空行留一个。
        body = body.replacingOccurrences(of: "[\\t\\x{00A0}]+", with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        // 去掉换行两侧的空格：块标签替换成换行后，下一段常常带着一个前导空格。
        body = body.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        // 三个以上换行收敛成一个空行。
        body = body.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)

        return (title, body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func decodeEntities(_ text: String) -> String {
        var result = text
        let map = [
            "&nbsp;": " ",
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&mdash;": "—",
            "&ndash;": "–",
            "&hellip;": "…"
        ]
        for (entity, replacement) in map {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[captured])
    }
}

/// 抓取网页并抽取正文。
public struct HTTPFetcher: WebFetchProvider {
    private let session: URLSession
    private let maxBytes: Int

    public init(session: URLSession = .shared, maxBytes: Int = 2 << 20) {
        self.session = session
        self.maxBytes = maxBytes
    }

    public func fetch(_ url: URL) async throws -> WebPage {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("text/html,application/xhtml+xml,text/plain", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw WebError.badStatus(http.statusCode)
        }
        guard data.count <= maxBytes else { throw WebError.tooLarge }

        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        guard contentType.contains("text") || contentType.contains("html") else {
            throw WebError.unsupportedContentType(contentType)
        }

        let raw = String(decoding: data, as: UTF8.self)
        if contentType.contains("html") {
            let extracted = HTMLTextExtractor.extract(raw)
            guard !extracted.text.isEmpty else { throw WebError.emptyBody }
            return WebPage(url: url, title: extracted.title, text: extracted.text)
        }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WebError.emptyBody }
        return WebPage(url: url, title: nil, text: text)
    }
}
