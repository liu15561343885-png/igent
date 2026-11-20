import CoreKit
import SwiftUI

struct ContentView: View {
    @State private var probe = "检测中…"

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)
                    Text("CoreKit 已链接")
                        .font(.subheadline.weight(.medium))
                }

                Text(probe)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Spacer()

                Text("P0 骨架：词汇 + 装配器 + SSE 解码器")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationTitle("igent")
        }
        .task {
            probe = Self.check()
        }
    }

    /// 用 CoreKit 走一遍「字节 → SSE 帧 → StreamChunk → 内容块」，
    /// 验证本地包链接正确、且能在运行时真正跑通。
    static func check() -> String {
        var decoder = SSEDecoder()
        let events = decoder.feed(Array("data: 你好，世界\n\n".utf8))
        guard let payload = events.first?.data else {
            return "SSE 解码失败"
        }

        var assembler = BlockAssembler()
        assembler.push(.textDelta(index: 0, text: payload))
        assembler.push(.usage(TokenUsage(uncachedInputTokens: 12, outputTokens: 4)))
        assembler.push(.finish(.stop, meta: nil))

        let blocks = (try? assembler.blocks()) ?? []
        let text = blocks.map(\.plainText).joined()
        return "SSE → \(events.count) 帧\n装配 → \(blocks.count) 块：\(text)"
    }
}

#Preview {
    ContentView()
}
