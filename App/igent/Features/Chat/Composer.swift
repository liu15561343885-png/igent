import CoreKit
import LLMKit
import PhotosUI
import SwiftUI

/// 底部输入条。
///
/// 布局分两层：上面是输入行（skill 气泡菜单 + 文本框 + 发送），
/// 下面是模式开关行（联网搜索 / 生成图片）。两个开关互斥，由 ViewModel 保证。
struct Composer: View {
    @Binding var text: String

    var isStreaming: Bool
    var isBusy: Bool
    var pendingImage: ImageAttachmentRef?
    var allowsImage: Bool

    var pendingDocuments: [ChatViewModel.PendingDocument]
    var isParsingDocument: Bool
    var parsingStatus: String?
    var allowsDocument: Bool

    var webSearchEnabled: Bool
    var webSearchAvailable: Bool
    var isSearching: Bool

    var imageMode: Bool
    var imageModel: String
    var imageAvailable: Bool

    var modelName: String
    var models: [ModelInfo]
    var isLoadingModels: Bool
    var modelError: String?
    var onSelectModel: (String) -> Void
    var onRefreshModels: () -> Void

    var reasoningEnabled: Bool
    var reasoning: ReasoningEffort?
    var onSelectReasoning: (ReasoningEffort?) -> Void

    var skillSummaries: [SkillSummary]
    var pendingSkillName: String?

    var onToggleWebSearch: (Bool) -> Void
    var onToggleImageMode: (Bool) -> Void
    var onSelectSkill: (String) -> Void
    var onRemoveSkill: () -> Void
    var onSend: () -> Void
    var onStop: () -> Void
    var onPickImage: (Data) -> Void
    var onRemoveImage: () -> Void
    var streamingMode: ChatViewModel.StreamingInputMode
    var queued: [ChatViewModel.QueuedMessage]
    var onInterject: () -> Void
    var onQueue: () -> Void
    var onRemoveQueued: (UUID) -> Void

    var onPickDocuments: ([URL]) -> Void
    var onRemoveDocument: (UUID) -> Void

