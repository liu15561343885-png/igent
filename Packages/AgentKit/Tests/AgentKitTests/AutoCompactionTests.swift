import CoreKit
import Foundation
import LLMKit
import StorageKit
import XCTest
@testable import AgentKit

/// 按调用用途返回不同文本，方便区分"压缩调用"和"对话调用"。
private final class PurposeAdapter: LlmAdapter, @unchecked Sendable {
    let profile: ProviderProfile
    private let lock = NSLock()
    private var seenPurposes: [CallPurpose?] = []
    private var sentMessageCounts: [Int] = []
    /// 第一次对话调用先返回上下文溢出，用来测兜底恢复。
    var failFirstTurnWithOverflow = false
    private var turnAttempts = 0

    init(profile: ProviderProfile) {
        self.profile = profile
    }

    var purposes: [CallPurpose?] {
        lock.lock(); defer { lock.unlock() }
        return seenPurposes
    }

    var messageCounts: [Int] {
        lock.lock(); defer { lock.unlock() }
        return sentMessageCounts
    }

    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        lock.lock()
        seenPurposes.append(options.purpose)
        sentMessageCounts.append(options.messages.count)
        if options.purpose == nil { turnAttempts += 1 }
        let attempt = turnAttempts
        lock.unlock()

        let isCompaction = options.purpose == .compaction
        let shouldOverflow = failFirstTurnWithOverflow && !isCompaction && attempt == 1

        return AsyncThrowingStream { continuation in
            if shouldOverflow {
                continuation.yield(.finish(
                    .error(LlmFailure(message: "context too long", code: .contextWindowExceeded)),
                    meta: nil
                ))
                continuation.finish()
                return
            }
            let text = isCompaction ? "压缩后的要点" : "正常回答"
            continuation.yield(.textDelta(index: 0, text: text))
            continuation.yield(.finish(.stop, meta: nil))
            continuation.finish()
        }
    }
}

final class AutoCompactionTests: XCTestCase {
    private var store: SessionStore!
    private var runtime: LlmRuntime!
    private var sessionID: SessionID!
    private var adapter: PurposeAdapter!

    override func setUp() async throws {
        store = try SessionStore.inMemory()
        runtime = LlmRuntime()
        sessionID = try await store.createSession().id
        adapter = PurposeAdapter(
            profile: .openAICompatible(id: "stub", name: "Stub", baseURL: "https://stub.test/v1")
        )
        _ = try await runtime.register(providers: ["stub"], adapter: adapter)
    }

