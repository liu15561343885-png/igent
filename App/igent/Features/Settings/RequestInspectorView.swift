import LLMKit
import SwiftUI

/// 请求检查器：把"发了什么、回来什么"摊开给你看。
///
/// 多厂商适配最常见的失败是配置问题（少个 `/v1`、模型名拼错、密钥头写错），
/// 这些在普通错误提示里都只显示成"请求失败"。这里能直接看到原文。
struct RequestInspectorView: View {
    @Environment(AppEnvironment.self) private var env

    @State private var traces: [RequestTrace] = []
    @State private var selected: RequestTrace?

    var body: some View {
        List {
            if traces.isEmpty {
                ContentUnavailableView(
                    "还没有请求",
                    systemImage: "waveform.path.ecg",
                    description: Text("发一条消息后，这里会出现完整的请求痕迹。")
                )
            }

            ForEach(traces) { trace in
                Button {
                    selected = trace
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Text(trace.provider)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(statusLabel(trace))
                                .font(.caption.monospaced())
                                .foregroundStyle(statusColor(trace))
                        }
                        Text(trace.url)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        HStack(spacing: 10) {
                            Text(trace.startedAt, format: .dateTime.hour().minute().second())
                            if let duration = trace.duration {
                                Text(String(format: "%.2fs", duration))
                            }
                            Text("\(trace.receivedBytes) B")
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .navigationTitle("请求记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("清空") {
                    Task {
                        await env.requestLog.clear()
                        await refresh()
                    }
                }
                .disabled(traces.isEmpty)
            }
        }
        .task { await refresh() }
        .refreshable { await refresh() }
        .sheet(item: $selected) { trace in
            RequestDetailView(trace: trace)
        }
    }

    private func refresh() async {
        traces = await env.requestLog.all()
    }

    private func statusLabel(_ trace: RequestTrace) -> String {
        if let failure = trace.failure { return failure.code.rawValue }
        if let status = trace.statusCode { return "HTTP \(status)" }
        return "OK"
    }

    private func statusColor(_ trace: RequestTrace) -> Color {
        if trace.failure != nil { return .red }
        if let status = trace.statusCode, !(200..<300).contains(status) { return .orange }
        return .green
    }
}

struct RequestDetailView: View {
    let trace: RequestTrace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("概览") {
                    row("厂商", trace.provider)
                    row("方法", trace.method)
                    row("状态", trace.failure?.code.rawValue ?? trace.statusCode.map(String.init) ?? "OK")
                    row("耗时", trace.duration.map { String(format: "%.2fs", $0) } ?? "—")
                    row("接收", "\(trace.receivedBytes) B")
                }

                Section("URL") {
                    Text(trace.url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }

                Section("请求头（已脱敏）") {
                    ForEach(trace.headers.sorted(by: { $0.key < $1.key }), id: \.key) { key, value in
                        HStack(alignment: .top) {
                            Text(key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(value)
                                .font(.caption.monospaced())
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }

                if !trace.bodyPreview.isEmpty {
                    Section("请求体") {
                        Text(trace.bodyPreview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if !trace.responsePreview.isEmpty {
                    Section("响应原文（前 4KB）") {
                        Text(trace.responsePreview)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }

                if let failure = trace.failure {
                    Section("失败") {
                        Text(failure.message)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("请求详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.callout.monospaced())
        }
    }
}
