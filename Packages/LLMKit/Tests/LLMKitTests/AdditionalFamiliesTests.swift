import CoreKit
import Foundation
import XCTest
@testable import LLMKit

/// Gemini / OpenAI Responses / Azure 三族的覆盖。
final class AdditionalFamiliesTests: XCTestCase {
    private var options: GenerateOptions {
        GenerateOptions(
            provider: "test",
            model: "gpt-4o-mini",
            messages: [Message(role: .user, blocks: [.text("你好")], source: .user)],
            system: "你是助手",
            temperature: 0.7,
            maxTokens: 256
        )
    }

    private func transport(_ text: String) -> FixtureTransport {
        FixtureTransport(data: Data(text.utf8), chunkSize: 7)
    }

    private func run(_ stream: AsyncThrowingStream<StreamChunk, Error>) async throws -> (blocks: [ContentBlock], usage: TokenUsage?, finish: FinishReason, meta: ProviderMeta?) {
        var assembler = BlockAssembler()
        for try await chunk in stream {
            assembler.push(chunk)
        }
        return (try assembler.blocks(), assembler.usage, assembler.finish, assembler.meta)
    }

    // MARK: - Gemini

    func testGeminiBodyMatchesFixture() throws {
        var options = self.options
        options.model = "gemini-2.5-flash"
        let built = GeminiRequestBuilder(profile: .gemini()).body(options)
        XCTAssertEqual(built, try Fixture.json("gemini.request"))
    }

    func testGeminiMapsAssistantToModelRole() {
        var options = self.options
        options.messages = [
            Message(role: .assistant, blocks: [.text("上一句")], source: .model(provider: "g", model: "m", meta: nil)),
            Message(role: .user, blocks: [.text("继续")], source: .user)
        ]
        let built = GeminiRequestBuilder(profile: .gemini()).body(options)
        let roles = built.objectValue?["contents"]?.arrayValue?
            .compactMap { $0.objectValue?["role"]?.stringValue } ?? []
        // assistant 映射成 model；开头若是 model 会补一条 user（Gemini 不接受首条是 model），
        // 所以这里断言"包含 model 且以 user 收尾"，而不是固定数组。
        XCTAssertTrue(roles.contains("model"), "assistant 应映射为 model 角色")
        XCTAssertEqual(roles.first, "user")
        XCTAssertEqual(roles.last, "user")
    }

