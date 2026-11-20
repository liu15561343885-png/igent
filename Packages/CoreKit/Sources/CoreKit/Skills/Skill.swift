import Foundation

/// 什么时候允许激活这个 skill。
public struct SkillInvocation: OptionSet, Codable, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// 用户手动选。
    public static let manual = SkillInvocation(rawValue: 1 << 0)
    /// 首轮按关键词自动路由。
    public static let auto = SkillInvocation(rawValue: 1 << 1)
    /// 常驻，每轮都注入。
    public static let always = SkillInvocation(rawValue: 1 << 2)

    public static let `default`: SkillInvocation = [.manual, .auto]

    var names: [String] {
        var result: [String] = []
        if contains(.manual) { result.append("manual") }
        if contains(.auto) { result.append("auto") }
        if contains(.always) { result.append("always") }
        return result
    }
}

public enum SkillSource: String, Codable, Sendable {
    case user
    case bundled
}

public struct SkillSummary: Codable, Sendable, Equatable, Identifiable {
    public var name: String
    public var description: String
    public var whenToUse: String?
    public var invocation: SkillInvocation
    public var source: SkillSource
    /// 粗略估算，仅用于界面提示"这个 skill 大概占多少上下文"。
    public var tokenEstimate: Int

    public var id: String { name }

    public init(
        name: String,
        description: String,
        whenToUse: String? = nil,
        invocation: SkillInvocation = .default,
        source: SkillSource = .user,
        tokenEstimate: Int = 0
    ) {
        self.name = name
        self.description = description
        self.whenToUse = whenToUse
        self.invocation = invocation
        self.source = source
        self.tokenEstimate = tokenEstimate
    }
}

public struct SkillDefinition: Sendable, Equatable, Identifiable {
    public var summary: SkillSummary
    public var body: String
    /// frontmatter 的 `include` 声明，键是相对路径，值是文件内容。
    public var resources: [String: String]

    public var id: String { summary.name }

    public init(summary: SkillSummary, body: String, resources: [String: String] = [:]) {
        self.summary = summary
        self.body = body
        self.resources = resources
    }

    /// 注入给模型的完整文本：正文 + 声明的随附文件。
    public var renderedContent: String {
        guard !resources.isEmpty else { return body }
        var text = body
        for path in resources.keys.sorted() {
            text += "\n\n## 参考文件：\(path)\n\n" + (resources[path] ?? "")
        }
        return text
    }
}

// MARK: - 解析

public enum SkillParseError: Error, Equatable {
    case missingFrontmatter
    case invalidName(String)
    case missingDescription
}

public enum SkillParser {
    /// 拆出 frontmatter 与正文。没有 frontmatter 返回 nil。
    public static func split(_ text: String) -> (frontmatter: [String: String], body: String)? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard normalized.hasPrefix("---\n") else { return nil }

        let rest = normalized.dropFirst(4)
        guard let closing = rest.range(of: "\n---") else { return nil }

        let header = String(rest[..<closing.lowerBound])
        var body = String(rest[closing.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }

        var fields: [String: String] = [:]
        for line in header.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            fields[key] = value
        }
        return (fields, body)
    }

    /// 解析列表值：`[a, b]` 或 `a, b`。
    public static func list(_ value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }
        var trimmed = value
        if trimmed.hasPrefix("[") { trimmed.removeFirst() }
        if trimmed.hasSuffix("]") { trimmed.removeLast() }
        return trimmed
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func parse(_ text: String, source: SkillSource = .user) throws -> SkillDefinition {
        guard let (fields, body) = split(text) else {
            throw SkillParseError.missingFrontmatter
        }
        guard let name = fields["name"], isValidName(name) else {
            throw SkillParseError.invalidName(fields["name"] ?? "")
        }
        guard let description = fields["description"], !description.isEmpty else {
            throw SkillParseError.missingDescription
        }

        let invocation = parseInvocation(fields["invocation"])
        let summary = SkillSummary(
            name: name,
            description: description,
            whenToUse: fields["when_to_use"],
            invocation: invocation,
            source: source,
            tokenEstimate: estimateTokens(body)
        )
        return SkillDefinition(summary: summary, body: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// kebab-case：小写字母/数字，单词间用单个连字符。
    public static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty else { return false }
        let pattern = "^[a-z0-9]+(-[a-z0-9]+)*$"
        return name.range(of: pattern, options: .regularExpression) != nil
    }

    static func parseInvocation(_ value: String?) -> SkillInvocation {
        let items = list(value)
        guard !items.isEmpty else { return .default }
        var result: SkillInvocation = []
        for item in items {
            switch item.lowercased() {
            case "manual": result.insert(.manual)
            case "auto": result.insert(.auto)
            case "always": result.insert(.always)
            default: break
            }
        }
        return result.isEmpty ? .default : result
    }

    /// 粗估：中文约 1.5 字/token，英文约 4 字符/token，取个中位数。
    static func estimateTokens(_ text: String) -> Int {
        max(1, Int(Double(text.count) / 2.5))
    }
}

// MARK: - 渲染

public enum SkillRenderer {
    /// 目录：告诉模型"有哪些 skill"，但不含正文。
    public static func catalog(_ summaries: [SkillSummary]) -> String {
        guard !summaries.isEmpty else { return "" }
        var lines = ["<available_skills>"]
        for summary in summaries {
            lines.append("- \(summary.name): \(summary.description)")
        }
        lines.append("</available_skills>")
        return lines.joined(separator: "\n")
    }

    /// 注入：把正文包进标记里。name 做转义，正文原样嵌入（本地可信内容）。
    public static func skillContent(_ definition: SkillDefinition) -> String {
        let name = escapeAttribute(definition.summary.name)
        return """
        <skill_content name="\(name)">
        \(definition.renderedContent)
        </skill_content>
        """
    }

    /// 拼成 system 文本。多个 skill 按给定顺序拼接。
    public static func system(_ definitions: [SkillDefinition]) -> String? {
        guard !definitions.isEmpty else { return nil }
        return definitions.map { skillContent($0) }.joined(separator: "\n\n")
    }

    static func escapeAttribute(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
