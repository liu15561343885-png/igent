import CoreKit
import Foundation

/// 检索证据的模型可见投影。两族共用，避免各写一份导致格式漂移。
enum ContextRendering {
    static func render(_ evidence: ContextEvidence) -> String {
        var lines = ["<context query=\"\(escape(evidence.query))\">", sanitize(evidence.digest)]
        if !evidence.sources.isEmpty {
            lines.append("")
            lines.append("来源：")
            for (index, source) in evidence.sources.enumerated() {
                let title = source.title ?? source.url.host() ?? source.url.absoluteString
                lines.append("[\(index + 1)] \(title) — \(source.url.absoluteString)")
            }
        }
        lines.append("</context>")
        return lines.joined(separator: "\n")
    }

    /// 防止检索结果里出现 `</context>` 提前闭合标签（提示注入的常见手法）。
    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func sanitize(_ digest: String) -> String {
        digest
            .replacingOccurrences(of: "</context>", with: "&lt;/context&gt;")
            .replacingOccurrences(of: "<context", with: "&lt;context")
    }
}
