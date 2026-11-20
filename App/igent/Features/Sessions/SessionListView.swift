import CoreKit
import SwiftUI
import UIKit

struct SessionListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let currentSessionID: SessionID
    /// 抽屉里用它关闭；作为 sheet 时回退到 dismiss。
    var onClose: (() -> Void)?

    @State private var sessions: [SessionSummary] = []

    private static var topSafeInset: CGFloat {
        (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 59
    }

    private func close() {
        if let onClose { onClose() } else { dismiss() }
    }

    var body: some View {
        if onClose != nil {
            drawerBody
        } else {
            sheetBody
        }
    }

    /// 抽屉模式：自己画标题栏，不套 NavigationStack——
    /// 套了会把「完成」按钮挤到抽屉外面，顶部还会被导航栏占掉一截。
    private var drawerBody: some View {
        VStack(spacing: 0) {
            header
            cardList
        }
        .task { await refresh() }
    }

    private var sheetBody: some View {
        NavigationStack {
            cardList
                .navigationTitle("会话")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("完成") { close() }
                    }
                }
                .task { await refresh() }
        }
    }

    private var header: some View {
        HStack {
            Text("会话")
                .font(.system(size: 22, weight: .semibold))
            Spacer()
            Button("完成") { close() }
                .font(.subheadline.weight(.medium))
        }
        .padding(.horizontal, 18)
        // 抽屉跨满整屏，得自己避开状态栏/灵动岛。
        .padding(.top, Self.topSafeInset + 6)
        .padding(.bottom, 12)
    }

    /// 每个会话一张独立卡片：套在 List 里时行与行是连成一片的，
    /// 窄抽屉里看起来像一整块白板，分不清条目边界。
    private var cardList: some View {
        ScrollView {
            VStack(spacing: 8) {
                newSessionCard

                if !sessions.isEmpty {
                    HStack {
                        // 之前用 .secondary，在浅色玻璃上几乎看不见；
                        // 改为更实的深灰 + 条数，兼作"有多少条"的提示。
                        Text("历史 \(sessions.count)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary.opacity(0.5))
                        Spacer()
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                    ForEach(sessions) { session in
                        SessionCardRow(
                            session: session,
                            isCurrent: session.id == currentSessionID,
                            onOpen: {
                                Task {
                                    await env.open(session: session)
                                    close()
                                }
                            },
                            onDelete: { delete(session) }
                        )
                        // 移除时收缩+淡出，而不是整行瞬间消失。
                        .transition(
                            .asymmetric(
                                insertion: .opacity,
                                removal: .scale(scale: 0.88, anchor: .center).combined(with: .opacity)
                            )
                        )
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var newSessionCard: some View {
        Button {
            Task {
                await env.startNewSession()
                close()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil")
                Text("新建对话")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5)
            )
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
    }

    /// 先从本地数组移除（触发收缩动画），再异步落库。
    /// 直接 `refresh()` 会让整行"啪"地消失，没有任何过渡。
    private func delete(_ session: SessionSummary) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            sessions.removeAll { $0.id == session.id }
        }
        Task { await env.delete(session: session) }
    }

    private func refresh() async {
        sessions = (try? await env.store.sessions()) ?? []
    }
}

/// 单个会话卡片。左滑露出删除按钮，点它才真正删除；点卡片本体收回。
private struct SessionCardRow: View {
    let session: SessionSummary
    let isCurrent: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isOpen = false

    private let revealWidth: CGFloat = 88

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteButton
            card
                .offset(x: offset)
                .gesture(dragGesture)
                .onTapGesture {
                    if isOpen { closeReveal() } else { onOpen() }
                }
                .contextMenu {
                    Button("删除", role: .destructive) {
                        onDelete()
                    }
                }
        }
    }

    private var deleteButton: some View {
        Button {
            guard isOpen else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onDelete()
        } label: {
            Image(systemName: "trash.fill")
                .font(.subheadline)
                .foregroundStyle(.white)
                .frame(width: revealWidth)
                .frame(maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red)
        )
        .opacity(offset < -2 ? 1 : 0)
        .allowsHitTesting(isOpen)
        .accessibilityLabel("删除会话")
    }

    private var card: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(session.updatedAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isCurrent
                        ? AnyShapeStyle(Color.accentColor.opacity(0.14))
                        : AnyShapeStyle(Color(.secondarySystemGroupedBackground))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isCurrent ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.12),
                    lineWidth: 0.5
                )
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let base = isOpen ? -revealWidth : 0
                offset = min(0, max(-revealWidth - 24, base + value.translation.width))
            }
            .onEnded { _ in
                // 越过一半就吸附到"露出"状态，否则弹回——比"一滑到底直接删"可控得多。
                if offset < -revealWidth * 0.55 {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                        offset = -revealWidth
                        isOpen = true
                    }
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred()
                } else {
                    closeReveal()
                }
            }
    }

    private func closeReveal() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.86)) {
            offset = 0
            isOpen = false
        }
    }
}
