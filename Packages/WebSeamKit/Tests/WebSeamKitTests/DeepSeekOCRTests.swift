import CoreKit
import Foundation
import XCTest
@testable import WebSeamKit

final class DeepSeekOCRTests: XCTestCase {
    func testRequestIsMultipartWithPurposeAndFile() throws {
        let request = DeepSeekOCRRecognizer.makeRequest(
            data: Data("PDFBYTES".utf8),
            filename: "报告.pdf",
            purpose: .textRecognition,
            apiKey: "sk-x"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/tools/ocr")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 180, "服务端总时限是 180 秒")

        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))

        let body = try XCTUnwrap(request.httpBody)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"purpose\""))
        XCTAssertTrue(text.contains("text_recognition"))
        XCTAssertTrue(text.contains("filename=\"报告.pdf\""))
        XCTAssertTrue(text.contains("PDFBYTES"))
    }

    /// 解析方式要如实写进 multipart，否则设置里的切换等于没生效。
    func testRichLayoutPurposeIsSent() throws {
        let request = DeepSeekOCRRecognizer.makeRequest(
            data: Data("x".utf8),
            filename: "财报.pdf",
            purpose: .richLayoutRecognition,
            apiKey: "k"
        )
        let text = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(text.contains("rich_layout_recognition"))
    }

    /// 识别期间服务端会发换行保活，响应体前面可能全是空行。
    func testParsesResponseWithLeadingNewlines() throws {
        let raw = "\n\n\n" + """
        {"id":"ocr-1","object":"ocr.result","purpose":"text_recognition","page_count":2,
         "pages":[{"index":0,"text":"第一页","finish_reason":"stop"},
                  {"index":1,"text":"第二页","finish_reason":"stop"}],
         "usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120}}
        """
        let result = try DeepSeekOCRRecognizer.parse(Data(raw.utf8))

        XCTAssertEqual(result.pageCount, 2)
        XCTAssertEqual(result.text, "第一页\n\n第二页")
        XCTAssertFalse(result.isTruncated)
        XCTAssertEqual(result.outputTokens, 20)
    }

    /// 某页因长度上限被截断时要标出来，否则用户会以为文档就这么多内容。
    func testDetectsTruncatedPages() throws {
        let raw = """
        {"page_count":2,"pages":[
          {"index":0,"text":"完整的","finish_reason":"stop"},
          {"index":1,"text":"被截断的","finish_reason":"length"}
        ]}
        """
        let result = try DeepSeekOCRRecognizer.parse(Data(raw.utf8))
        XCTAssertEqual(result.truncatedPages, [1])
        XCTAssertTrue(result.isTruncated)
    }

    func testSkipsEmptyPages() throws {
        let raw = """
        {"page_count":3,"pages":[
          {"index":0,"text":"有内容"},
          {"index":1,"text":"   "},
          {"index":2,"text":"也有内容"}
        ]}
        """
        XCTAssertEqual(try DeepSeekOCRRecognizer.parse(Data(raw.utf8)).text, "有内容\n\n也有内容")
    }

    func testAllEmptyPagesThrows() {
        let raw = #"{"page_count":1,"pages":[{"index":0,"text":"  "}]}"#
        XCTAssertThrowsError(try DeepSeekOCRRecognizer.parse(Data(raw.utf8)))
    }

    func testErrorBodyThrows() {
        let raw = #"{"error":{"message":"unsupported format"}}"#
        XCTAssertThrowsError(try DeepSeekOCRRecognizer.parse(Data(raw.utf8)))
    }
}
