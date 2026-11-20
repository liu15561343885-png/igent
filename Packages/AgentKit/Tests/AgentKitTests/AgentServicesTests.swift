import CoreKit
import Foundation
import LLMKit
import StorageKit
import XCTest
@testable import AgentKit

private struct EchoAdapter: LlmAdapter {
    var profile: ProviderProfile
    var reply: String
    var usage: TokenUsage?

    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(index: 0, text: reply))
            if let usage { continuation.yield(.usage(usage)) }
            continuation.yield(.finish(.stop, meta: nil))
            continuation.finish()
        }
    }
}

final class CompactionServiceTests: XCTestCase {
    private var store: SessionStore!
    private var runtime: LlmRuntime!
    private var sessionID: SessionID!

    override func setUp() async throws {
        store = try SessionStore.inMemory()
        runtime = LlmRuntime()
        sessionID = try await store.createSession().id
        _ = try await runtime.register(
            providers: ["stub"],
            adapter: EchoAdapter(
                profile: .openAICompatible(id: "stub", name: "Stub", baseURL: "https://stub.test/v1"),
                reply: "要点一：方案可行。要点二：成本偏高。",
                usage: TokenUsage(uncachedInputTokens: 50, outputTokens: 20)
            )
        )
    }

    private func seed(_ turns: Int) async throws {
        for index in 0..<turns {
            let user = Message(role: .user, blocks: [.text("问题\(index)")], source: .user)
            let answer = Message(
                role: .assistant,
                blocks: [.text("回答\(index)")],
                source: .model(provider: "stub", model: "stub", meta: nil)
            )
            try await store.append(.userMessage(user), to: sessionID, surfaceOp: .append)
            try await store.append(
                .assistantMessage(answer, usage: nil, interrupted: false),
                to: sessionID,
                surfaceOp: .append
            )
        }
    }

    func testCompactsOldMessagesIntoSummary() async throws {
        try await seed(8) // 16 条
        let service = CompactionService(store: store, runtime: runtime)
        let outcome = try await service.compact(
            .init(sessionID: sessionID, provider: "stub", model: "stub", keepRecentMessages: 4)
        )

        let result = try XCTUnwrap(outcome)
        XCTAssertEqual(result.shadowedCount, 12)

        let projection = try await store.projection(for: sessionID)
        XCTAssertEqual(projection.messages.count, 5, "12 条被压成 1 条 + 保留 4 条")
        XCTAssertEqual(projection.messages.first?.role, .context)
        XCTAssertTrue(projection.messages.first?.visibleText.contains("要点一") ?? false)
        // 最近 4 条仍在
        XCTAssertEqual(projection.messages.suffix(4).map(\.visibleText), ["问题6", "回答6", "问题7", "回答7"])
    }

    func testShortSessionIsNotCompacted() async throws {
        try await seed(3) // 6 条，低于默认 12
        let service = CompactionService(store: store, runtime: runtime)
        let outcome = try await service.compact(
            .init(sessionID: sessionID, provider: "stub", model: "stub")
        )
        XCTAssertNil(outcome)
    }

    /// 压缩是一次模型调用，用量要记账。
    func testCompactionUsageIsLogged() async throws {
        try await seed(8)
        let service = CompactionService(store: store, runtime: runtime)
        _ = try await service.compact(
            .init(sessionID: sessionID, provider: "stub", model: "stub", keepRecentMessages: 4)
        )
        let total = try await store.totalUsage(for: sessionID)
        XCTAssertEqual(total?.outputTokens, 20)
    }

    /// 日志里原始事件一条不少——压缩只是表面操作。
    func testOriginalEventsRemainInLog() async throws {
        try await seed(8)
        let before = try await store.records(for: sessionID).count
        let service = CompactionService(store: store, runtime: runtime)
        _ = try await service.compact(
            .init(sessionID: sessionID, provider: "stub", model: "stub", keepRecentMessages: 4)
        )
        let after = try await store.records(for: sessionID).count
        XCTAssertEqual(after, before + 1, "只多了一条摘要消息")
    }

    func testRenderIncludesRoles() {
        let messages = [
            Message(role: .user, blocks: [.text("问")], source: .user),
            Message(role: .assistant, blocks: [.text("答")], source: .model(provider: "p", model: "m", meta: nil))
        ]
        let text = CompactionService.render(messages)
        XCTAssertTrue(text.contains("用户：问"))
        XCTAssertTrue(text.contains("助手：答"))
    }
}

