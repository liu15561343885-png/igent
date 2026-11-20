import CoreKit
import Foundation
import XCTest
@testable import LLMKit

final class ImageGenerationTests: XCTestCase {
    private let request = ImageGenerationRequest(
        model: "gpt-image-1",
        prompt: "一只戴墨镜的橘猫，扁平插画风",
        size: "1024x1024"
    )

    // MARK: - OpenAI Images

    func testOpenAIRequestBody() throws {
        let adapter = OpenAIImagesAdapter(profile: .init(
            id: "x", name: "X", family: .openAICompatible,
            baseURL: URL(string: "https://api.openai.com/v1")!,
            chatPath: "/images/generations"
        ), apiKey: "k")
        let urlRequest = try adapter.makeRequest(request)
        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: body).objectValue)

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.openai.com/v1/images/generations")
        XCTAssertEqual(json["model"], .string("gpt-image-1"))
        XCTAssertEqual(json["prompt"], .string("一只戴墨镜的橘猫，扁平插画风"))
        XCTAssertEqual(json["size"], .string("1024x1024"))
        // gpt-image-1 不接受 response_format，所以请求体里不能有它。
        XCTAssertNil(json["response_format"])
    }

    func testOpenAIParsesBase64() throws {
        let json = #"{"created":1,"data":[{"b64_json":"QUJD"}]}"#
        let parsed = try OpenAIImagesAdapter.parse(Data(json.utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].base64, "QUJD")
    }

    func testOpenAIParsesURL() throws {
        let json = #"{"data":[{"url":"https://cdn.test/a.png"}]}"#
        let parsed = try OpenAIImagesAdapter.parse(Data(json.utf8))
        XCTAssertEqual(parsed[0].url?.absoluteString, "https://cdn.test/a.png")
    }

    func testOpenAIRejectsEmptyData() {
        XCTAssertThrowsError(try OpenAIImagesAdapter.parse(Data(#"{"data":[]}"#.utf8))) { error in
            XCTAssertEqual(error as? ImageGenerationError, .emptyResponse)
        }
    }

    /// 厂商在 200 里塞 error 也不是没可能，要认出来。
    func testOpenAIRecognisesInlineError() {
        let json = #"{"error":{"message":"content policy violation"}}"#
        XCTAssertThrowsError(try OpenAIImagesAdapter.parse(Data(json.utf8)))
    }

    func testOpenAIRejectsGarbage() {
        XCTAssertThrowsError(try OpenAIImagesAdapter.parse(Data("not json".utf8)))
    }

    // MARK: - Gemini Images

    func testGeminiRequestBody() throws {
        let adapter = GeminiImagesAdapter(apiKey: "goog")
        var req = request
        req.model = "gemini-2.5-flash-image"
        let urlRequest = try adapter.makeRequest(req)

        XCTAssertEqual(
            urlRequest.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-image:generateContent"
        )
        let body = try XCTUnwrap(urlRequest.httpBody)
        let json = try XCTUnwrap(try JSONDecoder().decode(JSONValue.self, from: body).objectValue)
        let modalities = json["generationConfig"]?.objectValue?["responseModalities"]?.arrayValue
        XCTAssertEqual(modalities, [.string("TEXT"), .string("IMAGE")])
    }

    func testGeminiParsesInlineData() throws {
        let json = """
        {"candidates":[{"content":{"parts":[
          {"text":"这是你要的图"},
          {"inlineData":{"mimeType":"image/png","data":"QUJD"}}
        ]}}]}
        """
        let images = try GeminiImagesAdapter.parse(Data(json.utf8))
        XCTAssertEqual(images.count, 1)
        XCTAssertEqual(images[0].mediaType, "image/png")
        XCTAssertEqual(images[0].data, Data([0x41, 0x42, 0x43]))
    }

    /// 只返回文字（模型判定不该出图）要被当成空结果，而不是成功。
    func testGeminiTextOnlyIsEmptyResponse() {
        let json = #"{"candidates":[{"content":{"parts":[{"text":"我不能画这个"}]}}]}"#
        XCTAssertThrowsError(try GeminiImagesAdapter.parse(Data(json.utf8))) { error in
            XCTAssertEqual(error as? ImageGenerationError, .emptyResponse)
        }
    }
}
