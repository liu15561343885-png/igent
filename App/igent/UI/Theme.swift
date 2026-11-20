import SwiftUI

enum Theme {
    static let bubbleRadius: CGFloat = 20
    /// 气泡最多占屏宽的比例，留出边距让对话有呼吸感。
    static let bubbleMaxWidth: CGFloat = 0.75
    static let groupSpacing: CGFloat = 12
    static let sameSenderSpacing: CGFloat = 3
}

/// "正在输入"的三点指示器。
struct TypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.28, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(.secondary)
                    .frame(width: 6, height: 6)
                    .opacity(phase == index ? 1 : 0.35)
                    .scaleEffect(phase == index ? 1.15 : 1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Theme.bubbleRadius, style: .continuous)
                .fill(Color.primary.opacity(0.08))
        )
        .animation(.easeInOut(duration: 0.25), value: phase)
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
        .accessibilityLabel("正在输入")
    }
}
