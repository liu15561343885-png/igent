import CoreKit
import SwiftUI

/// 把 Markdown 渲染成聊天气泡里的样子。
///
/// 块结构由 `MarkdownParser` 切分；行内格式（加粗、斜体、行内代码、链接）
/// 交给系统的 `AttributedString(markdown:)`——它不保留块结构，所以两者配合使用。
struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownParser.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case let .paragraph(content):
            Text(attributed(content))
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

        case let .heading(level, content):
            Text(attributed(content))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level == 1 ? 2 : 0)
                .fixedSize(horizontal: false, vertical: true)

        case let .code(language, content):
            codeBlock(language: language, content: content)

        case let .listItem(ordered, index, content):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(ordered ? "\(index)." : "•")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(attributed(content))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case let .quote(content):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                Text(attributed(content))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .divider:
            Divider().opacity(0.5)
        }
    }

    private func codeBlock(language: String?, content: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language?.lowercased() ?? "code")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = content
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("复制代码")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title3
        case 2: .headline
        default: .subheadline
        }
    }

    /// 解析失败时退回纯文本，绝不让一条消息因为格式问题渲染成空白。
    private func attributed(_ string: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: string, options: options)) ?? AttributedString(string)
    }
}
