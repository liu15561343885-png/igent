import CoreKit
import Foundation
import XCTest
@testable import LLMKit

final class RequestBuilderTests: XCTestCase {
    private var baseOptions: GenerateOptions {
        GenerateOptions(
            provider: "openai",
            model: "gpt-4o-mini",
            messages: [
                Message(role: .user, blocks: [.text("你好")], source: .user)
            ],
            system: "你是助手",
            temperature: 0.7,
            maxTokens: 256
        )
    }

    // MARK: - OpenAI 兼容

    func testOpenAIBodyMatchesFixture() throws {
        let profile = ProviderProfile.openAICompatible(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1"
        )
        let built = OpenAIRequestBuilder(profile: profile).body(baseOptions)
        XCTAssertEqual(built, try Fixture.json("openai-chat.request"))
    }

    func testOpenAIUsesMaxCompletionTokensWhenCapabilitySaysSo() {
        let profile = ProviderProfile.openAICompatible(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            capabilities: Capabilities(usesMaxCompletionTokens: true)
        )
        let built = OpenAIRequestBuilder(profile: profile).body(baseOptions)
        let object = built.objectValue
        XCTAssertNotNil(object?["max_completion_tokens"])
        XCTAssertNil(object?["max_tokens"])
    }

    func testOpenAISystemGoesIntoMessages() {
        let profile = ProviderProfile.openAICompatible(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1"
        )
        let built = OpenAIRequestBuilder(profile: profile).body(baseOptions)
        let messages = built.objectValue?["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.first?.objectValue?["role"], .string("system"))
    }

    func testOpenAIImageBecomesDataURL() {
        let profile = ProviderProfile.openAICompatible(
            id: "openai",
            name: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            capabilities: Capabilities(vision: true)
        )
        let image = ImageAttachmentRef(
            id: "sha256-abc",
            mediaType: "image/png",
            byteCount: 3,
            width: 1,
            height: 1
        )
        var options = baseOptions
        options.messages = [
            Message(role: .user, blocks: [.text("看图"), .image(image)], source: .user)
        ]
        let built = OpenAIRequestBuilder(profile: profile).body(options) { ref in
            "data:\(ref.mediaType);base64,AAAA"
        }
        // 第一条是 system（内容为字符串），用户消息在末尾。
        let parts = built.objectValue?["messages"]?.arrayValue?
            .last?.objectValue?["content"]?.arrayValue ?? []
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1].objectValue?["type"], .string("image_url"))
        XCTAssertEqual(
            parts[1].objectValue?["image_url"]?.objectValue?["url"],
            .string("data:image/png;base64,AAAA")
        )
    }

    // MARK: - Anthropic

    func testAnthropicBodyMatchesFixture() throws {
        var options = baseOptions
        options.model = "claude-sonnet-4-5"
        options.maxTokens = nil

        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        XCTAssertEqual(built, try Fixture.json("anthropic.request"))
    }

    /// Anthropic 的 max_tokens 必填：调用方没给也必须写进报文。
    func testAnthropicAlwaysSendsMaxTokens() {
        var options = baseOptions
        options.maxTokens = nil
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        XCTAssertEqual(built.objectValue?["max_tokens"], .number(4096))
    }

    func testAnthropicSystemIsTopLevel() {
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(baseOptions)
        XCTAssertEqual(built.objectValue?["system"], .string("你是助手"))
        let roles = built.objectValue?["messages"]?.arrayValue?
            .compactMap { $0.objectValue?["role"]?.stringValue } ?? []
        XCTAssertFalse(roles.contains("system"))
    }

    func testAnthropicDropsEmptyMessages() {
        var options = baseOptions
        options.messages = [
            Message(role: .assistant, blocks: [], source: .model(provider: "x", model: "y", meta: nil)),
            Message(role: .user, blocks: [.text("在吗")], source: .user)
        ]
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        XCTAssertEqual(built.objectValue?["messages"]?.arrayValue?.count, 1)
    }

    func testAnthropicImageBecomesBase64Source() {
        let image = ImageAttachmentRef(
            id: "sha256-abc",
            mediaType: "image/jpeg",
            byteCount: 3,
            width: 1,
            height: 1
        )
        var options = baseOptions
        options.messages = [
            Message(role: .user, blocks: [.image(image), .text("看图")], source: .user)
        ]
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options) { _ in
            ("image/jpeg", "AAAA")
        }
        let blocks = built.objectValue?["messages"]?.arrayValue?
            .first?.objectValue?["content"]?.arrayValue ?? []
        XCTAssertEqual(blocks.first?.objectValue?["type"], .string("image"))
        XCTAssertEqual(
            blocks.first?.objectValue?["source"]?.objectValue?["data"],
            .string("AAAA")
        )
    }

    /// 两个族的请求体都不该出现思维链块。
    func testReasoningNeverResent() {
        var options = baseOptions
        options.messages = [
            Message(role: .assistant, blocks: [.reasoning("思考过程"), .text("答案")], source: .model(provider: "p", model: "m", meta: nil))
        ]
        let openAI = OpenAIRequestBuilder(profile: .openAICompatible(id: "x", name: "X", baseURL: "https://x.test/v1")).body(options)
        let anthropic = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        XCTAssertFalse(openAI.descriptionContains("思考过程"))
        XCTAssertFalse(anthropic.descriptionContains("思考过程"))
    }

    // MARK: - 请求头

    func testOpenAIRequestHeaders() throws {
        let adapter = OpenAICompatibleAdapter(
            profile: .openAICompatible(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1"),
            apiKey: "sk-test",
            transport: FixtureTransport(data: Data())
        )
        let request = try adapter.makeRequest(baseOptions)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
    }

    func testAnthropicRequestHeadersAndVersion() throws {
        let adapter = AnthropicAdapter(apiKey: "sk-ant", transport: FixtureTransport(data: Data()))
        let request = try adapter.makeRequest(baseOptions)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
    }
}

