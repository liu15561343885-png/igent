import CoreKit
import SwiftUI

/// 一条消息气泡。对齐方式、配色、圆角都按 iMessage 的规则来。
struct MessageBubble: View {
    let message: Message
    var isStreaming: Bool = false

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

                if let reasoning {
                    // 思维链默认折起，只留一行提示；点开可读。
                    DisclosureGroup {
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
