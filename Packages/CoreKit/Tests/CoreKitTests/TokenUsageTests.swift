import XCTest
@testable import CoreKit

final class TokenUsageTests: XCTestCase {
    func testSumAddsMandatoryFields() {
        let total = TokenUsage(uncachedInputTokens: 10, outputTokens: 5)
            + TokenUsage(uncachedInputTokens: 3, outputTokens: 1)
        XCTAssertEqual(total.uncachedInputTokens, 13)
        XCTAssertEqual(total.outputTokens, 6)
    }

    /// 一笔报了缓存、一笔没报：按 0 计，不能把总额毁成未知。
    func testCacheAccumulatesWhenOnlyOneSideReports() {
        let total = TokenUsage(uncachedInputTokens: 1, outputTokens: 1)
            + TokenUsage(uncachedInputTokens: 1, outputTokens: 1, cacheReadTokens: 7)
        XCTAssertEqual(total.cacheReadTokens, 7)
    }

    func testCacheStaysUnknownWhenBothMissing() {
        let total = TokenUsage(uncachedInputTokens: 1, outputTokens: 1)
            + TokenUsage(uncachedInputTokens: 1, outputTokens: 1)
        XCTAssertNil(total.cacheReadTokens)
    }

    /// totalTokens 是厂商给的总数，缺一笔就无法确定，保持未知。
    func testTotalTokensStaysUnknownWhenEitherMissing() {
        let total = TokenUsage(uncachedInputTokens: 1, outputTokens: 1, totalTokens: 2)
            + TokenUsage(uncachedInputTokens: 1, outputTokens: 1)
        XCTAssertNil(total.totalTokens)
    }

    func testBilledInputIsDisjointSum() {
        let usage = TokenUsage(
            uncachedInputTokens: 10,
            outputTokens: 2,
            cacheReadTokens: 5,
            cacheWriteTokens: 3
        )
        XCTAssertEqual(usage.billedInputTokens, 18)
    }
}
