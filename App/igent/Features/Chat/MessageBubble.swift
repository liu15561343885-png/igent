import CoreKit
import SwiftUI

/// 一条消息气泡。对齐方式、配色、圆角都按 iMessage 的规则来。
struct MessageBubble: View {
    @Environment(AppEnvironment.self) private var env

    let message: Message
    var isStreaming: Bool = false

    @State private var reasoningExpanded = false

    private var isUser: Bool { message.role == .user }

    private var reasoning: String? {
        let text = message.blocks.compactMap { block -> String? in
            if case let .reasoning(value) = block { value } else { nil }
        }.joined()
        return text.isEmpty ? nil : text
    }

    /// 流式期间对超长文本降级为纯文本：每帧重新解析整段 Markdown 会卡。
    private var usePlainText: Bool {
        isUser || (isStreaming && body_.count > 3_000)
    }

    /// 带代码块的气泡放宽，否则横向滚动太窄。
    private var maxWidthFraction: CGFloat {
        let hasCode = MarkdownParser.parse(body_).contains { block in
            if case .code = block { true } else { false }
        }
        return hasCode ? 0.92 : Theme.bubbleMaxWidth
    }

    /// 服务端工具的调用痕迹：检索了哪些词、开了哪些页。
    /// 不展示这些，用户只会看到「答案里突然多出引用」，不知道模型做了什么。
    private var providerRows: [(icon: String, text: String)] {
        message.blocks.compactMap { block in
            guard case let .providerBlock(payload) = block else { return nil }
            let object = payload.payload.objectValue
            switch payload.type {
            case "server_tool_use":
                let input = object?["input"]?.objectValue
                switch input?["action"]?.stringValue ?? "" {
                case "search":
                    let queries = input?["queries"]?.arrayValue?
                        .compactMap { $0.stringValue }.joined(separator: " / ") ?? ""
                    return ("magnifyingglass", queries.isEmpty ? "联网检索" : queries)
                case "open_page":
                    return ("doc.text.magnifyingglass", "打开 \(shortHost(input?["url"]?.stringValue))")
                case "find_in_page":
                    return ("text.magnifyingglass", "页内查找「\(input?["pattern"]?.stringValue ?? "")」")
                case "read_link":
                    return ("link", "读取 \(shortHost(input?["url"]?.stringValue))")
                default:
                    return nil
                }
            case "web_search_tool_result":
                let count = object?["content"]?.arrayValue?.count ?? 0
                return ("list.bullet", "找到 \(count) 条结果")
            case "web_fetch_tool_result":
                let title = object?["content"]?.objectValue?["title"]?.stringValue ?? ""
                return ("doc.richtext", title.isEmpty ? "已读取页面" : "已读取：\(title)")
            case "research_step":
                return ("sparkles", object?["text"]?.stringValue ?? "调研")
            default:
                return nil
            }
        }
    }

    /// 应用侧检索注入的证据。之前这个块在界面上完全不可见，
    /// 用户只会觉得"答案突然变准了"，不知道发生过检索。
    private var contextRows: [(icon: String, text: String)] {
        message.blocks.compactMap { block in
            guard case let .context(evidence) = block else { return nil }
            let count = evidence.sources.count
            let suffix = count > 0 ? " · \(count) 个来源" : ""
            let query = evidence.query.isEmpty ? "联网检索" : evidence.query
            return ("globe", "已检索：\(query)\(suffix)")
        }
    }

    private var documents: [DocumentAttachment] {
        message.blocks.compactMap { block -> DocumentAttachment? in
            if case let .document(value) = block { value } else { nil }
        }
    }

    private var citations: [Citation] {
        message.blocks.compactMap { block -> Citation? in
            if case let .citation(value) = block { value } else { nil }
        }
    }

    private func shortHost(_ urlString: String?) -> String {
        guard let urlString, let host = URL(string: urlString)?.host() else {
            return urlString ?? "页面"
        }
        return host
    }

    private var images: [ImageAttachmentRef] {
        message.blocks.compactMap { block -> ImageAttachmentRef? in
            if case let .image(ref) = block { ref } else { nil }
        }
    }

    private var body_: String {
        message.blocks.compactMap { block -> String? in
            if case let .text(value) = block { value } else { nil }
        }.joined()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 44) }

            VStack(alignment: .leading, spacing: 8) {
                if !images.isEmpty {
                    ForEach(images, id: \.id) { ref in
                        AttachmentThumbnail(reference: ref)
                    }
                }

                ForEach(Array(documents.enumerated()), id: \.offset) { _, document in
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text.fill")
                            .foregroundStyle(isUser ? Color.white.opacity(0.9) : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(document.name)
                                .font(.caption)
                                .lineLimit(1)
                            Text("\(document.pageCount) 页 · \(document.text.count) 字\(document.truncated ? " · 部分未解析" : "")")
                                .font(.caption2)
                                .foregroundStyle(isUser ? Color.white.opacity(0.75) : Color.secondary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isUser ? Color.white.opacity(0.16) : Color.primary.opacity(0.06))
                    )
                }

                if env.showInternals, !providerRows.isEmpty || !contextRows.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array((providerRows + contextRows).enumerated()), id: \.offset) { _, row in
                            Label(row.text, systemImage: row.icon)
                                .font(.caption2)
                                .foregroundStyle(isUser ? Color.white.opacity(0.85) : Color.secondary)
                                .lineLimit(1)
                        }
                    }
                }

                if let reasoning, env.showInternals {
                    // 思维链默认折起，只留一行提示；点开可读。
                    DisclosureGroup(isExpanded: $reasoningExpanded) {
                        Text(reasoning)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                    } label: {
                        Label("思考过程", systemImage: "brain")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                    }
                    .tint(.secondary)
                    .onAppear {
                        // 关掉「自动收起」时保持展开，由用户自己折。
                        reasoningExpanded = !env.autoCollapseReasoning
                    }
                }

                if usePlainText {
                    Text(body_)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    // 模型输出几乎总是 Markdown；用户输入按原样显示，避免误伤。
                    MarkdownView(text: body_)
                        .textSelection(.enabled)
                }

                if !citations.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(Array(citations.enumerated()), id: \.offset) { _, citation in
                                Link(destination: citation.url) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "link")
                                        Text(citation.title ?? (citation.url.host() ?? ""))
                                            .lineLimit(1)
                                    }
                                    .font(.caption2)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.07), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                if isStreaming {
                    Text("▍")
                        .font(.body)
                        .foregroundStyle(isUser ? .white.opacity(0.7) : .secondary)
                        .opacity(0.6)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                    .fill(isUser ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(0.08)))
            )
            .frame(
                maxWidth: UIScreen.main.bounds.width * maxWidthFraction,
                alignment: isUser ? .trailing : .leading
            )

            if !isUser { Spacer(minLength: 44) }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }
}