extension JSONValue {
    /// 递归检索字符串内容，用于"某段文本不该出现在报文里"这类断言。
    func descriptionContains(_ needle: String) -> Bool {
        switch self {
        case let .string(value):
            return value.contains(needle)
        case let .array(values):
            return values.contains { $0.descriptionContains(needle) }
        case let .object(values):
            return values.values.contains { $0.descriptionContains(needle) }
        case .null, .bool, .number:
            return false
        }
    }
}

// MARK: - Anthropic 角色交替

extension RequestBuilderTests {
    private func messages(of body: JSONValue) -> [[String: JSONValue]] {
        (body.objectValue?["messages"]?.arrayValue ?? []).compactMap(\.objectValue)
    }

    /// 压缩后摘要（context→user）会紧跟一条用户消息，必须合并，
    /// 否则 Anthropic 会因为"roles must alternate"直接 400。
    func testAnthropicMergesConsecutiveUserMessages() {
        var options = baseOptions
        options.messages = [
            Message(role: .context, blocks: [.text("【此前对话的要点】A")], source: .compactionSummary(compactionID: UUID())),
            Message(role: .user, blocks: [.text("继续问")], source: .user)
        ]
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        let list = messages(of: built)

        XCTAssertEqual(list.count, 1, "两条 user 应合并成一条")
        XCTAssertEqual(list.first?["role"], .string("user"))
        let blocks = list.first?["content"]?.arrayValue ?? []
        XCTAssertEqual(blocks.count, 2)
    }

    func testAnthropicKeepsAlternatingMessagesSeparate() {
        var options = baseOptions
        options.messages = [
            Message(role: .user, blocks: [.text("问")], source: .user),
            Message(role: .assistant, blocks: [.text("答")], source: .model(provider: "p", model: "m", meta: nil)),
            Message(role: .user, blocks: [.text("再问")], source: .user)
        ]
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        XCTAssertEqual(messages(of: built).map { $0["role"]?.stringValue }, ["user", "assistant", "user"])
    }

    /// 空消息被跳过时不能打断合并逻辑。
    func testAnthropicSkipsEmptyWithoutBreakingMerge() {
        var options = baseOptions
        options.messages = [
            Message(role: .user, blocks: [.text("第一段")], source: .user),
            Message(role: .user, blocks: [], source: .user),
            Message(role: .user, blocks: [.text("第二段")], source: .user)
        ]
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        let list = messages(of: built)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?["content"]?.arrayValue?.count, 2)
    }
}
