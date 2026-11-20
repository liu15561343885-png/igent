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
            HStack {
                Text("会话")
                    .font(.headline)
                Spacer()
                Button("完成") { close() }
                    .font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()

            listContent
        }
        .task { await refresh() }
    }

    private var sheetBody: some View {
        NavigationStack {
            listContent
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

    @ViewBuilder
    private var listContent: some View {
        List {
                Section {
                    Button {
                        Task {
                            await env.startNewSession()
                            close()
                        }
                    } label: {
                        Label("新建对话", systemImage: "square.and.pencil")
                    }
                }

                Section("历史") {
                    ForEach(sessions) { session in
                        Button {
                            Task {
                                await env.open(session: session)
                                close()
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(session.title)
                                        .foregroundStyle(.primary)
                                    Text(session.updatedAt, format: .dateTime.month().day().hour().minute())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if session.id == currentSessionID {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                    .onDelete { offsets in
                        Task {
                            for index in offsets {
                                await env.delete(session: sessions[index])
                            }
                            await refresh()
                        }
                    }
                }
            }
    }

    private func refresh() async {
        sessions = (try? await env.store.sessions()) ?? []
    }
}
