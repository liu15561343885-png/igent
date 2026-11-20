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
                            onDelete: {
                                Task {
                                    await env.delete(session: session)
                                    await refresh()
                                }
                            }
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

    private func refresh() async {
        sessions = (try? await env.store.sessions()) ?? []
    }
}

/// 单个会话卡片。左滑露出删除，长按也能删。
private struct SessionCardRow: View {
    let session: SessionSummary
    let isCurrent: Bool
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var offset: CGFloat = 0

    var body: some View {
        ZStack(alignment: .trailing) {
            // 卡片被拖开后露出的删除底
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red.opacity(offset < -8 ? 0.9 : 0))
                .overlay(alignment: .trailing) {
                    Image(systemName: "trash")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.trailing, 18)
                        .opacity(offset < -8 ? 1 : 0)
                }

            card
                .offset(x: offset)
                .gesture(
                    DragGesture(minimumDistance: 12)
                        .onChanged { value in
                            offset = min(0, value.translation.width)
                        }
                        .onEnded { value in
                            if value.translation.width < -80 {
                                withAnimation(.easeOut(duration: 0.18)) { offset = -400 }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: onDelete)
                            } else {
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                                    offset = 0
                                }
                            }
                        }
                )
                .onTapGesture {
                    if offset < -8 {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) { offset = 0 }
                    } else {
                        onOpen()
                    }
                }
                .contextMenu {
                    Button("删除", role: .destructive, action: onDelete)
                }
        }
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
}