    func testGeminiURLPutsModelInPathAndAltSSE() throws {
        let adapter = GeminiAdapter(apiKey: "k", transport: FixtureTransport(data: Data()))
        var options = self.options
        options.model = "gemini-2.5-flash"
        let request = try adapter.makeRequest(options)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:streamGenerateContent?alt=sse"
        )
    }

    func testGeminiAuthHeader() throws {
        let adapter = GeminiAdapter(apiKey: "goog-key", transport: FixtureTransport(data: Data()))
        let request = try adapter.makeRequest(options)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-goog-api-key"), "goog-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testGeminiFixtureAssemblesBlocks() async throws {
        let adapter = GeminiAdapter(apiKey: "k", transport: FixtureTransport(data: try Fixture.sse("gemini"), chunkSize: 5))
        let result = try await run(adapter.stream(options))

        XCTAssertEqual(result.blocks, [.reasoning("先想一想"), .text("你好，世界")])
        // promptTokenCount 含缓存，减出 cachedContentTokenCount 才是互斥计数。
        XCTAssertEqual(
            result.usage,
            TokenUsage(uncachedInputTokens: 5, outputTokens: 9, totalTokens: 30, cacheReadTokens: 16)
        )
        XCTAssertEqual(result.finish, .stop)
    }

    func testGeminiSafetyFinishMapsToContentFilter() async throws {
        let sse = """
        data: {"candidates":[{"content":{"parts":[{"text":"部分"}],"role":"model"},"finishReason":"SAFETY","index":0}]}

        """
        let adapter = GeminiAdapter(apiKey: "k", transport: transport(sse))
        let result = try await run(adapter.stream(options))
        XCTAssertEqual(result.finish, .contentFilter("SAFETY"))
    }

    // MARK: - OpenAI Responses

    func testResponsesBodyMatchesFixture() throws {
        var options = self.options
        options.model = "gpt-5"
        let built = OpenAIResponsesRequestBuilder(profile: .openAIResponses()).body(options)
        XCTAssertEqual(built, try Fixture.json("responses.request"))
    }

    func testResponsesUsesInstructionsAndMaxOutputTokens() {
        let built = OpenAIResponsesRequestBuilder(profile: .openAIResponses()).body(options)
        let object = built.objectValue
        XCTAssertEqual(object?["instructions"], .string("你是助手"))
        XCTAssertNotNil(object?["max_output_tokens"])
        XCTAssertNil(object?["max_tokens"])
        XCTAssertNotNil(object?["input"])
        XCTAssertNil(object?["messages"])
    }

    func testResponsesFixtureAssemblesBlocks() async throws {
        let adapter = OpenAIResponsesAdapter(
            apiKey: "k",
            transport: FixtureTransport(data: try Fixture.sse("responses"), chunkSize: 11)
        )
        let result = try await run(adapter.stream(options))

        XCTAssertEqual(result.blocks, [.text("你好，世界")])
        XCTAssertEqual(
            result.usage,
            TokenUsage(uncachedInputTokens: 5, outputTokens: 9, totalTokens: 30, cacheReadTokens: 16, reasoningTokens: 0)
        )
        XCTAssertEqual(result.finish, .stop)
        XCTAssertEqual(result.meta?.responseId, "resp_1")
    }

    func testResponsesIncompleteMapsToMaxTokens() async throws {
        let sse = """
        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":"截断"}

        event: response.incomplete
        data: {"type":"response.incomplete","response":{"id":"resp_2","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}

        """
        let adapter = OpenAIResponsesAdapter(apiKey: "k", transport: transport(sse))
        let result = try await run(adapter.stream(options))
        XCTAssertEqual(result.finish, .maxTokens)
    }

    // MARK: - Azure（配置而非适配器）

    func testAzureURLContainsDeploymentAndAPIVersion() throws {
        let profile = ProviderProfile.azure(resource: "myres", deployment: "gpt-4o")
        let adapter = OpenAICompatibleAdapter(profile: profile, apiKey: "k", transport: FixtureTransport(data: Data()))
        let request = try adapter.makeRequest(options)
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://myres.openai.azure.com/openai/deployments/gpt-4o/chat/completions?api-version=2024-10-21"
        )
    }

    func testAzureUsesAPIKeyHeaderNotBearer() throws {
        let adapter = OpenAICompatibleAdapter(
            profile: .azure(resource: "r", deployment: "d"),
            apiKey: "azure-key",
            transport: FixtureTransport(data: Data())
        )
        let request = try adapter.makeRequest(options)
        XCTAssertEqual(request.value(forHTTPHeaderField: "api-key"), "azure-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    /// Azure 的报文与 OpenAI 完全一致——这正是"配置而非代码"的依据。
    func testAzureBodyIsIdenticalToOpenAI() {
        let azure = OpenAIRequestBuilder(profile: .azure(resource: "r", deployment: "d")).body(options)
        let openai = OpenAIRequestBuilder(
            profile: .openAICompatible(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1")
        ).body(options)
        XCTAssertEqual(azure, openai)
    }

    // MARK: - 四族横向对比

    /// 四族各跑一遍录制流，装配出的正文块完全一致。
    func testAllFamiliesAgreeOnVisibleText() async throws {
        var results: [String] = []

        let openAI = OpenAICompatibleAdapter(
            profile: .openAICompatible(id: "o", name: "O", baseURL: "https://x.test/v1"),
            apiKey: "k",
            transport: FixtureTransport(data: try Fixture.sse("openai-chat"), chunkSize: 9)
        )
        results.append(try await run(openAI.stream(options)).blocks.last?.plainText ?? "")

        let anthropic = AnthropicAdapter(
            apiKey: "k",
            transport: FixtureTransport(data: try Fixture.sse("anthropic"), chunkSize: 9)
        )
        results.append(try await run(anthropic.stream(options)).blocks.last?.plainText ?? "")

        let gemini = GeminiAdapter(
            apiKey: "k",
            transport: FixtureTransport(data: try Fixture.sse("gemini"), chunkSize: 9)
        )
        results.append(try await run(gemini.stream(options)).blocks.last?.plainText ?? "")

        let responses = OpenAIResponsesAdapter(
            apiKey: "k",
            transport: FixtureTransport(data: try Fixture.sse("responses"), chunkSize: 9)
        )
        results.append(try await run(responses.stream(options)).blocks.last?.plainText ?? "")

        XCTAssertEqual(Set(results), ["你好，世界"], "四族输出不一致：\(results)")
    }
}

final class GeminiAlternationTests: XCTestCase {
    private func contents(_ messages: [Message]) -> [[String: JSONValue]] {
        let body = GeminiRequestBuilder(profile: .gemini()).body(
            GenerateOptions(provider: "g", model: "m", messages: messages)
        )
        return (body.objectValue?["contents"]?.arrayValue ?? []).compactMap { $0.objectValue }
    }

    /// 连续两条 user 必须合并成一条，否则 Gemini 直接 400。
    func testConsecutiveUserTurnsAreMerged() {
        let messages = [
            Message(role: .user, blocks: [.text("第一句")], source: .user),
            Message(role: .user, blocks: [.text("第二句")], source: .user)
        ]
        let result = contents(messages)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?["role"], .string("user"))
    }

    /// 开头是 model 也要补一条 user。
    func testLeadingModelTurnGetsUserPrefix() {
        let messages = [
            Message(role: .assistant, blocks: [.text("我先说")], source: .model(provider: "g", model: "m", meta: nil)),
            Message(role: .user, blocks: [.text("好")], source: .user)
        ]
        let result = contents(messages)
        XCTAssertEqual(result.first?["role"], .string("user"))
        XCTAssertEqual(result.count, 3)
    }

    /// 正常交替时不能多合并。
    func testAlternatingTurnsArePreserved() {
        let messages = [
            Message(role: .user, blocks: [.text("问")], source: .user),
            Message(role: .assistant, blocks: [.text("答")], source: .model(provider: "g", model: "m", meta: nil)),
            Message(role: .user, blocks: [.text("再问")], source: .user)
        ]
        XCTAssertEqual(contents(messages).map { $0["role"] }, [.string("user"), .string("model"), .string("user")])
    }
}

final class FinishReasonEdgeTests: XCTestCase {
    /// incomplete 的原因是 content_filter 时要报内容过滤，不能报"超长"。
    func testResponsesIncompleteContentFilter() {
        let sse = """
        data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}

        """
        var parser = OpenAIResponsesStreamParser()
        var chunks = parser.feed(Data(sse.utf8))
        chunks += parser.finish()
        let reason = chunks.compactMap { chunk -> FinishReason? in
            if case let .finish(r, _) = chunk { r } else { nil }
        }.last
        guard case .contentFilter = reason else {
            return XCTFail("应映射为 contentFilter，实际 \(String(describing: reason))")
        }
    }

    /// 提示词被拦截时只有 promptFeedback，没有 candidates。
    func testGeminiPromptFeedbackBecomesContentFilter() {
        let sse = """
        data: {"promptFeedback":{"blockReason":"SAFETY"}}

        """
        var parser = GeminiStreamParser()
        var chunks = parser.feed(Data(sse.utf8))
        chunks += parser.finish()
        let reason = chunks.compactMap { chunk -> FinishReason? in
            if case let .finish(r, _) = chunk { r } else { nil }
        }.last
        guard case .contentFilter = reason else {
            return XCTFail("应映射为 contentFilter，实际 \(String(describing: reason))")
        }
    }
}