final class TitleServiceTests: XCTestCase {
    private func makeStore() async throws -> (SessionStore, LlmRuntime, SessionID) {
        let store = try SessionStore.inMemory()
        let runtime = LlmRuntime()
        _ = try await runtime.register(
            providers: ["stub"],
            adapter: EchoAdapter(
                profile: .openAICompatible(id: "stub", name: "Stub", baseURL: "https://stub.test/v1"),
                reply: "\"周报模板讨论。\"",
                usage: nil
            )
        )
        let session = try await store.createSession()
        let user = Message(role: .user, blocks: [.text("帮我整理周报")], source: .user)
        try await store.append(.userMessage(user), to: session.id, surfaceOp: .append)
        return (store, runtime, session.id)
    }

    func testGeneratesAndStoresTitle() async throws {
        let (store, runtime, id) = try await makeStore()
        let service = TitleService(store: store, runtime: runtime)
        let title = await service.generateTitle(sessionID: id, provider: "stub", model: "stub")

        XCTAssertEqual(title, "周报模板讨论")
        let session = try await store.session(id)
        XCTAssertEqual(session?.title, "周报模板讨论")
    }

    /// 已经有自定义标题就不该覆盖。
    func testDoesNotOverwriteCustomTitle() async throws {
        let (store, runtime, id) = try await makeStore()
        try await store.rename(id, to: "我自己起的")
        let service = TitleService(store: store, runtime: runtime)
        let title = await service.generateTitle(sessionID: id, provider: "stub", model: "stub")

        XCTAssertNil(title)
        let session = try await store.session(id)
        XCTAssertEqual(session?.title, "我自己起的")
    }

    func testCleansQuotesAndSentenceEnd() {
        XCTAssertEqual(TitleService.clean("\"标题。\""), "标题")
        XCTAssertEqual(TitleService.clean("「标题」\n多余的话"), "标题")
        XCTAssertNil(TitleService.clean("   "))
        XCTAssertEqual(TitleService.clean(String(repeating: "字", count: 100))?.count, 24)
    }
}

final class SessionExporterTests: XCTestCase {
    private var session: SessionSummary {
        SessionSummary(
            id: UUID(),
            title: "周报整理",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            provider: "deepseek",
            model: "deepseek-chat"
        )
    }

    func testMarkdownHasTitleAndRoles() {
        let messages = [
            Message(role: .user, blocks: [.text("帮我写周报")], source: .user),
            Message(
                role: .assistant,
                blocks: [.text("好的：\n\n```swift\nlet a = 1\n```")],
                source: .model(provider: "p", model: "m", meta: nil)
            )
        ]
        let markdown = SessionExporter.markdown(
            session: session,
            messages: messages,
            totalUsage: TokenUsage(uncachedInputTokens: 100, outputTokens: 40)
        )

        XCTAssertTrue(markdown.contains("# 周报整理"))
        XCTAssertTrue(markdown.contains("## 我"))
        XCTAssertTrue(markdown.contains("## 助手"))
        XCTAssertTrue(markdown.contains("deepseek-chat"))
        XCTAssertTrue(markdown.contains("```swift"))
        XCTAssertTrue(markdown.contains("↑100 ↓40 tokens"))
    }

    /// 思维链默认不导出，开了才带。
    func testReasoningIsOptional() {
        let message = Message(
            role: .assistant,
            blocks: [.reasoning("想了想"), .text("答案")],
            source: .model(provider: "p", model: "m", meta: nil)
        )
        let without = SessionExporter.markdown(session: session, messages: [message])
        XCTAssertFalse(without.contains("想了想"))

        let with = SessionExporter.markdown(session: session, messages: [message], includeReasoning: true)
        XCTAssertTrue(with.contains("想了想"))
    }

    func testImagePlaceholder() {
        let message = Message(
            role: .user,
            blocks: [
                .image(ImageAttachmentRef(id: "x", mediaType: "image/jpeg", byteCount: 1, width: 1, height: 1)),
                .text("看图")
            ],
            source: .user
        )
        let markdown = SessionExporter.markdown(session: session, messages: [message])
        XCTAssertTrue(markdown.contains("_[图片未随文本导出]_"))
    }

    func testFilenameSanitisesSlashes() {
        var dirty = session
        dirty.title = "a/b:c"
        XCTAssertEqual(SessionExporter.filename(for: dirty), "a-b-c.md")
    }
}
