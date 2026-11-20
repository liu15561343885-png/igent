import AgentKit
import CoreKit
import Foundation
import Observation
import StorageKit

extension AppEnvironment {
    /// skill 目录：`Documents/Skills`，开文件共享后可在访达里直接编辑。
    static var skillsRoot: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return documents.appendingPathComponent("Skills", isDirectory: true)
    }

    /// 常驻 skill 的名字集合，存 UserDefaults 就够——它属于用户偏好，不是内容。
    var alwaysSkillNames: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "alwaysSkills") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "alwaysSkills") }
    }

    func reloadSkills() async {
        _ = try? FileManager.default.createDirectory(
            at: Self.skillsRoot,
            withIntermediateDirectories: true
        )
        Self.seedSampleSkillIfNeeded(at: Self.skillsRoot)

        let summaries = await skillRegistry.reload()
        let definitions = await skillRegistry.definitions(named: summaries.map(\.name))
        skillDefinitions = Dictionary(
            definitions.map { ($0.summary.name, $0) },
            uniquingKeysWith: { _, last in last }
        )
        skillSummaries = summaries
    }

    /// 首轮消息可能触发的自动路由。
    func routedSkillNames(for text: String) -> [String] {
        KeywordSkillRouter().route(text, candidates: skillSummaries)
    }

    /// 本轮要注入的 skill：常驻 + 手动指定（或自动路由结果）。
    func resolveSkills(pending: SkillDefinition?, text: String) -> [SkillDefinition] {
        var names = alwaysSkillNames
        if let pending {
            names.insert(pending.summary.name)
        } else {
            names.formUnion(routedSkillNames(for: text))
        }

        var seen = Set<String>()
        return names
            .sorted()
            .compactMap { name -> SkillDefinition? in
                guard seen.insert(name).inserted else { return nil }
                return skillDefinitions[name]
            }
    }

    /// 首次启动写一个示例 skill，不然这个功能藏得太深。
    private static func seedSampleSkillIfNeeded(at root: URL) {
        let sample = root.appendingPathComponent("concise-reply", isDirectory: true)
        let file = sample.appendingPathComponent("SKILL.md")
        guard !FileManager.default.fileExists(atPath: file.path) else { return }

        try? FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
        let content = """
        ---
        name: concise-reply
        description: 回答尽量简洁，先给结论
        when_to_use: 用户说"简短点""别废话""一句话"
        invocation: [auto, manual]
        ---

        回答时先给结论，再给必要的理由。

        - 除非用户明确要求，否则不超过五行。
        - 不要复述问题，不要写"当然可以"这类开场。
        - 需要展开时先给一句摘要，再问用户要不要展开。
        """
        try? content.write(to: file, atomically: true, encoding: .utf8)
    }
}
