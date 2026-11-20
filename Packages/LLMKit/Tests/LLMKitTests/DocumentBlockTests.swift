import CoreKit
import Foundation
import XCTest
@testable import LLMKit

final class DocumentBlockTests: XCTestCase {
    private func message(with document: DocumentAttachment) -> Message {
        Message(role: .user, blocks: [.text("总结这份文件"), .document(document)], source: .user)
    }

    private let sample = DocumentAttachment(
        name: "季度报告.pdf",
        pageCount: 3,
        text: "第一页内容\n\n第二页内容\n\n第三页内容"
    )

    func testPromptTextHasHeaderAndBody() {
        let text = sample.promptText
        XCTAssertTrue(text.hasPrefix("【文件：季度报告.pdf（3 页）】"))
        XCTAssertTrue(text.contains("第三页内容"))
    }

    /// 超过上限时截断并说明，避免整段请求直接超窗。
    func testPromptTextTruncatesLongDocuments() {
        let huge = DocumentAttachment(
            name: "书.pdf",
            pageCount: 900,
            text: String(repeating: "字", count: 60_000)
        )
        let text = huge.promptText
        XCTAssertLessThan(text.count, 30_000)
        XCTAssertTrue(text.contains("后续内容已截断"))
    }

    /// 解析阶段就被截断的文件要如实告知，不能让模型以为读到了全部。
    func testPromptTextMentionsUnparsedTail() {
        let partial = DocumentAttachment(name: "a.pdf", pageCount: 5, text: "内容", truncated: true)
        XCTAssertTrue(partial.promptText.contains("部分内容未解析"))
    }

    func testPlainTextIsDocumentText() {
        let block = ContentBlock.document(sample)
        XCTAssertEqual(block.plainText, sample.text)
    }

    func testRoundTripsThroughCodable() throws {
        let block = ContentBlock.document(sample)
        let data = try JSONEncoder().encode(block)
        XCTAssertEqual(try JSONDecoder().decode(ContentBlock.self, from: data), block)
    }

    // MARK: - 各族请求

    func testOpenAISendsDocumentAsText() throws {
        let body = OpenAIRequestBuilder(profile: .openAICompatible(
            id: "p", name: "P", baseURL: "https://api.openai.com/v1"
        )).body(GenerateOptions(provider: "p", model: "gpt-4o", messages: [message(with: sample)]))
        let dumped = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        XCTAssertTrue(dumped.contains("季度报告.pdf"))
        XCTAssertTrue(dumped.contains("第三页内容"))
    }

    func testAnthropicSendsDocumentAsTextBlock() throws {
        let body = AnthropicRequestBuilder(profile: .anthropic()).body(
            GenerateOptions(provider: "p", model: "m", messages: [message(with: sample)])
        )
        let content = try XCTUnwrap(
            body.objectValue?["messages"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue
        )
        let texts = content.compactMap { $0.objectValue?["text"]?.stringValue }.joined()
        XCTAssertTrue(texts.contains("【文件：季度报告.pdf（3 页）】"))
    }

    func testGeminiSendsDocumentAsTextPart() throws {
        let body = GeminiRequestBuilder(profile: .gemini()).body(
            GenerateOptions(provider: "p", model: "m", messages: [message(with: sample)])
        )
        let dumped = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        XCTAssertTrue(dumped.contains("季度报告.pdf"))
    }

    func testResponsesSendsDocumentAsInputText() throws {
        let body = OpenAIResponsesRequestBuilder(profile: .openAIResponses()).body(
            GenerateOptions(provider: "p", model: "m", messages: [message(with: sample)])
        )
        let dumped = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        XCTAssertTrue(dumped.contains("第三页内容"))
    }
}