    private func seed(_ turns: Int) async throws {
        for index in 0..<turns {
            let user = Message(role: .user, blocks: [.text(String(repeating: "问题", count: 50) + "\(index)")], source: .user)
            let answer = Message(
                role: .assistant,
                blocks: [.text(String(repeating: "回答", count: 50) + "\(index)")],
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

    private func configuration(contextWindow: Int) -> TurnOrchestrator.Configuration {
        .init(provider: "stub", model: "stub", contextWindow: contextWindow)
    }

    /// 历史远超阈值时，开回合前应自动压缩：先有一次 compaction 调用。
    func testAutoCompactsBeforeTurnWhenOverThreshold() async throws {
        try await seed(7) // 14 条
        let orchestrator = TurnOrchestrator(
            store: store,
            runtime: runtime,
            policy: CompactionPolicy(thresholdRatio: 0.5, retainRatio: 0.2, minimumMessages: 6)
        )

        let stream = await orchestrator.send(
            "新问题",
            in: sessionID,
            configuration: configuration(contextWindow: 800)
        )
        for await _ in stream {}

        let purposes = adapter.purposes
        XCTAssertEqual(purposes.first, .compaction, "应当先压缩再对话")
        XCTAssertNil(purposes.last ?? nil, "最后一次是正常对话调用")

        let records = try await store.records(for: sessionID)
        XCTAssertTrue(records.contains { record in
            if case let .contextMessage(message) = record.event,
               case .compactionSummary = message.source { return true }
            return false
        })
    }

    /// 窗口很大时不该压缩。
    func testNoCompactionWhenWindowIsLarge() async throws {
        try await seed(7)
        let orchestrator = TurnOrchestrator(store: store, runtime: runtime)
        let stream = await orchestrator.send(
            "新问题",
            in: sessionID,
            configuration: configuration(contextWindow: 200_000)
        )
        for await _ in stream {}

        XCTAssertFalse(adapter.purposes.contains(.compaction))
    }

    /// 厂商报溢出：压缩一次后重试，第二次成功。
    func testOverflowRecoveryRetriesAfterCompaction() async throws {
        try await seed(7)
        adapter.failFirstTurnWithOverflow = true

        let orchestrator = TurnOrchestrator(
            store: store,
            runtime: runtime,
            policy: CompactionPolicy(thresholdRatio: 0.99, retainRatio: 0.2, minimumMessages: 6)
        )
        // 窗口给小一点，压缩才有可压的区间。
        let stream = await orchestrator.send(
            "新问题",
            in: sessionID,
            configuration: configuration(contextWindow: 2_000)
        )
        var last: TurnUpdate?
        for await update in stream { last = update }

        XCTAssertTrue(adapter.purposes.contains(.compaction), "溢出后应触发压缩")
        XCTAssertEqual(adapter.purposes.filter { $0 == nil }.count, 2, "对话调用应重试一次")

        guard case let .finished(result)? = last else { return XCTFail("缺少结束事件") }
        XCTAssertEqual(result.finish, .stop)
        let projection = try await store.projection(for: sessionID)
        XCTAssertEqual(projection.messages.last?.visibleText, "正常回答")
    }

    /// 关闭策略后不做自动压缩。
    func testPolicyDisabledSkipsAutoCompaction() async throws {
        try await seed(7)
        let orchestrator = TurnOrchestrator(store: store, runtime: runtime, policy: nil)
        let stream = await orchestrator.send(
            "新问题",
            in: sessionID,
            configuration: configuration(contextWindow: 500)
        )
        for await _ in stream {}

        XCTAssertFalse(adapter.purposes.contains(.compaction))
    }
}

final class CompactionPolicyTests: XCTestCase {
    func testThresholdScalesWithWindow() {
        let policy = CompactionPolicy(thresholdRatio: 0.8)
        XCTAssertEqual(policy.thresholdTokens(contextWindow: 100_000, reservedOutput: 0), 80_000)
        XCTAssertEqual(policy.thresholdTokens(contextWindow: 8_000, reservedOutput: 4_000), 3_200)
    }

    /// 小窗口也要有个下限，否则阈值会掉到几百 token。
    func testThresholdHasFloor() {
        let policy = CompactionPolicy(thresholdRatio: 0.8)
        XCTAssertGreaterThan(policy.thresholdTokens(contextWindow: 100, reservedOutput: 4_096), 0)
    }

    func testShouldCompactRequiresMinimumMessages() {
        let policy = CompactionPolicy(minimumMessages: 10)
        XCTAssertFalse(policy.shouldCompact(inputTokens: 999_999, messageCount: 4, contextWindow: 1000, reservedOutput: 0))
        XCTAssertTrue(policy.shouldCompact(inputTokens: 900, messageCount: 10, contextWindow: 1000, reservedOutput: 0))
    }

    /// 压缩区间：保留足够 token 的尾部，其余全压。
    func testCompactCountRetainsTail() {
        let policy = CompactionPolicy(minimumMessages: 4)
        let tokens = [100, 100, 100, 100, 100, 100] // 总量 600
        let count = policy.compactCount(messageTokens: tokens, retainTokens: 250, minimumMessages: 4)
        XCTAssertEqual(count, 3, "保留最后 3 条（300 token ≥ 250）")
    }

    /// 压缩完必须至少留两条，否则没有上下文可用。
    func testCompactCountKeepsAtLeastTwo() {
        let policy = CompactionPolicy(minimumMessages: 2)
        let tokens = Array(repeating: 10, count: 10)
        let count = policy.compactCount(messageTokens: tokens, retainTokens: 1, minimumMessages: 2)
        XCTAssertEqual(count, 8)
    }

    func testCompactCountZeroWhenTooShort() {
        let policy = CompactionPolicy(minimumMessages: 8)
        let count = policy.compactCount(messageTokens: [10, 10, 10], retainTokens: 1, minimumMessages: 8)
        XCTAssertEqual(count, 0)
    }
}

final class TokenEstimatorTests: XCTestCase {
    func testChineseIsDenserThanEnglish() {
        let chinese = TokenEstimator.estimate(String(repeating: "字", count: 100))
        let english = TokenEstimator.estimate(String(repeating: "a", count: 100))
        XCTAssertGreaterThan(chinese, english)
    }

    func testEmptyTextIsZero() {
        XCTAssertEqual(TokenEstimator.estimate(""), 0)
    }

    func testMessageOverheadApplied() {
        let message = Message(role: .user, blocks: [.text("hi")], source: .user)
        XCTAssertGreaterThanOrEqual(TokenEstimator.estimate(message), 4)
    }

    func testImageCountsAsSubstantial() {
        let textOnly = Message(role: .user, blocks: [.text("看图")], source: .user)
        let withImage = Message(
            role: .user,
            blocks: [
                .image(ImageAttachmentRef(id: "x", mediaType: "image/jpeg", byteCount: 1, width: 1, height: 1)),
                .text("看图")
            ],
            source: .user
        )
        XCTAssertGreaterThan(TokenEstimator.estimate(withImage), TokenEstimator.estimate(textOnly) + 500)
    }
}

/// 摘要调用专用的桩：永远返回一句摘要文本。
private struct SummaryOnlyAdapter: LlmAdapter {
    var profile: ProviderProfile

    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(index: 0, text: "要点若干"))
            continuation.yield(.finish(.stop, meta: nil))
            continuation.finish()
        }
    }
}

