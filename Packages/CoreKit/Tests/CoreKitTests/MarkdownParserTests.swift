import Foundation
import XCTest
@testable import CoreKit

final class MarkdownParserTests: XCTestCase {
    func testPlainParagraph() {
        XCTAssertEqual(
            MarkdownParser.parse("你好，世界"),
            [.paragraph("你好，世界")]
        )
    }

    func testBlankLineSplitsParagraphs() {
        XCTAssertEqual(
            MarkdownParser.parse("第一段\n\n第二段"),
            [.paragraph("第一段"), .paragraph("第二段")]
        )
    }

    func testSingleNewlineStaysInsideParagraph() {
        XCTAssertEqual(
            MarkdownParser.parse("第一行\n第二行"),
            [.paragraph("第一行\n第二行")]
        )
    }

    func testHeadings() {
        XCTAssertEqual(
            MarkdownParser.parse("# 标题\n### 三级"),
            [.heading(level: 1, text: "标题"), .heading(level: 3, text: "三级")]
        )
    }

    /// 没有空格的 `#标签` 不是标题。
    func testHashWithoutSpaceIsNotHeading() {
        XCTAssertEqual(
            MarkdownParser.parse("#话题"),
            [.paragraph("#话题")]
        )
    }

    func testFencedCodeWithLanguage() {
        let source = """
        说明：

        ```swift
        let a = 1
        print(a)
        ```
        """
        XCTAssertEqual(
            MarkdownParser.parse(source),
            [
                .paragraph("说明："),
                .code(language: "swift", content: "let a = 1\nprint(a)")
            ]
        )
    }

    func testCodeBlockWithoutLanguage() {
        XCTAssertEqual(
            MarkdownParser.parse("```\nraw\n```"),
            [.code(language: nil, content: "raw")]
        )
    }

    /// 代码块内的 `#`、`-` 不能被当成标题和列表。
    func testMarkersInsideCodeAreLiteral() {
        let source = """
        ```
        # not a heading
        - not a list
        ```
        """
        XCTAssertEqual(
            MarkdownParser.parse(source),
            [.code(language: nil, content: "# not a heading\n- not a list")]
        )
    }

    /// 未闭合的代码块也要显示出来，不能吞内容。
    func testUnclosedCodeFenceStillRenders() {
        XCTAssertEqual(
            MarkdownParser.parse("```swift\nlet a = 1"),
            [.code(language: "swift", content: "let a = 1")]
        )
    }

    func testLists() {
        XCTAssertEqual(
            MarkdownParser.parse("- 甲\n- 乙\n1. 丙"),
            [
                .listItem(ordered: false, index: 0, text: "甲"),
                .listItem(ordered: false, index: 0, text: "乙"),
                .listItem(ordered: true, index: 1, text: "丙")
            ]
        )
    }

    func testQuote() {
        XCTAssertEqual(
            MarkdownParser.parse("> 引用一句"),
            [.quote("引用一句")]
        )
    }

    func testDivider() {
        XCTAssertEqual(MarkdownParser.parse("---"), [.divider])
    }

    /// 行内格式原样保留在段落文本里，交给 AttributedString 处理。
    func testInlineFormattingPreserved() {
        XCTAssertEqual(
            MarkdownParser.parse("这是 **加粗** 和 `代码`"),
            [.paragraph("这是 **加粗** 和 `代码`")]
        )
    }

    func testWindowsLineEndings() {
        XCTAssertEqual(
            MarkdownParser.parse("第一段\r\n\r\n第二段"),
            [.paragraph("第一段"), .paragraph("第二段")]
        )
    }

    func testMixedDocumentStructure() {
        let source = """
        # 结论

        有两点：

        1. 成本偏高
        2. 排期可控

        ```
        cost = 100
        ```
        """
        let blocks = MarkdownParser.parse(source)
        XCTAssertEqual(blocks.count, 5)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "结论"))
        XCTAssertEqual(blocks[1], .paragraph("有两点："))
        XCTAssertEqual(blocks[2], .listItem(ordered: true, index: 1, text: "成本偏高"))
        XCTAssertEqual(blocks[3], .listItem(ordered: true, index: 2, text: "排期可控"))
        XCTAssertEqual(blocks[4], .code(language: nil, content: "cost = 100"))
    }
}
