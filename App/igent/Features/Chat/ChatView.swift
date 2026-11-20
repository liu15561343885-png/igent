import AgentKit
import CoreKit
import SwiftUI

struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    let model: ChatViewModel

    @State private var showSettings = false
    @State private var showSessions = false

    private var draftBinding: Binding<String> {
        Binding(get: { model.draft }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Composer(
                text: draftBinding,
                isStreaming: model.isStreaming,
                onSend: send,
                onStop: { model.stop() }
            )
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSessions = true } label: {
                    Image(systemName: "list.bullet")
                }
                .accessibilityLabel("会话列表")
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(env.activeModel.isEmpty ? "未选择模型" : env.activeModel)
                        .font(.headline)
                        .lineLimit(1)
                    Text(env.activeProfile?.name ?? "去设置里添加厂商")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("设置")
            }
        }
        .sheet(isPresented: $showSettings) {
            ProviderSettingsView()
        }
        .sheet(isPresented: $showSessions) {
            SessionListView(currentSessionID: model.sessionID)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Theme.groupSpacing) {
                    ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .padding(.top, topSpacing(at: index))
                    }

                    if model.isThinking {
                        HStack {
                            TypingIndicator()
                            Spacer(minLength: 44)
                        }
                        .id(Anchor.typing)
                    }

                    if model.isStreaming, !model.streamingText.isEmpty {
                        MessageBubble(message: streamingMessage, isStreaming: true)
                            .id(Anchor.streaming)
                    }

                    if let error = model.lastError {
                        HStack {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.orange.opacity(0.12), in: Capsule())
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 6)
                    }

                    Color.clear.frame(height: 1).id(Anchor.bottom)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            // 内容不足一屏时贴底，和 iMessage 一致。
            .defaultScrollAnchor(.bottom)
            .onChange(of: model.messages.count) { scroll(proxy) }
            .onChange(of: model.streamingText) { scroll(proxy) }
            .onChange(of: model.isThinking) { scroll(proxy) }
            .onAppear { scroll(proxy, animated: false) }
        }
    }

    /// 同一个人连续发言时收紧间距——iMessage 的成组规则。
    private func topSpacing(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        let previous = model.messages[index - 1].role
        let current = model.messages[index].role
        if previous == current, current == .user || current == .assistant {
            return Theme.sameSenderSpacing - Theme.groupSpacing
        }
        return 0
    }

    private var streamingMessage: Message {
        Message(
            role: .assistant,
            blocks: [.text(model.streamingText)],
            source: .model(provider: env.activeProfileID ?? "", model: env.activeModel, meta: nil)
        )
    }

    private func send() {
        guard let profile = env.activeProfile else {
            showSettings = true
            return
        }
        let configuration = TurnOrchestrator.Configuration(
            provider: profile.id,
            model: env.activeModel
        )
        model.send(configuration: configuration)
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let action = { proxy.scrollTo(Anchor.bottom, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
    }

    private enum Anchor: Hashable {
        case typing
        case streaming
        case bottom
    }
}