    @FocusState private var isFocused: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var showSkillPopover = false
    @State private var showFilePicker = false
    @State private var showReasoningPopover = false
    @State private var showAttachDialog = false
    @State private var showPhotoPicker = false
    @State private var showModelPopover = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || pendingImage != nil
            || !pendingDocuments.isEmpty
    }

    private var placeholder: String {
        if imageMode { return "描述你想要的画面…" }
        if isStreaming {
            switch streamingMode {
            case .interject: return "插话以调整方向…"
            case .queue: return "排队，本轮结束后发送…"
            case .off: break
            }
        }
        return "发消息…"
    }

    var body: some View {
        VStack(spacing: 8) {
            attachmentPreview
            documentPreview
            queuedPreview
            skillChip
            searchStatus

            inputRow
            modeRow
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: - 上方状态区

    @ViewBuilder
    private var queuedPreview: some View {
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(queued) { item in
                    HStack(spacing: 8) {
                        Image(systemName: "clock")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(item.text)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            onRemoveQueued(item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .black.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("移除排队消息")
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var documentPreview: some View {
        if !pendingDocuments.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(pendingDocuments) { document in
                    HStack(spacing: 8) {
                        Image(systemName: document.attachment == nil ? "doc.text" : "doc.text.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(document.name)
                                .font(.caption)
                                .lineLimit(1)
                            if let attachment = document.attachment {
                                Text("\(attachment.pageCount) 页 · \(attachment.text.count) 字")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if isParsingDocument {
                            ProgressView().controlSize(.mini)
                        } else {
                            Button {
                                onRemoveDocument(document.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.35))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("移除 \(document.name)")
                        }
                    }
                }

                if let parsingStatus {
                    Text(parsingStatus)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var attachmentPreview: some View {
        if let pendingImage {
            HStack(alignment: .top, spacing: 8) {
                AttachmentThumbnail(reference: pendingImage, maxSide: 120)
                Button(action: onRemoveImage) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除图片")
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var skillChip: some View {
        if let pendingSkillName {
            HStack(spacing: 8) {
                Label(pendingSkillName, systemImage: "text.badge.checkmark")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                    .foregroundStyle(Color.accentColor)
                Button(action: onRemoveSkill) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("移除 skill")
                Spacer()
            }
            .padding(.horizontal, 14)
        }
    }

    @ViewBuilder
    private var searchStatus: some View {
        if isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("正在检索…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .transition(.opacity)
        }
    }

    // MARK: - 输入行

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            skillButton

            TextField(placeholder, text: $text, axis: .vertical)
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
                .disabled((isStreaming && streamingMode == .off) || isBusy)

            sendButton
        }
        .padding(.horizontal, 12)
    }

    /// 输入框左侧：弹出气泡，不是整屏 sheet。
    private var skillButton: some View {
        Button {
            showSkillPopover = true
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(pendingSkillName == nil ? Color.secondary : Color.accentColor)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .disabled(isStreaming)
        .accessibilityLabel("选择 Skill")
        .popover(isPresented: $showSkillPopover, arrowEdge: .bottom) {
            SkillPopover(
                skills: skillSummaries,
                onSelect: { name in
                    onSelectSkill(name)
                    showSkillPopover = false
                }
            )
            .presentationCompactAdaptation(.popover)
        }
    }

    private var sendButton: some View {
        HStack(spacing: 6) {
            if isStreaming, streamingMode != .off, canSend {
                // 有内容时主按钮是"插话"，停止退成旁边那个小按钮——
                // 想打断但没话说的人应该按停止，这两个动作不能混。
                Button(action: onStop) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("停止生成")
            }

            primaryButton
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isStreaming)
    }

    private var primaryButton: some View {
        Button {
            if isStreaming {
                if canSend, streamingMode == .interject {
                    onInterject()
                } else if canSend, streamingMode == .queue {
                    onQueue()
                } else {
                    onStop()
                }
            } else {
                onSend()
            }
        } label: {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isStreaming && !(streamingMode != .off && canSend) ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(buttonFill))
        }
        .buttonStyle(.plain)
        .disabled(isStreaming ? (!canSend && streamingMode == .off) : (!canSend || isBusy))
        .accessibilityLabel(
            isStreaming
                ? (canSend ? (streamingMode == .queue ? "排队发送" : "插话") : "停止生成")
                : (imageMode ? "生成图片" : "发送")
        )
    }

    private var buttonFill: AnyShapeStyle {
        if isStreaming || isBusy {
            return AnyShapeStyle(Color.secondary.opacity(0.6))
        }
        return AnyShapeStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
    }

    // MARK: - 开关行

    private var modeRow: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    modeChips
                }
                .padding(.trailing, 4)
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            attachmentButtons
        }
        .padding(.horizontal, 12)
    }

    /// 三个带状态的药丸。
    @ViewBuilder
    private var modeChips: some View {
        Group {
            // 模型放最前：它决定了后面几项是否可用，先看到它更顺。
            // 生图模式下对话模型不参与，隐藏它给图片模型名腾位置。
            if !imageMode {
                modelChip
            }

            modeChip(
                title: "联网",
                systemImage: "globe",
                isOn: webSearchEnabled,
                enabled: webSearchAvailable && !isStreaming,
                action: { onToggleWebSearch(!webSearchEnabled) }
            )

            modeChip(
                title: "生图",
                systemImage: "sparkles",
                isOn: imageMode,
                enabled: imageAvailable && !isStreaming,
                action: { onToggleImageMode(!imageMode) }
            )

            reasoningChip

            if imageMode {
                Text(imageModel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    /// 右侧固定的两个附件入口。
    @ViewBuilder
    private var attachmentButtons: some View {
        // 两个附件入口合成一个加号：模式行要塞下四个药丸，
        // 拆成"文件 + 图片"两个图标就会把「思考」挤出屏幕。
        Button {
            showAttachDialog = true
        } label: {
            Image(systemName: "plus.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(isStreaming || imageMode || (!allowsImage && !allowsDocument))
        .opacity(isStreaming || imageMode ? 0.4 : 1)
        .accessibilityLabel("添加附件")
        .confirmationDialog("添加附件", isPresented: $showAttachDialog) {
            if allowsImage {
                Button("图片") { showPhotoPicker = true }
            }
            if allowsDocument {
                Button("文件") { showFilePicker = true }
            }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $pickerItem, matching: .images)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    onPickImage(data)
                }
                pickerItem = nil
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.pdf, .plainText, .rtf, .data],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result, !urls.isEmpty {
                onPickDocuments(urls)
            }
        }
    }

    /// 模式开关做成药丸：选中态用强调色底，关掉时是可点的灰底——
    /// 比系统 Toggle 的细长开关更适合这条窄行。
    /// 模型：点开是气泡，选完标签跟着变（与思考强度同一套交互）。
    private var modelChip: some View {
        Button {
            showModelPopover.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "cpu")
                Text(modelName.isEmpty ? "模型" : modelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.caption)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(maxWidth: 84)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .disabled(isStreaming)
        .opacity(isStreaming ? 0.45 : 1)
        .accessibilityLabel("模型：\(modelName)")
        .popover(isPresented: $showModelPopover, arrowEdge: .bottom) {
            ModelPopover(
                current: modelName,
                models: models,
                isLoading: isLoadingModels,
                error: modelError,
                onSelect: { name in
                    onSelectModel(name)
                    showModelPopover = false
                },
                onRefresh: onRefreshModels
            )
            .presentationCompactAdaptation(.popover)
            .onAppear {
                if models.isEmpty { onRefreshModels() }
            }
        }
    }

    /// 思考强度：点开是气泡，选完标签跟着变。
    private var reasoningChip: some View {
        Button {
            showReasoningPopover.toggle()
        } label: {
            Label(reasoningTitle, systemImage: "brain")
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        reasoning == nil
                            ? Color.primary.opacity(0.06)
                            : Color.accentColor.opacity(0.16)
                    )
                )
                .foregroundStyle(reasoning == nil ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(!reasoningEnabled || isStreaming)
        .opacity(reasoningEnabled ? 1 : 0.45)
        .accessibilityLabel("思考强度：\(reasoningTitle)")
        .popover(isPresented: $showReasoningPopover, arrowEdge: .bottom) {
            ReasoningPopover(selection: reasoning) { level in
                onSelectReasoning(level)
                showReasoningPopover = false
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private var reasoningTitle: String {
        guard let reasoning else { return "思考" }
        switch reasoning {
        case .minimal: return "思考·最低"
        case .low: return "思考·低"
        case .medium: return "思考·中"
        case .high: return "思考·高"
        }
    }

    private func modeChip(
        title: String,
        systemImage: String,
        isOn: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(
                        isOn ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)
                    )
                )
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.15), value: isOn)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// skill 选择气泡。
struct SkillPopover: View {
    let skills: [SkillSummary]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if skills.isEmpty {
                    Text("还没有 skill。\n在设置 → Skill 里放入 SKILL.md。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(12)
                }

                ForEach(skills) { skill in
                    Button {
                        onSelect(skill.name)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(skill.name)
                                .font(.caption.monospaced())
                                .foregroundStyle(.primary)
                            Text(skill.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 260)
        .frame(maxHeight: 320)
    }
}

/// 思考强度选择气泡。
struct ReasoningPopover: View {
    let selection: ReasoningEffort?
    let onSelect: (ReasoningEffort?) -> Void

    private var levels: [(title: String, detail: String, value: ReasoningEffort?)] {
        [
            ("关闭", "不下发思考参数，由厂商默认", nil),
            ("最低", "只做最少思考，最快", .minimal),
            ("低", "简单问题够用", .low),
            ("中", "默认档位", .medium),
            ("高", "难题、需要多步推理", .high)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                Button {
                    onSelect(level.value)
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(level.title).font(.caption)
                            Text(level.detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == level.value {
                            Image(systemName: "checkmark")
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 220)
    }
}

/// 模型选择气泡。
struct ModelPopover: View {
    let current: String
    let models: [ModelInfo]
    let isLoading: Bool
    let error: String?
    let onSelect: (String) -> Void
    let onRefresh: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("模型")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: onRefresh) {
                    if isLoading {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel("重新拉取模型列表")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if models.isEmpty, !isLoading {
                Text("还没有列表。点右上角刷新，或在设置里手填模型名。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(12)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        // 当前模型即使不在列表里也要显示，否则用户看不出自己选了什么。
                        ForEach(entries, id: \.self) { name in
                            Button {
                                onSelect(name)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(name)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                    if name == current {
                                        Image(systemName: "checkmark")
                                            .font(.caption2)
                                            .foregroundStyle(.tint)
                                    }
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 260)
    }

    private var entries: [String] {
        var names = models.map(\.id)
        if !current.isEmpty, !names.contains(current) {
            names.insert(current, at: 0)
        }
        return names
    }
}
