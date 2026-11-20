import CoreKit
import Foundation
import XCTest
@testable import AgentKit

final class FileSystemSkillProviderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("igent-skills-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ path: String, _ content: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testScansDirectoryAndFlatLayouts() async throws {
        try write("weekly-report/SKILL.md", """
        ---
        name: weekly-report
        description: 整理周报
        ---
        正文
        """)
        try write("plain.md", """
        ---
        name: plain
        description: 扁平布局
        ---
        正文
        """)

        let provider = FileSystemSkillProvider(root: root)
        let skills = await provider.scan()
        XCTAssertEqual(skills.map(\.summary.name).sorted(), ["plain", "weekly-report"])
    }

    func testIgnoresInvalidSkillFiles() async throws {
        try write("bad/SKILL.md", "没有 frontmatter")
        try write("Bad_Name/SKILL.md", """
        ---
        name: Bad_Name
        description: 名字不合法
        ---
        正文
        """)
        try write("good/SKILL.md", """
        ---
        name: good
        description: 合法
        ---
        正文
        """)

        let skills = await FileSystemSkillProvider(root: root).scan()
        XCTAssertEqual(skills.map(\.summary.name), ["good"])
    }

    func testLoadsDeclaredResourcesOnly() async throws {
        try write("with-resources/SKILL.md", """
        ---
        name: with-resources
        description: 带随附文件
        include: [templates/a.md]
        ---
        正文
        """)
        try write("with-resources/templates/a.md", "模板内容")
        try write("with-resources/templates/unlisted.md", "不该被注入")

        let skills = await FileSystemSkillProvider(root: root).scan()
        let skill = try XCTUnwrap(skills.first)
        XCTAssertEqual(skill.resources["templates/a.md"], "模板内容")
        XCTAssertNil(skill.resources["templates/unlisted.md"])
        XCTAssertTrue(skill.renderedContent.contains("模板内容"))
        XCTAssertFalse(skill.renderedContent.contains("不该被注入"))
    }

    /// include 里写 `../` 不能读到目录外面去。
    func testRejectsPathTraversal() async throws {
        try write("escape/SKILL.md", """
        ---
        name: escape
        description: 试图越界
        include: [../../etc/hosts]
        ---
        正文
        """)
        let skills = await FileSystemSkillProvider(root: root).scan()
        XCTAssertTrue(skills.first?.resources.isEmpty ?? false)
    }

    func testMissingRootReturnsEmpty() async {
        let provider = FileSystemSkillProvider(root: root.appendingPathComponent("nope"))
        let skills = await provider.scan()
        XCTAssertTrue(skills.isEmpty)
    }

    func testRegistryReloadAndLookup() async throws {
        try write("a/SKILL.md", """
        ---
        name: alpha
        description: 第一个
        ---
        A
        """)
        let registry = SkillRegistry(provider: FileSystemSkillProvider(root: root))
        let summaries = await registry.reload()

        XCTAssertEqual(summaries.map(\.name), ["alpha"])
        let definition = await registry.definition(named: "alpha")
        XCTAssertEqual(definition?.body, "A")
        let missing = await registry.definition(named: "nope")
        XCTAssertNil(missing)
    }
}

final class KeywordSkillRouterTests: XCTestCase {
    private let router = KeywordSkillRouter()

    private var candidates: [SkillSummary] {
        [
            SkillSummary(name: "weekly-report", description: "整理周报", whenToUse: "用户提到周报 本周总结"),
            SkillSummary(name: "code-review", description: "审查代码", whenToUse: "用户要求 review 代码"),
            SkillSummary(name: "silent", description: "只在手动时用", invocation: [.manual])
        ]
    }

    func testMatchesWhenToUseKeywords() {
        let names = router.route("帮我写一下本周的周报", candidates: candidates)
        XCTAssertEqual(names, ["weekly-report"])
    }

    func testMatchesNameDirectly() {
        let names = router.route("用 code review 看看这段", candidates: candidates)
        XCTAssertTrue(names.contains("code-review"))
    }

    func testUnrelatedTextRoutesNothing() {
        XCTAssertTrue(router.route("今天天气怎么样", candidates: candidates).isEmpty)
    }

    /// 只允许手动激活的 skill 不参与自动路由。
    func testManualOnlySkillsAreNotRouted() {
        XCTAssertTrue(router.route("silent 手动", candidates: candidates).isEmpty)
    }

    func testRespectsLimit() {
        let many = (1...5).map {
            SkillSummary(name: "s\($0)", description: "相同关键词 周报", whenToUse: "周报")
        }
        XCTAssertEqual(router.route("周报", candidates: many, limit: 2).count, 2)
    }
}
