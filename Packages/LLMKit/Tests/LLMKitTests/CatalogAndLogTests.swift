import CoreKit
import Foundation
import XCTest
@testable import LLMKit

final class ModelCatalogTests: XCTestCase {
    // MARK: - 请求构造

    func testOpenAICompatibleModelsURL() throws {
        let profile = ProviderProfile.openAICompatible(
            id: "deepseek",
            name: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1"
        )
        let request = try ModelCatalog.makeRequest(profile: profile, apiKey: "k")
        XCTAssertEqual(request.url?.absoluteString, "https://api.deepseek.com/v1/models")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer k")
    }

    func testGeminiModelsURLAndHeader() throws {
        let request = try ModelCatalog.makeRequest(profile: .gemini(), apiKey: "goog")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "goog")
    }

    func testAnthropicSendsVersionHeader() throws {
        let request = try ModelCatalog.makeRequest(profile: .anthropic(), apiKey: "ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "ant")
    }

    // MARK: - 解析

    func testParseOpenAIShape() throws {
        let json = """
        {"object":"list","data":[
          {"id":"gpt-4o-mini","object":"model","owned_by":"system"},
          {"id":"gpt-4o","object":"model","owned_by":"system"}
        ]}
        """
        let models = try ModelCatalog.parse(family: .openAICompatible, data: Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["gpt-4o-mini", "gpt-4o"])
    }

    func testParseOpenRouterExtraFields() throws {
        let json = """
        {"data":[{"id":"anthropic/claude-sonnet-4.5","name":"Claude Sonnet 4.5","context_length":200000}]}
        """
        let models = try ModelCatalog.parse(family: .openAICompatible, data: Data(json.utf8))
        XCTAssertEqual(models.first?.displayName, "Claude Sonnet 4.5")
        XCTAssertEqual(models.first?.contextWindow, 200_000)
    }

    func testParseAnthropicShape() throws {
        let json = """
        {"data":[{"id":"claude-sonnet-4-5","display_name":"Claude Sonnet 4.5","type":"model"}],"has_more":false}
        """
        let models = try ModelCatalog.parse(family: .anthropic, data: Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["claude-sonnet-4-5"])
        XCTAssertEqual(models.first?.displayName, "Claude Sonnet 4.5")
    }

    /// Gemini 的 name 带 `models/` 前缀，使用时必须去掉。
    func testParseGeminiStripsPrefix() throws {
        let json = """
        {"models":[
          {"name":"models/gemini-2.5-flash","displayName":"Gemini 2.5 Flash","inputTokenLimit":1048576},
          {"name":"models/gemini-2.5-pro","displayName":"Gemini 2.5 Pro","inputTokenLimit":2097152}
        ]}
        """
        let models = try ModelCatalog.parse(family: .gemini, data: Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["gemini-2.5-flash", "gemini-2.5-pro"])
        XCTAssertEqual(models.first?.contextWindow, 1_048_576)
    }

    func testParseRejectsUnexpectedShape() {
        XCTAssertThrowsError(
            try ModelCatalog.parse(family: .openAICompatible, data: Data(#"{"error":"nope"}"#.utf8))
        )
    }

    func testParseSkipsEntriesWithoutID() throws {
        let json = """
        {"data":[{"object":"model"},{"id":"ok"}]}
        """
        let models = try ModelCatalog.parse(family: .openAICompatible, data: Data(json.utf8))
        XCTAssertEqual(models.map(\.id), ["ok"])
    }
}

final class RequestLogTests: XCTestCase {
    private struct StubUpstream: StreamTransport {
        var chunks: [Data] = []
        var failure: Error?

        func bytes(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
            AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                if let failure {
                    continuation.finish(throwing: failure)
                } else {
                    continuation.finish()
                }
            }
        }
    }

    private func request(headers: [String: String], body: String? = nil) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.test/v1/chat/completions")!)
        request.httpMethod = "POST"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        request.httpBody = body.map { Data($0.utf8) }
        return request
    }

    func testRecordsTraceWithSensitiveHeadersMasked() async throws {
        let log = RequestLog()
        let transport = LoggingTransport(
            upstream: StubUpstream(chunks: [Data("data: hi\n\n".utf8)]),
            log: log,
            label: "openai"
        )

        let request = request(headers: [
            "Authorization": "Bearer sk-secret",
            "Content-Type": "application/json"
        ], body: #"{"model":"gpt"}"#)

        for try await _ in transport.bytes(for: request) {}

        let traces = await log.all()
        XCTAssertEqual(traces.count, 1)
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace.headers["Authorization"], "••••", "密钥绝不能进日志")
        XCTAssertEqual(trace.headers["Content-Type"], "application/json")
        XCTAssertTrue(trace.bodyPreview.contains("gpt"))
        XCTAssertEqual(trace.responsePreview, "data: hi\n\n")
        XCTAssertEqual(trace.provider, "openai")
        XCTAssertNil(trace.failure)
    }

    func testRecordsFailureStatus() async throws {
        let log = RequestLog()
        let failure = LlmFailure.from(status: 401, body: "invalid key")
        let transport = LoggingTransport(
            upstream: StubUpstream(failure: failure),
            log: log,
            label: "anthropic"
        )

        do {
            for try await _ in transport.bytes(for: request(headers: [:])) {}
            XCTFail("应当抛出")
        } catch {
            // 预期
        }

        let traces = await log.all()
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace.statusCode, 401)
        XCTAssertEqual(trace.failure?.code, .auth)
    }

    func testPreviewIsTruncated() async throws {
        let log = RequestLog()
        let big = Data(repeating: 0x41, count: 10_000)
        let transport = LoggingTransport(
            upstream: StubUpstream(chunks: [big]),
            log: log,
            label: "x",
            previewLimit: 128
        )
        for try await _ in transport.bytes(for: request(headers: [:])) {}

        let traces = await log.all()
        let trace = try XCTUnwrap(traces.first)
        XCTAssertEqual(trace.responsePreview.count, 128)
        XCTAssertEqual(trace.receivedBytes, 10_000, "统计字节数不受预览截断影响")
    }

    func testRingBufferKeepsLatest() async throws {
        let log = RequestLog(capacity: 2)
        for index in 0..<4 {
            _ = await log.begin(
                RequestTrace(
                    startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    provider: "p\(index)",
                    method: "POST",
                    url: "https://x/\(index)",
                    headers: [:],
                    bodyPreview: ""
                )
            )
        }
        let traces = await log.all()
        XCTAssertEqual(traces.count, 2)
        XCTAssertEqual(Set(traces.map(\.provider)), ["p2", "p3"])
    }
}
