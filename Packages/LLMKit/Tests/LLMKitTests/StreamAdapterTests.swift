import CoreKit
import Foundation
import XCTest
@testable import LLMKit

final class StreamAdapterTests: XCTestCase {
    private var options: GenerateOptions {
        GenerateOptions(
            provider: "test",
            model: "test-model",
            messages: [Message(role: .user, blocks: [.text("你好")], source: .user)]
        )
    }

    private func openAIAdapter(chunkSize: Int) throws -> OpenAICompatibleAdapter {
        let profile = ProviderProfile.openAICompatible(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1"
        )
        return OpenAICompatibleAdapter(
            profile: profile,
            apiKey: "k",
            transport: FixtureTransport(data: try Fixture.sse("openai-chat"), chunkSize: chunkSize)
        )
    }

    private func anthropicAdapter(chunkSize: Int) throws -> AnthropicAdapter {
        AnthropicAdapter(
            apiKey: "k",
            transport: FixtureTransport(data: try Fixture.sse("anthropic"), chunkSize: chunkSize)
        )
    }

    // MARK: - OpenAI 兼容

    func testOpenAIFixtureAssemblesBlocks() async throws {
        let chunks = try await collect(try openAIAdapter(chunkSize: 7).stream(options))
        let result = try assemble(chunks)

        XCTAssertEqual(result.blocks, [.text("你好，世界")])
        XCTAssertEqual(
            result.usage,
            TokenUsage(uncachedInputTokens: 5, outputTokens: 9, totalTokens: 30, cacheReadTokens: 16)
        )
        XCTAssertEqual(result.finish, .stop)
    }

    /// usage 的 prompt_tokens 含缓存命中，必须减成互斥计数。
    func testOpenAIUsageSubtractsCache() async throws {
        let chunks = try await collect(try openAIAdapter(chunkSize: 64).stream(options))
        guard let usage = try assemble(chunks).usage else {
            return XCTFail("没有 usage")
        }
        XCTAssertEqual(usage.uncachedInputTokens, 5)
        XCTAssertEqual(usage.cacheReadTokens, 16)
        XCTAssertEqual(usage.billedInputTokens, 21)
    }

    func testOpenAIUsagePrecedesFinish() async throws {
        let chunks = try await collect(try openAIAdapter(chunkSize: 64).stream(options))
        let usageIndex = chunks.firstIndex { if case .usage = $0 { return true } else { return false } }
        let finishIndex = chunks.firstIndex { if case .finish = $0 { return true } else { return false } }
        let usage = try XCTUnwrap(usageIndex)
        let finish = try XCTUnwrap(finishIndex)
        XCTAssertLessThan(usage, finish, "契约要求 usage 在 finish 之前")
    }

    func testOpenAIResponseIdCaptured() async throws {
        var assembler = BlockAssembler()
        for chunk in try await collect(try openAIAdapter(chunkSize: 64).stream(options)) {
            assembler.push(chunk)
        }
        XCTAssertEqual(assembler.meta?.responseId, "chatcmpl-1")
    }

    /// 一字节一片也要得到完全相同的结果。
    func testOpenAISurvivesByteByByteDelivery() async throws {
        let chunks = try await collect(try openAIAdapter(chunkSize: 1).stream(options))
        XCTAssertEqual(try assemble(chunks).blocks, [.text("你好，世界")])
    }

    // MARK: - Anthropic

    func testAnthropicFixtureAssemblesBlocks() async throws {
        let chunks = try await collect(try anthropicAdapter(chunkSize: 5).stream(options))
        let result = try assemble(chunks)

        XCTAssertEqual(result.blocks, [.reasoning("先想一想"), .text("你好，世界")])
        // Anthropic 的 input_tokens 不含缓存，本身即互斥计数。
        XCTAssertEqual(
            result.usage,
            TokenUsage(uncachedInputTokens: 18, outputTokens: 9, cacheReadTokens: 12, cacheWriteTokens: 0)
        )
        XCTAssertEqual(result.finish, .stop)
    }

    func testAnthropicEmitsBlockBoundaries() async throws {
        let chunks = try await collect(try anthropicAdapter(chunkSize: 5).stream(options))
        XCTAssertEqual(chunks.first, .blockStart(index: 0, type: .reasoning))
        XCTAssertEqual(
            chunks.filter { if case .blockEnd = $0 { return true } else { return false } }.count,
            2
        )
    }

