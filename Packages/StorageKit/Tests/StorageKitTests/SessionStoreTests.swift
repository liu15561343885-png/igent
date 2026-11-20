import CoreKit
import Foundation
import LLMKit
import XCTest
@testable import StorageKit

final class SessionStoreTests: XCTestCase {
    private func store() throws -> SessionStore {
        try SessionStore.inMemory()
    }

    private func userText(_ value: String) -> Message {
        Message(role: .user, blocks: [.text(value)], source: .user)
    }

    private func assistantText(_ value: String) -> Message {
        Message(
            role: .assistant,
            blocks: [.text(value)],
            source: .model(provider: "p", model: "m", meta: nil)
        )
    }

    // MARK: - 会话

    func testCreateAndListSessions() async throws {
        let store = try store()
        let first = try await store.createSession(title: "第一个")
        let second = try await store.createSession(title: "第二个")

        let list = try await store.sessions()
        XCTAssertEqual(Set(list.map(\.id)), [first.id, second.id])
        XCTAssertEqual(list.count, 2)
    }

    func testRenameAndDelete() async throws {
        let store = try store()
        let session = try await store.createSession()
        try await store.rename(session.id, to: "改名了")

        let renamed = try await store.session(session.id)
        XCTAssertEqual(renamed?.title, "改名了")

        try await store.delete(session.id)
        let after = try await store.sessions()
        XCTAssertTrue(after.isEmpty)
    }

    /// 会话被删除时事件一并清掉，不留孤儿行。
    func testDeleteRemovesEvents() async throws {
        let store = try store()
        let session = try await store.createSession()
        try await store.append(.userMessage(userText("hi")), to: session.id)

        try await store.delete(session.id)
        let records = try await store.records(for: session.id)
        XCTAssertTrue(records.isEmpty)
    }

    // MARK: - 事件

    func testSequenceIsMonotonicPerSession() async throws {
        let store = try store()
        let a = try await store.createSession()
        let b = try await store.createSession()

        let a0 = try await store.append(.turnStart(turn: 1), to: a.id)
        let a1 = try await store.append(.userMessage(userText("hi")), to: a.id, surfaceOp: .append)
        let b0 = try await store.append(.turnStart(turn: 1), to: b.id)

        XCTAssertEqual([a0, a1], [0, 1])
        XCTAssertEqual(b0, 0, "seq 是按会话独立的")
    }

    func testRecordsPreserveOrderAndPayload() async throws {
        let store = try store()
        let session = try await store.createSession()
        try await store.append(.userMessage(userText("一")), to: session.id, surfaceOp: .append)
        try await store.append(.assistantMessage(assistantText("二"), usage: nil, interrupted: false), to: session.id, surfaceOp: .append)

        let records = try await store.records(for: session.id)
        XCTAssertEqual(records.map(\.seq), [0, 1])
        XCTAssertEqual(records.compactMap { $0.event.surfaceMessage?.visibleText }, ["一", "二"])
        XCTAssertEqual(records.map(\.surfaceOp), [.append, .append])
    }

    func testIncrementalRead() async throws {
        let store = try store()
        let session = try await store.createSession()
        for index in 0..<5 {
            try await store.append(.userMessage(userText("\(index)")), to: session.id, surfaceOp: .append)
        }
        let tail = try await store.records(for: session.id, after: 2)
        XCTAssertEqual(tail.map(\.seq), [3, 4])
    }

    func testUsageAndFinishSurviveRoundTrip() async throws {
        let store = try store()
        let session = try await store.createSession()
        let usage = TokenUsage(uncachedInputTokens: 10, outputTokens: 5, cacheReadTokens: 2)
        try await store.append(
            .assistantMessage(assistantText("答"), usage: usage, interrupted: true),
            to: session.id,
            surfaceOp: .append
        )

        let record = try await store.records(for: session.id).first
        guard case let .assistantMessage(_, restoredUsage, interrupted) = record?.event else {
            return XCTFail("事件类型不对")
        }
        XCTAssertEqual(restoredUsage, usage)
        XCTAssertTrue(interrupted)
    }

    // MARK: - 投影

    func testProjectionAppliesReplace() async throws {
        let store = try store()
        let session = try await store.createSession()

        try await store.append(.userMessage(userText("问")), to: session.id, surfaceOp: .append)
        let oldSeq = try await store.append(
            .assistantMessage(assistantText("旧答案"), usage: nil, interrupted: false),
            to: session.id,
            surfaceOp: .append
        )
        try await store.append(
            .assistantMessage(assistantText("新答案"), usage: nil, interrupted: false),
            to: session.id,
            surfaceOp: .replace(startSeq: oldSeq, endSeq: oldSeq)
        )

        let projection = try await store.projection(for: session.id)
        XCTAssertEqual(projection.messages.map(\.visibleText), ["问", "新答案"])

        // 日志里旧事件仍在
        let records = try await store.records(for: session.id)
        XCTAssertEqual(records.count, 3)
    }

    // MARK: - 用量聚合

    func testTotalUsageAggregates() async throws {
        let store = try store()
        let session = try await store.createSession()
        try await store.logUsage(
            sessionID: session.id, turn: 1, step: 1, provider: "p", model: "m",
            purpose: nil, usage: TokenUsage(uncachedInputTokens: 10, outputTokens: 5)
        )
        try await store.logUsage(
            sessionID: session.id, turn: 2, step: 2, provider: "p", model: "m",
            purpose: .compaction, usage: TokenUsage(uncachedInputTokens: 3, outputTokens: 1, cacheReadTokens: 7)
        )

        let total = try await store.totalUsage(for: session.id)
        XCTAssertEqual(total?.uncachedInputTokens, 13)
        XCTAssertEqual(total?.outputTokens, 6)
        XCTAssertEqual(total?.cacheReadTokens, 7)
    }

    // MARK: - 厂商配置

    func testProfileRoundTrip() async throws {
        let store = try store()
        let profile = ProviderProfile.azure(resource: "res", deployment: "gpt-4o")
        try await store.saveProfile(profile, sort: 1)

        let loaded = try await store.profiles()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, profile)
    }

    func testProfileUpsertDoesNotDuplicate() async throws {
        let store = try store()
        var profile = ProviderProfile.openAICompatible(id: "x", name: "X", baseURL: "https://x.test/v1")
        try await store.saveProfile(profile)
        profile.name = "X 改名"
        try await store.saveProfile(profile)

        let loaded = try await store.profiles()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "X 改名")
    }

    func testDeleteProfile() async throws {
        let store = try store()
        try await store.saveProfile(.openAICompatible(id: "x", name: "X", baseURL: "https://x.test/v1"))
        try await store.deleteProfile(id: "x")
        let loaded = try await store.profiles()
        XCTAssertTrue(loaded.isEmpty)
    }

    // MARK: - 落盘

    func testPersistenceAcrossReopen() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("igent-store-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        let sessionID: SessionID
        do {
            let store = try SessionStore(url: url)
            let session = try await store.createSession(title: "持久化")
            sessionID = session.id
            try await store.append(.userMessage(userText("你好")), to: session.id, surfaceOp: .append)
        }

        let reopened = try SessionStore(url: url)
        let projection = try await reopened.projection(for: sessionID)
        XCTAssertEqual(projection.messages.map(\.visibleText), ["你好"])

        let summary = try await reopened.session(sessionID)
        XCTAssertEqual(summary?.title, "持久化")
    }
}
