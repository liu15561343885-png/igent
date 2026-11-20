import AgentKit
import CoreKit
import SwiftUI

struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    let model: ChatViewModel

    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showImageGen = false
    @State private var showSkillPicker = false

    private var draftBinding: Binding<String> {
        Binding(get: { model.draft }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            Composer(
                text: draftBinding,
                isStreaming: model.isStreaming,
                pendingImage: model.pendingImage,
                allowsImage: env.activeProfile?.capabilities.vision ?? false,
                webSearchEnabled: model.webSearchEnabled,
                webSearchAvailable: env.isWebSearchConfigured,
                isSearching: model.isSearching,
                pendingSkillName: model.pendingSkill?.summary.name,
                onToggleWebSearch: { model.webSearchEnabled.toggle() },
                onPickSkill: { showSkillPicker = true },
                onRemoveSkill: { model.pendingSkill = nil },
                onSend: send,
                onStop: { model.stop() },
                onPickImage: { data in
                    Task { await model.attach(data) }
                },
                onRemoveImage: { model.removePendingImage() }
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
                Menu {
                    Button {
                        showImageGen = true
                    } label: {
                        Label("生成图片", systemImage: "sparkles")
                    }
                    Button {
                        showSettings = true
                    } label: {
                        Label("设置", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $showSettings) {
            ProviderSettingsView()
        }
        .sheet(isPresented: $showSessions) {
            SessionListView(currentSessionID: model.sessionID)
        }
        .sheet(isPresented: $showImageGen) {
            ImageGenView(model: model)
        }
        .sheet(isPresented: $showSkillPicker) {
            skillPicker
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
            .onChange(of: model.messages.count) { scroll(proxy) }
            .onChange(of: model.streamingText) { scroll(proxy) }
            .onChange(of: model.isThinking) { scroll(proxy) }
            .task {
                // 首屏必须等一次布局：onAppear 时单元格还没量高，
                // scrollTo 会停在上一步的位置，看起来像"没滚到底"。
                try? await Task.sleep(nanoseconds: 250_000_000)
                scrollToLast(proxy, animated: false)
            }
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
        let skills = env.resolveSkills(pending: model.pendingSkill, text: model.draft)
        model.send(
            configuration: configuration,
            webSearch: env.makeWebSearchProvider(),
            skills: skills
        )
    }

    /// 优先滚到最后一条消息（懒加载容器里它一定被创建），兜底滚到哨兵。
    private var skillPicker: some View {
        NavigationStack {
            List {
                if env.skillSummaries.isEmpty {
                    ContentUnavailableView(
                        "还没有 skill",
                        systemImage: "text.badge.plus",
                        description: Text("在设置里打开 Skill，把 SKILL.md 放进 Documents/Skills。")
                    )
                }
                ForEach(env.skillSummaries) { summary in
                    Button {
                        model.pendingSkill = env.skillDefinitions[summary.name]
                        showSkillPicker = false
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(summary.name)
                                .font(.callout.monospaced())
                                .foregroundStyle(.primary)
                            Text(summary.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("选择 Skill")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showSkillPicker = false }
                }
            }
        }
    }

    private func scrollToLast(_ proxy: ScrollViewProxy, animated: Bool = false) {
        let target: AnyHashable = model.messages.last.map { AnyHashable($0.id) } ?? AnyHashable(Anchor.bottom)
        let action = { proxy.scrollTo(target, anchor: .bottom) }
        if animated {
            withAnimation(.easeOut(duration: 0.2), action)
        } else {
            action()
        }
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
