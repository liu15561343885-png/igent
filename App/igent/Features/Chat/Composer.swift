import CoreKit
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
    var onPickDocuments: ([URL]) -> Void
    var onRemoveDocument: (UUID) -> Void

    @FocusState private var isFocused: Bool
    @State private var pickerItem: PhotosPickerItem?
    @State private var showSkillPopover = false
    @State private var showFilePicker = false

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || pendingImage != nil
            || !pendingDocuments.isEmpty
    }

    private var placeholder: String {
        imageMode ? "描述你想要的画面…" : "发消息…"
    }

    var body: some View {
        VStack(spacing: 8) {
            attachmentPreview
            documentPreview
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
                .disabled(isStreaming || isBusy)

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
        Button {
            if isStreaming {
                onStop()
            } else {
                onSend()
            }
        } label: {
            Group {
                if isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: isStreaming ? "stop.fill" : "arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 32, height: 32)
            .background(Circle().fill(buttonFill))
        }
        .buttonStyle(.plain)
        .disabled(!isStreaming && (!canSend || isBusy))
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isStreaming)
        .accessibilityLabel(isStreaming ? "停止生成" : (imageMode ? "生成图片" : "发送"))
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
            modeChip(
                title: "联网搜索",
                systemImage: "globe",
                isOn: webSearchEnabled,
                enabled: webSearchAvailable && !isStreaming,
                action: { onToggleWebSearch(!webSearchEnabled) }
            )

            modeChip(
                title: "生成图片",
                systemImage: "sparkles",
                isOn: imageMode,
                enabled: imageAvailable && !isStreaming,
                action: { onToggleImageMode(!imageMode) }
            )

            if imageMode {
                Text(imageModel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if allowsDocument && !isStreaming && !imageMode {
                Button {
                    showFilePicker = true
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("添加文件")
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

            if allowsImage && !isStreaming && !imageMode {
                PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("添加图片")
                .onChange(of: pickerItem) { _, item in
                    guard let item else { return }
                    Task {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            onPickImage(data)
                        }
                        pickerItem = nil
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    /// 模式开关做成药丸：选中态用强调色底，关掉时是可点的灰底——
    /// 比系统 Toggle 的细长开关更适合这条窄行。
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
                .padding(.horizontal, 10)
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
