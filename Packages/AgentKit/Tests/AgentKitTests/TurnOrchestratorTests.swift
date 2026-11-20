import CoreKit
import Foundation
import LLMKit
import StorageKit
import XCTest
@testable import AgentKit

private struct StubAdapter: LlmAdapter {
    var profile: ProviderProfile
    var chunks: [StreamChunk]
    var delayNanos: UInt64 = 0

    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                for chunk in chunks {
                    if delayNanos > 0 {
                        try? await Task.sleep(nanoseconds: delayNanos)
                    }
                    if Task.isCancelled { break }
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class TurnOrchestratorTests: XCTestCase {
    private var store: SessionStore!
    private var runtime: LlmRuntime!
    private var sessionID: SessionID!
    private var orchestrator: TurnOrchestrator!

    private let configuration = TurnOrchestrator.Configuration(
        provider: "stub",
        model: "stub-model",
        system: "你是助手"
    )

    override func setUp() async throws {
        store = try SessionStore.inMemory()
        runtime = LlmRuntime()
        sessionID = try await store.createSession().id
        orchestrator = TurnOrchestrator(store: store, runtime: runtime)
    }

    private func register(_ chunks: [StreamChunk], delayNanos: UInt64 = 0) async throws {
        _ = try await runtime.register(
            providers: ["stub"],
            adapter: StubAdapter(
                profile: .openAICompatible(id: "stub", name: "Stub", baseURL: "https://stub.test/v1"),
                chunks: chunks,
                delayNanos: delayNanos
            )
        )
    }

    private func drain(_ stream: AsyncStream<TurnUpdate>) async -> [TurnUpdate] {
        var updates: [TurnUpdate] = []
        for await update in stream { updates.append(update) }
        return updates
    }

    // MARK: - 正常回合

    func testHappyPathPersistsBothMessages() async throws {
        try await register([
            .textDelta(index: 0, text: "答"),
            .usage(TokenUsage(uncachedInputTokens: 5, outputTokens: 2)),
            .finish(.stop, meta: ProviderMeta(responseId: "r1"))
        ])

        let updates = await drain(await orchestrator.send("问", in: sessionID, configuration: configuration))
        let projection = try await store.projection(for: sessionID)

        XCTAssertEqual(projection.messages.map(\.role), [.user, .assistant])
        XCTAssertEqual(projection.messages.map(\.visibleText), ["问", "答"])

        let last = updates.last
        guard case let .finished(result)? = last else { return XCTFail("缺少结束事件") }
        XCTAssertEqual(result.turn, 1)
        XCTAssertFalse(result.interrupted)
        XCTAssertEqual(result.usage?.outputTokens, 2)
    }

    func testTurnAndStepEventsAreRecorded() async throws {
        try await register([.textDelta(index: 0, text: "答"), .finish(.stop, meta: nil)])
        _ = await drain(await orchestrator.send("问", in: sessionID, configuration: configuration))

        let kinds = try await store.records(for: sessionID).map(\.event.kind)
        XCTAssertEqual(kinds, [
            "turn/start", "user/message", "step/start",
            "assistant/message", "step/end", "turn/end"
        ])
    }

    func testSecondTurnIncrementsTurnNumber() async throws {
        try await register([.textDelta(index: 0, text: "一"), .finish(.stop, meta: nil)])
        _ = await drain(await orchestrator.send("第一问", in: sessionID, configuration: configuration))
        _ = await drain(await orchestrator.send("第二问", in: sessionID, configuration: configuration))

        let projection = try await store.projection(for: sessionID)
        XCTAssertEqual(projection.lastTurn, 2)
        XCTAssertFalse(projection.isTurnOpen)
        XCTAssertEqual(projection.messages.count, 4)
    }

    func testUsageIsLogged() async throws {
        try await register([
            .textDelta(index: 0, text: "答"),
            .usage(TokenUsage(uncachedInputTokens: 7, outputTokens: 3, cacheReadTokens: 2)),
            .finish(.stop, meta: nil)
        ])
        _ = await drain(await orchestrator.send("问", in: sessionID, configuration: configuration))

        let total = try await store.totalUsage(for: sessionID)
        XCTAssertEqual(total?.uncachedInputTokens, 7)
        XCTAssertEqual(total?.cacheReadTokens, 2)
    }

    /// 历史里不能出现思维链块，但助手消息应保留它供 UI 折叠展示。
    func testReasoningIsPersistedButNotResent() async throws {
        try await register([
            .reasoningDelta(index: 1, text: "想一想"),
            .textDelta(index: 0, text: "答"),
            .finish(.stop, meta: nil)
        ])
        _ = await drain(await orchestrator.send("问", in: sessionID, configuration: configuration))

        let projection = try await store.projection(for: sessionID)
        let assistant = projection.messages.last
        XCTAssertEqual(assistant?.blocks.count, 2)
    }

    // MARK: - 失败

    func testFailureWithNoContentLeavesAttemptNotMessage() async throws {
        let failure = LlmFailure(message: "500", code: .server, status: 500)
        try await register([.finish(.error(failure), meta: nil)])

        let updates = await drain(await orchestrator.send("问", in: sessionID, configuration: configuration))
        let projection = try await store.projection(for: sessionID)

        XCTAssertEqual(projection.messages.map(\.role), [.user], "不应留下空的助手消息")
        let kinds = try await store.records(for: sessionID).map(\.event.kind)
        XCTAssertTrue(kinds.contains("assistant/attempt"))

        guard case let .finished(result)? = updates.last else { return XCTFail() }
        XCTAssertTrue(result.interrupted)
    }

    func testUnknownProviderFailsGracefully() async throws {
        // 不注册任何适配器
        let updates = await drain(await orchestrator.send("问", in: sessionID, configuration: configuration))
        guard case let .finished(result)? = updates.last else { return XCTFail() }
        guard case let .error(failure) = result.finish else { return XCTFail("期望 error") }
        XCTAssertEqual(failure.code, .noAdapter)
    }

    // MARK: - 取消

    /// 中断时保留已产出的可见前缀，并标记 interrupted。
    func testCancelKeepsPartialText() async throws {
        try await register([
            .textDelta(index: 0, text: "半句"),
            .textDelta(index: 0, text: "话"),
            .textDelta(index: 0, text: "还没说完"),
            .finish(.stop, meta: nil)
        ], delayNanos: 30_000_000)

        let stream = await orchestrator.send("问", in: sessionID, configuration: configuration)
        let canceller = orchestrator!
        let consumer = Task { () -> [TurnUpdate] in
            var updates: [TurnUpdate] = []
            for await update in stream {
                updates.append(update)
                if case .chunk = update {
                    await canceller.cancel()
                }
            }
            return updates
        }
        let updates = await consumer.value

        guard case let .finished(result)? = updates.last else { return XCTFail() }
        XCTAssertTrue(result.interrupted)

        let projection = try await store.projection(for: sessionID)
        let assistant = projection.messages.last
        XCTAssertEqual(assistant?.role, .assistant)
        let text = assistant?.visibleText ?? ""
        XCTAssertTrue("半句话还没说完".hasPrefix(text), "中断应保留前缀，实际：\(text)")
        XCTAssertTrue(text.count < "半句话还没说完".count, "应当被截断")

        let token = try await store.session(sessionID)
        XCTAssertNotNil(token)
    }

    /// 一个字都没出就取消：不留助手消息，只留 attempt。
    func testCancelBeforeAnyTokenLeavesAttempt() async throws {
        try await register([
            .textDelta(index: 0, text: "来不及"),
            .finish(.stop, meta: nil)
        ], delayNanos: 200_000_000)

        let stream = await orchestrator.send("问", in: sessionID, configuration: configuration)
        let canceller = orchestrator!
        let consumer = Task { () -> [TurnUpdate] in
            var updates: [TurnUpdate] = []
            for await update in stream {
                updates.append(update)
                if case .started = update {
                    await canceller.cancel()
                }
            }
            return updates
        }
        _ = await consumer.value

        let projection = try await store.projection(for: sessionID)
        XCTAssertEqual(projection.messages.map(\.role), [.user])
    }
}
