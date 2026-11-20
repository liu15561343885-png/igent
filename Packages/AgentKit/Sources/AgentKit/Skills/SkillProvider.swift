import CoreKit
import Foundation

/// 从目录里读 skill：`<root>/<name>/SKILL.md`（目录型）或 `<root>/<name>.md`（扁平型）。
///
/// 目录放在 App 沙盒的 `Documents/Skills`。开了文件共享之后，
/// 可以在「文件」App 或 Mac 访达里直接编辑——用电脑写 skill、手机上用，比在手机上敲 Markdown 舒服得多。
public struct FileSystemSkillProvider: Sendable {
    public let root: URL
    private let maxResourceBytes: Int

    public init(root: URL, maxResourceBytes: Int = 64 * 1024) {
        self.root = root
        self.maxResourceBytes = maxResourceBytes
    }

    public func scan() async -> [SkillDefinition] {
        let fileManager = FileManager.default
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [SkillDefinition] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false

            if isDirectory {
                let file = entry.appendingPathComponent("SKILL.md")
                guard fileManager.fileExists(atPath: file.path) else { continue }
                if let skill = load(file: file, source: .user, base: entry) {
                    results.append(skill)
                }
            } else if entry.pathExtension.lowercased() == "md" {
                if let skill = load(file: entry, source: .user, base: entry.deletingLastPathComponent()) {
                    results.append(skill)
                }
            }
        }
        return results
    }

    private func load(file: URL, source: SkillSource, base: URL) -> SkillDefinition? {
        guard let data = try? Data(contentsOf: file),
              data.count <= maxResourceBytes * 4,
              let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        guard var skill = try? SkillParser.parse(text, source: source) else { return nil }

        // 只有 frontmatter 里显式声明的随附文件才会被注入。
        // 无工具模式下模型没法自己去读文件，所以这里必须"要么给全，要么不给"。
        if let fields = SkillParser.split(text)?.frontmatter,
           let include = fields["include"] {
            var resources: [String: String] = [:]
            for path in SkillParser.list(include) {
                let resourceURL = base.appendingPathComponent(path)
                guard resourceURL.path.hasPrefix(base.path),
                      let data = try? Data(contentsOf: resourceURL),
                      data.count <= maxResourceBytes,
                      let content = String(data: data, encoding: .utf8)
                else { continue }
                resources[path] = content
            }
            skill.resources = resources
        }
        return skill
    }
}

/// 已加载的 skill 集合。按名字去重，重名时后来者覆盖（用户目录优先于内置）。
public actor SkillRegistry {
    private var definitions: [String: SkillDefinition] = [:]
    private var provider: FileSystemSkillProvider

    public init(provider: FileSystemSkillProvider) {
        self.provider = provider
    }

    public func update(provider: FileSystemSkillProvider) {
        self.provider = provider
    }

    @discardableResult
    public func reload() async -> [SkillSummary] {
        let loaded = await provider.scan()
        definitions = Dictionary(loaded.map { ($0.summary.name, $0) }, uniquingKeysWith: { _, last in last })
        return summaries()
    }

    public func summaries() -> [SkillSummary] {
        definitions.values.map(\.summary).sorted { $0.name < $1.name }
    }

    public func definition(named name: String) -> SkillDefinition? {
        definitions[name]
    }

    public func definitions(named names: [String]) -> [SkillDefinition] {
        names.compactMap { definitions[$0] }
    }
}

/// skill 自动路由。
///
/// 不用模型来判断：多一次调用就多一次延迟和不确定性，而 skill 的触发条件本来就写在
/// `when_to_use` 里。关键词匹配在这个场景里既够用又可预测。
public protocol SkillRouter: Sendable {
    func route(_ text: String, candidates: [SkillSummary], limit: Int) -> [String]
}

public struct KeywordSkillRouter: SkillRouter {
    /// 名字命中权重最高，其次是 when_to_use，最后是描述。
    private let nameWeight = 3
    private let whenWeight = 2
    private let descriptionWeight = 1
    private let threshold = 2

    public init() {}

    public func route(_ text: String, candidates: [SkillSummary], limit: Int = 2) -> [String] {
        let haystack = text.lowercased()
        var scored: [(name: String, score: Int)] = []

        for candidate in candidates where candidate.invocation.contains(.auto) {
            var score = 0
            if haystack.contains(candidate.name.lowercased())
                || haystack.contains(candidate.name.replacingOccurrences(of: "-", with: " ")) {
                score += nameWeight
            }
            score += hits(in: haystack, probes: probes(from: candidate.whenToUse)) * whenWeight
            score += hits(in: haystack, probes: probes(from: candidate.description)) * descriptionWeight

            if score >= threshold {
                scored.append((candidate.name, score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.name)
    }

    private func probes(from value: String?) -> [String] {
        guard let value, !value.isEmpty else { return [] }

        let separators = CharacterSet(charactersIn: " \t\n，。、；：？！,.;:?!\"'“”‘’（）()[]【】<>/\\|-")
        var result: [String] = []

        for token in value.components(separatedBy: separators) {
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else { continue }

            if trimmed.containsCJK {
                // 中文没有空格，"用户提到周报" 是一个整词，而用户输入里往往只有"周报"。
                // 所以切成 2~3 字的 n-gram 去匹配，匹配到的片段越多分越高。
                result += ngrams(of: trimmed, sizes: 2...3)
            } else {
                result.append(trimmed.lowercased())
            }
        }
        return result
    }

    private func ngrams(of text: String, sizes: ClosedRange<Int>) -> [String] {
        let characters = Array(text)
        var result: [String] = []
        for size in sizes where characters.count >= size {
            for start in 0...(characters.count - size) {
                result.append(String(characters[start..<(start + size)]))
            }
        }
        return result
    }

    private func hits(in haystack: String, probes: [String]) -> Int {
        probes.reduce(0) { count, probe in
            haystack.contains(probe.lowercased()) ? count + 1 : count
        }
    }
}


extension String {
    /// 是否含中日韩统一表意文字。用来决定要不要走 n-gram 匹配。
    var containsCJK: Bool {
        unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
    }
}
