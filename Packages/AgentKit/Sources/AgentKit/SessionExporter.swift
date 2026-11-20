import CoreKit
import Foundation

/// 把一次会话导出成可读文本。
///
/// 选 Markdown 而不是 JSON：导出的第一用途是"存一份、发给别人看"，
/// 而 Markdown 在任何编辑器里都直接可读，代码块也保住了。
public enum SessionExporter {
    public static func markdown(
        session: SessionSummary,
        messages: [Message],
        totalUsage: TokenUsage? = nil,
        includeReasoning: Bool = false
    ) -> String {
        var lines: [String] = []
        lines.append("# \(session.title.isEmpty ? "未命名会话" : session.title)")
        lines.append("")

        var meta: [String] = []
        meta.append(session.createdAt.formatted(date: .numeric, time: .shortened))
        if let provider = session.provider, !provider.isEmpty {
            meta.append(provider)
        }
        if let model = session.model, !model.isEmpty {
            meta.append(model)
        }
        if let usage = totalUsage {
            meta.append("↑\(usage.billedInputTokens) ↓\(usage.outputTokens) tokens")
        }
        lines.append("> " + meta.joined(separator: " · "))
        lines.append("")
        lines.append("---")
        lines.append("")

        for message in messages {
            switch message.role {
            case .user:
                lines.append("## 我")
                lines.append("")
                lines.append(message.visibleText)
            case .assistant:
                lines.append("## 助手")
                if includeReasoning {
                    let reasoning = message.blocks.compactMap { block -> String? in
                        if case let .reasoning(value) = block { value } else { nil }
                    }.joined()
                    if !reasoning.isEmpty {
                        lines.append("")
                        lines.append("<details><summary>思考过程</summary>")
                        lines.append("")
                        lines.append(reasoning)
                        lines.append("")
                        lines.append("</details>")
                    }
                }
                lines.append("")
                lines.append(message.visibleText)
            case .context:
                lines.append("> 资料：\n> " + message.visibleText.replacingOccurrences(of: "\n", with: "\n> "))
            case .system:
                continue
            }

            // 图片来源没有字节可取，导出时留个占位，避免读者以为漏了内容。
            if message.hasImage {
                lines.append("")
                lines.append("_[图片未随文本导出]_")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// 供分享面板写入临时文件时用。
    public static func filename(for session: SessionSummary) -> String {
        let base = session.title.isEmpty ? "igent" : session.title
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(safe.isEmpty ? "igent" : safe).md"
    }
}
