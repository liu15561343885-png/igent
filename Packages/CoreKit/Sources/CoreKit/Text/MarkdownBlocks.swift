import Foundation

/// Markdown 的块级结构。
///
/// 只做聊天场景真正需要的那部分：段落、标题、代码块、列表、引用、分隔线。
/// 行内格式（加粗、斜体、行内代码、链接）交给系统的 `AttributedString(markdown:)`，
/// 这里只负责把它们正确地切成块——因为系统那个 API 不保留块结构。
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case code(language: String?, content: String)
    case listItem(ordered: Bool, index: Int, text: String)
    case quote(String)
    case divider
}

public enum MarkdownParser {
    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []

        var inCode = false
        var codeLanguage: String?
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let joined = paragraph.joined(separator: "\n")
            blocks.append(.paragraph(joined))
            paragraph.removeAll()
        }

        func flushCode() {
            blocks.append(.code(language: codeLanguage, content: codeLines.joined(separator: "\n")))
            codeLines.removeAll()
            codeLanguage = nil
        }

        // 统一换行，Windows 风格的行尾也能正确切分。
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for rawLine in lines {
            let line = rawLine
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    flushCode()
                    inCode = false
                } else {
                    flushParagraph()
                    inCode = true
                    let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    codeLanguage = language.isEmpty ? nil : language
                }
                continue
            }

            if inCode {
                codeLines.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
                continue
            }

            if let heading = parseHeading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                continue
            }

            if isDivider(trimmed) {
                flushParagraph()
                blocks.append(.divider)
                continue
            }

            if let item = parseListItem(trimmed) {
                flushParagraph()
                blocks.append(item)
                continue
            }

            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                blocks.append(.quote(String(trimmed.dropFirst(trimmed == ">" ? 1 : 2))))
                continue
            }

            paragraph.append(line)
        }

        // 未闭合的代码块按代码处理：宁可多显示，也不要吞掉用户看到的内容。
        if inCode {
            flushCode()
        }
        flushParagraph()
        return blocks
    }

    private static func parseHeading(_ line: String) -> MarkdownBlock? {
        var level = 0
        for character in line {
            if character == "#" { level += 1 } else { break }
        }
        guard level > 0, level <= 6 else { return nil }
        let rest = line.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, text: rest.trimmingCharacters(in: .whitespaces))
    }

    private static func isDivider(_ line: String) -> Bool {
        let stripped = line.replacingOccurrences(of: " ", with: "")
        guard stripped.count >= 3 else { return false }
        return stripped.allSatisfy { $0 == "-" }
            || stripped.allSatisfy { $0 == "*" }
            || stripped.allSatisfy { $0 == "_" }
    }

    private static func parseListItem(_ line: String) -> MarkdownBlock? {
        if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ") {
            return .listItem(ordered: false, index: 0, text: String(line.dropFirst(2)))
        }

        // 有序列表：`1. 内容`
        var digits = ""
        var rest = Substring(line)
        while let first = rest.first, first.isNumber {
            digits.append(first)
            rest = rest.dropFirst()
        }
        guard !digits.isEmpty, rest.hasPrefix(". "), let index = Int(digits) else { return nil }
        return .listItem(ordered: true, index: index, text: String(rest.dropFirst(2)))
    }
}
