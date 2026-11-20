import Foundation
import XCTest
@testable import CoreKit

final class SurfaceProjectionTests: XCTestCase {
    private let sessionID = UUID()

    private func record(
        _ seq: Int64,
        _ event: SessionEvent,
        _ op: SurfaceOp? = nil
    ) -> SessionRecord {
        SessionRecord(seq: seq, sessionID: sessionID, time: Date(timeIntervalSince1970: TimeInterval(seq)), event: event, surfaceOp: op)
    }

    private func text(_ value: String, role: MessageRole) -> Message {
        Message(role: role, blocks: [.text(value)], source: role == .assistant ? .model(provider: "p", model: "m", meta: nil) : .user)
    }

    func testAppendBuildsOrderedMessages() {
        let records = [
            record(0, .userMessage(text("一", role: .user)), .append),
            record(1, .assistantMessage(text("二", role: .assistant), usage: nil, interrupted: false), .append),
            record(2, .userMessage(text("三", role: .user)), .append)
        ]
        let projection = SurfaceProjection.build(from: records)
        XCTAssertEqual(projection.messages.map(\.visibleText), ["一", "二", "三"])
        XCTAssertEqual(projection.messageSeqs, [0, 1, 2])
    }

    /// 重生成：新助手消息 replace 旧的，表面只剩一条。
    func testReplaceSwapsSingleMessage() {
        let records = [
            record(0, .userMessage(text("问", role: .user)), .append),
            record(1, .assistantMessage(text("旧答", role: .assistant), usage: nil, interrupted: false), .append),
            record(2, .assistantMessage(text("新答", role: .assistant), usage: nil, interrupted: false), .replace(startSeq: 1, endSeq: 1))
        ]
        let projection = SurfaceProjection.build(from: records)
        XCTAssertEqual(projection.messages.map(\.visibleText), ["问", "新答"])
        // 替换节点接管被替换区间的起点 seq（1），保证 messageSeqs 单调递增。
        XCTAssertEqual(projection.messageSeqs, [0, 1])
    }

    /// 压缩：一条摘要 replace 掉一段历史。
    func testReplaceCoversRange() {
        let records = [
            record(0, .userMessage(text("一", role: .user)), .append),
            record(1, .assistantMessage(text("二", role: .assistant), usage: nil, interrupted: false), .append),
            record(2, .userMessage(text("三", role: .user)), .append),
            record(3, .contextMessage(text("[摘要]", role: .context)), .replace(startSeq: 0, endSeq: 2))
        ]
        let projection = SurfaceProjection.build(from: records)
        XCTAssertEqual(projection.messages.map(\.visibleText), ["[摘要]"])
        XCTAssertEqual(projection.messageSeqs, [0], "摘要承接被遮蔽区间的起点 seq")
    }

    /// 日志里的旧事件仍在，只是被遮蔽；这保证可回滚。
    func testReplacedRecordsRemainInLog() {
        let records = [
            record(0, .assistantMessage(text("旧", role: .assistant), usage: nil, interrupted: false), .append),
            record(1, .assistantMessage(text("新", role: .assistant), usage: nil, interrupted: false), .replace(startSeq: 0, endSeq: 0))
        ]
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(SurfaceProjection.build(from: records).messages.count, 1)
    }

    func testTurnTracking() {
        let records = [
            record(0, .turnStart(turn: 1)),
            record(1, .userMessage(text("问", role: .user)), .append),
            record(2, .stepStart(turn: 1, step: 1)),
            record(3, .stepEnd(turn: 1, step: 1)),
            record(4, .assistantMessage(text("答", role: .assistant), usage: nil, interrupted: false), .append),
            record(5, .turnEnd(turn: 1, reason: .completed))
        ]
        let projection = SurfaceProjection.build(from: records)
        XCTAssertEqual(projection.lastTurn, 1)
        XCTAssertFalse(projection.isTurnOpen)
        XCTAssertEqual(projection.messages.count, 2)
    }

    func testOpenTurnDetected() {
        let records = [
            record(0, .turnStart(turn: 1)),
            record(1, .userMessage(text("问", role: .user)), .append)
        ]
        XCTAssertTrue(SurfaceProjection.build(from: records).isTurnOpen)
    }

    /// 过程事件与失败尝试不进表面。
    func testNonSurfaceEventsExcluded() {
        let records = [
            record(0, .stepStart(turn: 1, step: 1)),
            record(1, .assistantAttempt(turn: 1, step: 1, failure: LlmFailure(message: "boom", code: .server))),
            record(2, .titleGenerated("标题")),
            record(3, .userMessage(text("只有我", role: .user)), .append)
        ]
        XCTAssertEqual(SurfaceProjection.build(from: records).messages.map(\.visibleText), ["只有我"])
    }

    func testLastAssistantSeq() {
        let records = [
            record(0, .userMessage(text("问", role: .user)), .append),
            record(1, .assistantMessage(text("答", role: .assistant), usage: nil, interrupted: false), .append)
        ]
        XCTAssertEqual(SurfaceProjection.build(from: records).lastAssistantSeq, 1)
    }
}

extension SurfaceProjectionTests {
    /// 替换节点占据原位置，不追加到队尾。
    func testReplaceKeepsPositionOfReplacedRange() {
        let records = [
            record(0, .userMessage(text("一", role: .user)), .append),
            record(1, .assistantMessage(text("二", role: .assistant), usage: nil, interrupted: false), .append),
            record(2, .userMessage(text("三", role: .user)), .append),
            record(3, .userMessage(text("摘要", role: .context)), .replace(startSeq: 0, endSeq: 1))
        ]
        let projection = SurfaceProjection.build(from: records)
        XCTAssertEqual(projection.messages.map(\.visibleText), ["摘要", "三"])
        // 摘要节点接管被替换区间的起点 seq（0），保证 messageSeqs 单调递增。
        XCTAssertEqual(projection.messageSeqs, [0, 2])
    }
}
