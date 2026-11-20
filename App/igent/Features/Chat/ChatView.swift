import AgentKit
import CoreKit
import SwiftUI

struct ChatView: View {
    @Environment(AppEnvironment.self) private var env
    let model: ChatViewModel

    @State private var showSettings = false
    @State private var showSessions = false
    @State private var showStats = false
    @State private var showExport = false
    @State private var stats: SessionStats?
    @State private var exportText = ""
    @State private var infoMessage: String?
    @State private var isWorking = false

    private var draftBinding: Binding<String> {
        Binding(get: { model.draft }, set: { model.draft = $0 })
    }

    var body: some View {
        VStack(spacing: 0) {
            transcript
            usageBar
            composer
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
                    Text(title)
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
                    Button { showSettings = true } label: {
                        Label("设置", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    Button {
                        Task { await compact() }
                    } label: {
                        Label("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left")
                    }
                    Button {
                        Task { await loadStats() }
                    } label: {
                        Label("统计", systemImage: "chart.bar.xaxis")
                    }
                    Button {
                        Task { await prepareExport() }
                    } label: {
                        Label("导出为 Markdown", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .disabled(isWorking)
                .accessibilityLabel("更多")
            }
        }
        .sheet(isPresented: $showSettings) {
            ProviderSettingsView()
        }
        .sheet(isPresented: $showSessions) {
            SessionListView(currentSessionID: model.sessionID)
        }
        .sheet(isPresented: $showStats) {
            statsSheet
        }
        .sheet(isPresented: $showExport) {
            exportSheet
        }
        .alert("提示", isPresented: Binding(
            get: { infoMessage != nil },
            set: { if !$0 { infoMessage = nil } }
        )) {
            Button("好") { infoMessage = nil }
        } message: {
            Text(infoMessage ?? "")
        }
        .task(id: model.messages.count) {
            // 首轮结束后自动起标题；已经在用自定义标题时是空操作。
            await env.generateTitleIfNeeded(sessionID: model.sessionID)
        }
    }

    private var title: String {
        if model.imageMode {
            return env.isImageGenerationConfigured ? "生成图片" : "生成图片（未配置）"
        }
        return env.activeModel.isEmpty ? "未选择模型" : env.activeModel
    }

    /// 最近一轮的用量与估算成本。成本算不出来时只显示 token。
    @ViewBuilder
    private var usageBar: some View {
        if let usage = model.lastTurnUsage {
            HStack(spacing: 6) {
                Text("本轮 ↑\(usage.billedInputTokens) ↓\(usage.outputTokens)")
                if let cost = model.lastTurnCost {
                    Text("· ≈$\(cost, format: .number.precision(.fractionLength(cost < 0.01 ? 4 : 3)))")
                }
                Spacer()
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 16)
            .padding(.bottom, 2)
        }
    }

    private var statsSheet: some View {
        NavigationStack {
            List {
                if let stats {
                    Section("用量") {
                        row("输入（未缓存）", "\(stats.usage?.uncachedInputTokens ?? 0)")
                        row("缓存读", "\(stats.usage?.cacheReadTokens ?? 0)")
                        row("输出", "\(stats.usage?.outputTokens ?? 0)")
                    }
                    Section("估算成本") {
                        if let cost = stats.costUSD {
                            row("合计", String(format: "≈ $%.4f", cost))
                        } else {
                            Text("价格表里没有 \(stats.model)，只显示 token。")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("会话") {
                        row("消息数", "\(stats.messageCount)")
                        row("模型", stats.model)
                    }
                }
            }
            .navigationTitle("统计")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showStats = false }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    private var exportSheet: some View {
        NavigationStack {
            ScrollView {
                Text(exportText)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .navigationTitle("导出")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showExport = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: exportText) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private func compact() async {
        isWorking = true
        let count = await env.compactCurrentSession()
        isWorking = false
        infoMessage = count.map { "已把 \($0) 条历史压成一段要点。" }
            ?? "消息太少，暂时不需要压缩。"
    }

    private func loadStats() async {
        stats = await env.currentStats()
        showStats = true
    }

    private func prepareExport() async {
        exportText = await env.exportCurrentSession() ?? "（没有可导出的内容）"
        showExport = true
    }

    private var composer: some View {
        Composer(
            text: draftBinding,
            isStreaming: model.isStreaming,
            isBusy: model.isGeneratingImage,
            pendingImage: model.pendingImage,
            allowsImage: env.activeProfile?.capabilities.vision ?? false,
            webSearchEnabled: model.webSearchEnabled,
            webSearchAvailable: env.isWebSearchConfigured,
            isSearching: model.isSearching,
            imageMode: model.imageMode,
            imageModel: env.imageSettings.model,
            imageAvailable: env.isImageGenerationConfigured,
            skillSummaries: env.skillSummaries,
            pendingSkillName: model.pendingSkill?.summary.name,
            onToggleWebSearch: { model.setWebSearch($0) },
            onToggleImageMode: { model.setImageMode($0) },
            onSelectSkill: { name in
                model.pendingSkill = env.skillDefinitions[name]
            },
            onRemoveSkill: { model.pendingSkill = nil },
            onSend: send,
            onStop: { model.stop() },
            onPickImage: { data in
                Task { await model.attach(data) }
            },
            onRemoveImage: { model.removePendingImage() }
        )
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
        if model.imageMode {
            sendImagePrompt()
            return
        }

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

    private func sendImagePrompt() {
        let prompt = model.takeDraft()
        guard !prompt.isEmpty else { return }
        guard let adapter = env.makeImageAdapter() else {
            model.reportError("图片生成还没配置：设置 → 图片生成，填 Base URL、模型和 Key。")
            showSettings = true
            return
        }
        Task {
            await model.generateImage(
                prompt: prompt,
                adapter: adapter,
                model: env.imageSettings.model
            )
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