    func testAnthropicSignatureDeltaIgnored() async throws {
        let chunks = try await collect(try anthropicAdapter(chunkSize: 5).stream(options))
        let texts = chunks.compactMap { chunk -> String? in
            if case let .reasoningDelta(_, text) = chunk { return text }
            return nil
        }
        XCTAssertEqual(texts.joined(), "先想一想")
    }

    func testAnthropicResponseIdCaptured() async throws {
        var assembler = BlockAssembler()
        for chunk in try await collect(try anthropicAdapter(chunkSize: 5).stream(options)) {
            assembler.push(chunk)
        }
        XCTAssertEqual(assembler.meta?.responseId, "msg_1")
    }

    func testAnthropicSurvivesByteByByteDelivery() async throws {
        let chunks = try await collect(try anthropicAdapter(chunkSize: 1).stream(options))
        XCTAssertEqual(try assemble(chunks).blocks, [.reasoning("先想一想"), .text("你好，世界")])
    }

    // MARK: - 同一契约

    /// 两条完全不同的线格式，装配成结构相同的内容块序列。
    func testTwoFamiliesProduceSameBlockShape() async throws {
        let a = try assemble(try await collect(try openAIAdapter(chunkSize: 9).stream(options)))
        let b = try assemble(try await collect(try anthropicAdapter(chunkSize: 9).stream(options)))

        XCTAssertEqual(a.blocks.count, 1)
        XCTAssertEqual(b.blocks.count, 2)
        XCTAssertEqual(a.blocks.last, .text("你好，世界"))
        XCTAssertEqual(b.blocks.last, .text("你好，世界"))
    }
}

final class EmptyStreamTests: XCTestCase {
    /// 200 + 非 SSE 内容（比如代理返回 HTML）时，必须报错而不是"正常结束但零内容"。
    func testEmptyStreamIsReportedAsError() {
        var parser = OpenAIStreamParser()
        var chunks = parser.feed(Data("<html>gateway error</html>".utf8))
        chunks += parser.finish()

        let finishes = chunks.compactMap { chunk -> FinishReason? in
            if case let .finish(reason, _) = chunk { reason } else { nil }
        }
        guard case let .error(failure)? = finishes.last else {
            return XCTFail("空响应应当以错误结束，而不是 .stop")
        }
        XCTAssertEqual(failure.code, .emptyResponse)
    }

    /// 有内容但没有结束标记（连接被提前关闭）时保持宽容，按正常结束处理。
    func testContentWithoutTerminalStaysStop() {
        let sse = """
        data: {"choices":[{"delta":{"content":"你好"},"index":0}]}

        """
        var parser = OpenAIStreamParser()
        var chunks = parser.feed(Data(sse.utf8))
        chunks += parser.finish()

        let finishes = chunks.compactMap { chunk -> FinishReason? in
            if case let .finish(reason, _) = chunk { reason } else { nil }
        }
        XCTAssertEqual(finishes.last, .stop)
    }
}

final class FailureClassificationTests: XCTestCase {
    /// 只认厂商的明确措辞。裸子串 "context" 会把"字段被拒"误判成超窗，
    /// 而超窗会触发压缩——压缩是不可逆的。
    func testGenericContextMentionIsNotOverflow() {
        let failure = LlmFailure.from(status: 400, body: "invalid value for field context")
        XCTAssertNotEqual(failure.code, .contextWindowExceeded)
        XCTAssertEqual(failure.code, .invalidRequest)
    }

    func testKnownOverflowPhrasingIsOverflow() {
        XCTAssertEqual(
            LlmFailure.from(status: 400, body: "context_length_exceeded").code,
            .contextWindowExceeded
        )
        XCTAssertEqual(
            LlmFailure.from(status: 400, body: "prompt is too long: 300000 tokens").code,
            .contextWindowExceeded
        )
    }

    /// 参数错误不能被显示成"密钥无效"。
    func testBadRequestIsNotCredentialError() {
        let failure = LlmFailure.from(status: 400, body: "max_tokens is not supported")
        XCTAssertEqual(failure.code, .invalidRequest)
    }
}
