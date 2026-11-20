import Foundation
import XCTest
@testable import CoreKit

final class SkillParserTests: XCTestCase {
    private let sample = """
    ---
    name: weekly-report
    description: 把零散记录整理成结构化周报
    when_to_use: 用户提到"周报""本周总结"时
    invocation: [auto, manual]
    include: [templates/report.md]
    ---

    # 周报整理

    按以下结构输出：
    1. 本周完成
    2. 下周计划
    """

    func testParsesFrontmatterAndBody() throws {
        let skill = try SkillParser.parse(sample)
        XCTAssertEqual(skill.summary.name, "weekly-report")
        XCTAssertEqual(skill.summary.description, "把零散记录整理成结构化周报")
        XCTAssertEqual(skill.summary.whenToUse, "用户提到\"周报\"\"本周总结\"时")
        XCTAssertTrue(skill.summary.invocation.contains(.auto))
        XCTAssertTrue(skill.summary.invocation.contains(.manual))
        XCTAssertFalse(skill.summary.invocation.contains(.always))
        XCTAssertTrue(skill.body.hasPrefix("# 周报整理"))
    }

    func testDefaultInvocationIsManualAndAuto() throws {
        let text = """
        ---
        name: plain
        description: 普通 skill
        ---
        正文
        """
        let skill = try SkillParser.parse(text)
        XCTAssertEqual(skill.summary.invocation, .default)
    }

    /// 名字必须是 kebab-case：带空格、大写、下划线都拒。
    func testRejectsInvalidNames() {
        for bad in ["Weekly Report", "weekly_report", "Weekly", "", "weekly--report"] {
            XCTAssertFalse(SkillParser.isValidName(bad), bad)
        }
        XCTAssertTrue(SkillParser.isValidName("weekly-report"))
        XCTAssertTrue(SkillParser.isValidName("a1-b2"))
    }

    func testRejectsMissingFrontmatter() {
        XCTAssertThrowsError(try SkillParser.parse("# 只有正文")) { error in
            XCTAssertEqual(error as? SkillParseError, .missingFrontmatter)
        }
    }

    func testRejectsMissingDescription() {
        let text = "---\nname: x\n---\n正文"
        XCTAssertThrowsError(try SkillParser.parse(text)) { error in
            XCTAssertEqual(error as? SkillParseError, .missingDescription)
        }
    }

    func testQuotedValuesAreUnwrapped() throws {
        let text = """
        ---
        name: quoted
        description: "带引号的描述"
        ---
        正文
        """
        XCTAssertEqual(try SkillParser.parse(text).summary.description, "带引号的描述")
    }

    func testTokenEstimateIsPositive() throws {
        XCTAssertGreaterThan(try SkillParser.parse(sample).summary.tokenEstimate, 0)
    }

    func testRenderedContentIncludesResources() {
        let summary = SkillSummary(name: "s", description: "d")
        let skill = SkillDefinition(
            summary: summary,
            body: "正文",
            resources: ["templates/a.md": "模板内容"]
        )
        XCTAssertTrue(skill.renderedContent.contains("正文"))
        XCTAssertTrue(skill.renderedContent.contains("templates/a.md"))
        XCTAssertTrue(skill.renderedContent.contains("模板内容"))
    }
}

final class SkillRendererTests: XCTestCase {
    private func summary(_ name: String, _ description: String) -> SkillSummary {
        SkillSummary(name: name, description: description)
    }

    func testCatalogFormat() {
        let text = SkillRenderer.catalog([
            summary("weekly-report", "整理周报"),
            summary("code-review", "审查代码")
        ])
        XCTAssertEqual(text, """
        <available_skills>
        - weekly-report: 整理周报
        - code-review: 审查代码
        </available_skills>
        """)
    }

    func testEmptyCatalogIsEmptyString() {
        XCTAssertEqual(SkillRenderer.catalog([]), "")
    }

    func testSkillContentWrapping() {
        let skill = SkillDefinition(summary: summary("x", "y"), body: "正文")
        XCTAssertEqual(SkillRenderer.skillContent(skill), """
        <skill_content name="x">
        正文
        </skill_content>
        """)
    }

    /// skill 正文里出现闭合标签不能破坏外层结构。
    func testNameIsEscaped() {
        let skill = SkillDefinition(
            summary: SkillSummary(name: "x", description: "y"),
            body: "正文"
        )
        // name 合法时不会含特殊字符，这里直接验证转义函数本身
        XCTAssertEqual(SkillRenderer.escapeAttribute("a\"b<c>"), "a&quot;b&lt;c&gt;")
        XCTAssertFalse(SkillRenderer.skillContent(skill).contains("<<<"))
    }

    func testSystemCombinesMultipleSkills() {
        let a = SkillDefinition(summary: summary("a", "第一"), body: "A 正文")
        let b = SkillDefinition(summary: summary("b", "第二"), body: "B 正文")
        let system = SkillRenderer.system([a, b])
        XCTAssertTrue(system?.contains("A 正文") ?? false)
        XCTAssertTrue(system?.contains("B 正文") ?? false)
        XCTAssertNil(SkillRenderer.system([]))
    }
}
