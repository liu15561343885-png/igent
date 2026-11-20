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

    private var body_: String {
        message.blocks.compactMap { block -> String? in
            if case let .text(value) = block { value } else { nil }
        }.joined()
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 44) }

            VStack(alignment: .leading, spacing: 8) {
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

                Text(body_)
                    .font(.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

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
                maxWidth: UIScreen.main.bounds.width * Theme.bubbleMaxWidth,
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
