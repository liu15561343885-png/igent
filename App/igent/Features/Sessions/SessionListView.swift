import CoreKit
import SwiftUI

struct SessionListView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let currentSessionID: SessionID

    @State private var sessions: [SessionSummary] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task {
                            await env.startNewSession()
                            dismiss()
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
                                dismiss()
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
            .navigationTitle("会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        sessions = (try? await env.store.sessions()) ?? []
    }
}