final class CompactionRepeatTests: XCTestCase {
    /// 第二次压缩必须把第一次的摘要一起覆盖掉。
    ///
    /// 这里有个隐蔽前提：替换节点的 seq 取**区间起点**而不是新事件 seq。
    /// 否则 messageSeqs 非单调，第二次算出的 start > end，replace 删不掉任何东西，
    /// 结果是摘要越堆越多、上下文一点没瘦。
    func testSecondCompactionShadowsTheFirstSummary() async throws {
        let store = try SessionStore.inMemory()
        let runtime = LlmRuntime()
        _ = try await runtime.register(
            providers: ["stub"],
            adapter: SummaryOnlyAdapter(
                profile: .openAICompatible(id: "stub", name: "S", baseURL: "https://stub.test/v1")
            )
        )
        let session = try await store.createSession()
        for index in 0..<10 {
            let user = Message(role: .user, blocks: [.text("问题\(index)")], source: .user)
            let answer = Message(
                role: .assistant, blocks: [.text("回答\(index)")],
                source: .model(provider: "stub", model: "stub", meta: nil)
            )
            _ = try await store.append(.userMessage(user), to: session.id, surfaceOp: .append)
            _ = try await store.append(
                .assistantMessage(answer, usage: nil, interrupted: false),
                to: session.id, surfaceOp: .append
            )
        }

        let compactor = CompactionService(store: store, runtime: runtime)

        // 第一次保留 8 条，第二次只保留 6 条 → 第二轮的压缩区间会**包含**第一份摘要。
        // 这正是会触发 size 倒置的场景：只压摘要本身时是看不出来的。
        _ = try await compactor.compact(.init(
            sessionID: session.id, provider: "stub", model: "stub", keepRecentMessages: 8
        ))
        let afterFirst = try await store.projection(for: session.id)

        _ = try await compactor.compact(.init(
            sessionID: session.id, provider: "stub", model: "stub", keepRecentMessages: 6
        ))
        let afterSecond = try await store.projection(for: session.id)

        let summaries = afterSecond.messages.filter {
            if case .compactionSummary = $0.source { return true }
            return false
        }
        XCTAssertEqual(summaries.count, 1, "第二次压缩应覆盖第一份摘要，而不是叠加")
        XCTAssertLessThanOrEqual(afterSecond.messages.count, afterFirst.messages.count)
        XCTAssertEqual(
            afterSecond.messageSeqs, afterSecond.messageSeqs.sorted(),
            "投影的 seq 必须单调，否则后续区间计算会倒置"
        )
    }
}
