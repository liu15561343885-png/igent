import XCTest
@testable import CoreKit

final class BlockAssemblerTests: XCTestCase {
    func testTextDeltasOnly() throws {
        var assembler = BlockAssembler()
        assembler.push(.textDelta(index: 0, text: "he"))
        assembler.push(.textDelta(index: 0, text: "llo"))
        XCTAssertEqual(try assembler.blocks(), [.text("hello")])
    }

    func testBlockStartAndEnd() throws {
        var assembler = BlockAssembler()
        assembler.push(.blockStart(index: 0, type: .text))
        assembler.push(.textDelta(index: 0, text: "hi"))
        assembler.push(.blockEnd(index: 0, block: .text("hi")))
        XCTAssertEqual(try assembler.blocks(), [.text("hi")])
    }

    /// 思维链与正文交错流出，顺序按块首次出现确定。
    func testInterleavedReasoningAndText() throws {
        var assembler = BlockAssembler()
        assembler.push(.reasoningDelta(index: 0, text: "想一想"))
        assembler.push(.textDelta(index: 1, text: "答案"))
        assembler.push(.reasoningDelta(index: 0, text: "…"))
        XCTAssertEqual(try assembler.blocks(), [.reasoning("想一想…"), .text("答案")])
    }

    func testDeltaAfterBlockEndIsIgnored() throws {
        var assembler = BlockAssembler()
        assembler.push(.blockStart(index: 0, type: .text))
        assembler.push(.blockEnd(index: 0, block: .text("done")))
        assembler.push(.textDelta(index: 0, text: "late"))
        XCTAssertEqual(try assembler.blocks(), [.text("done")])
    }

    func testUsageAndFinishCaptured() throws {
        var assembler = BlockAssembler()
        assembler.push(.textDelta(index: 0, text: "x"))
        assembler.push(.usage(TokenUsage(uncachedInputTokens: 10, outputTokens: 5)))
        assembler.push(.finish(.stop, meta: ProviderMeta(responseId: "resp_1")))
        XCTAssertEqual(try assembler.blocks(), [.text("x")])
        XCTAssertEqual(assembler.usage?.outputTokens, 5)
        XCTAssertEqual(assembler.finish, .stop)
        XCTAssertEqual(assembler.meta?.responseId, "resp_1")
    }

    func testFinishDefaultsToStopWhenAbsent() throws {
        var assembler = BlockAssembler()
        assembler.push(.textDelta(index: 0, text: "x"))
        XCTAssertEqual(assembler.finish, .stop)
    }

    /// 中断：只有空白的未闭合块不算产出。
    func testInterruptedDropsWhitespaceOnly() {
        var assembler = BlockAssembler()
        assembler.push(.textDelta(index: 0, text: "   \n"))
        assembler.push(.reasoningDelta(index: 1, text: "\n\n"))
        XCTAssertEqual(assembler.interruptedBlocks(), [])
    }

    func testInterruptedKeepsSubstantiveText() {
        var assembler = BlockAssembler()
        assembler.push(.textDelta(index: 0, text: "半句话"))
        assembler.push(.textDelta(index: 1, text: "   "))
        XCTAssertEqual(assembler.interruptedBlocks(), [.text("半句话")])
    }

    func testInterruptedKeepsClosedImageBlock() {
        var assembler = BlockAssembler()
        let image = ImageAttachmentRef(
            id: "sha256-abc",
            mediaType: "image/png",
            byteCount: 1024,
            width: 512,
            height: 512
        )
        assembler.push(.blockStart(index: 0, type: .reasoning))
        assembler.push(.blockEnd(index: 0, block: .image(image)))
        XCTAssertEqual(assembler.interruptedBlocks(), [.image(image)])
    }

    /// 未知类型既没闭合也没有可推导内容 → 抛错，不静默丢块。
    func testUnclosedUnknownBlockThrows() {
        var assembler = BlockAssembler()
        assembler.push(.blockStart(index: 0, type: .context))
        XCTAssertThrowsError(try assembler.blocks()) { error in
            XCTAssertEqual(
                error as? AssemblyError,
                .unclosedUnknownBlock(index: 0, type: .context)
            )
        }
    }

    /// 空白正文块不产生空块，避免历史里出现空消息。
    func testEmptyTextBlockOmitted() throws {
        var assembler = BlockAssembler()
        assembler.push(.blockStart(index: 0, type: .text))
        XCTAssertEqual(try assembler.blocks(), [])
    }
}
