import SwiftUI

/// 底部输入条：随内容增高、流式时变成停止按钮。
struct Composer: View {
    @Binding var text: String
    var isStreaming: Bool
    var onSend: () -> Void
    var onStop: () -> Void

    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("发消息…", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .font(.body)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 19, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .overlay(
                            RoundedRectangle(cornerRadius: 19, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5)
                        )
                )
                .focused($isFocused)
                .submitLabel(.send)
                .disabled(isStreaming)

            Button {
                if isStreaming {
                    onStop()
                } else {
                    onSend()
                }
            } label: {
                Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(
                        Circle().fill(
                            isStreaming
                                ? AnyShapeStyle(Color.secondary)
                                : AnyShapeStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                        )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!isStreaming && !canSend)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isStreaming)
            .accessibilityLabel(isStreaming ? "停止生成" : "发送")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
