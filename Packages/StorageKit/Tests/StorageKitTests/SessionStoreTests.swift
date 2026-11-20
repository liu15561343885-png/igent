import CoreKit
import Foundation
import LLMKit
import XCTest
@testable import StorageKit

final class StorageHygieneTests: XCTestCase {
    /// 删会话必须连带删掉用量行，否则 usage_log 只增不减。
    func testDeletingSessionRemovesUsageRows() async throws {
        let store = try SessionStore.inMemory()
        let session = try await store.createSession()
        try await store.logUsage(
            sessionID: session.id, turn: 1, step: 1,
            provider: "p", model: "m", purpose: nil,
            usage: TokenUsage(uncachedInputTokens: 10, outputTokens: 5)
        )
        let before = try await store.totalUsage(for: session.id)
        XCTAssertNotNil(before)

        try await store.delete(session.id)
        let after = try await store.totalUsage(for: session.id)
        XCTAssertNil(after)
    }

    /// 附件是内容寻址、多会话共享，所以要先按引用集合判断再清理。
    func testReferencedAttachmentPathsAreExtracted() async throws {
        let store = try SessionStore.inMemory()
        let session = try await store.createSession()
        let ref = ImageAttachmentRef(
            id: "abcdef", mediaType: "image/jpeg", byteCount: 3,
            width: 1, height: 1, relativePath: "ab/abcdef.jpg"
        )
        let message = Message(role: .user, blocks: [.image(ref)], source: .user)
        _ = try await store.append(.userMessage(message), to: session.id, surfaceOp: .append)

        let paths = try await store.referencedAttachmentPaths()
        XCTAssertTrue(paths.contains("ab/abcdef.jpg"))
    }

    /// 被引用的文件**绝不能**删。这条测试是防止把用户图片删光的回归护栏：
    /// 枚举器会规范化 /var → /private/var，前缀算法一旦写错就会全删。
    func testPruneKeepsReferencedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-\(UUID().uuidString)")
        let attachments = try AttachmentStore(root: root)
        let normalized = NormalizedImage(
            data: Data([0xFF, 0xD8, 0xFF, 0x01]), mediaType: "image/jpeg", width: 1, height: 1
        )
        let ref = try await attachments.save(normalized)
        let path = try XCTUnwrap(ref.relativePath)

        let removed = await attachments.prune(referenced: [path])
        XCTAssertEqual(removed, 0, "被引用的文件不应被回收")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(path).path
        ))
    }

    /// 没被任何事件引用的文件应当被回收。
    func testPruneRemovesUnreferencedFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachments-\(UUID().uuidString)")
        let attachments = try AttachmentStore(root: root)
        let normalized = NormalizedImage(
            data: Data([0xFF, 0xD8, 0xFF]), mediaType: "image/jpeg", width: 1, height: 1
        )
        let ref = try await attachments.save(normalized)
        XCTAssertNotNil(ref.relativePath)

        let removed = await attachments.prune(referenced: [])
        XCTAssertEqual(removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(ref.relativePath!).path
        ))
    }
}

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
