import CoreKit
import PhotosUI
import SwiftUI

/// 底部输入条：可带一张图、随内容增高、流式时变成停止按钮。
struct Composer: View {
    @Binding var text: String
    var isStreaming: Bool
    var pendingImage: ImageAttachmentRef?
    /// 当前模型是否支持视觉。不支持时不显示相册按钮，避免用户白传。
    var allowsImage: Bool
    /// 联网检索开关状态与可用性。
    var webSearchEnabled: Bool
    var webSearchAvailable: Bool
    var isSearching: Bool
    var onToggleWebSearch: () -> Void
    var onSend: () -> Void
    var onStop: () -> Void
    var onPickImage: (Data) -> Void
    var onRemoveImage: () -> Void

    @FocusState private var isFocused: Bool
    @State private var pickerItem: PhotosPickerItem?

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil
    }

    var body: some View {
        VStack(spacing: 8) {
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
                .padding(.horizontal, 12)
                .padding(.top, 8)
            }

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

            HStack(alignment: .bottom, spacing: 10) {
                if webSearchAvailable && !isStreaming {
                    Button(action: onToggleWebSearch) {
                        Image(systemName: "globe")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(webSearchEnabled ? Color.accentColor : .secondary)
                            .frame(width: 32, height: 32)
                            .background(
                                Circle().fill(
                                    webSearchEnabled
                                        ? Color.accentColor.opacity(0.14)
                                        : Color.clear
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .animation(.easeOut(duration: 0.15), value: webSearchEnabled)
                    .accessibilityLabel(webSearchEnabled ? "关闭联网检索" : "开启联网检索")
                }

                if allowsImage && !isStreaming {
                    PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                        Image(systemName: "photo")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
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
        }
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }
}
