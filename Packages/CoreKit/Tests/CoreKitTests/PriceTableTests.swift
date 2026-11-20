import Foundation
import XCTest
@testable import CoreKit

final class PriceTableTests: XCTestCase {
    func testMatchesLongestKeyFirst() {
        // gpt-4o-mini 不能被 gpt-4o 抢先匹配
        XCTAssertEqual(PriceTable.price(for: "gpt-4o-mini-2024-07-18")?.key, "gpt-4o-mini")
        XCTAssertEqual(PriceTable.price(for: "gpt-4o")?.key, "gpt-4o")
    }

    func testUnknownModelHasNoPrice() {
        let estimate = PriceTable.estimate(
            TokenUsage(uncachedInputTokens: 1000, outputTokens: 500),
            model: "some-local-model"
        )
        XCTAssertNil(estimate.amountUSD)
        XCTAssertFalse(estimate.isAvailable)
    }

    func testComputesCostFromDisjointCounts() {
        let usage = TokenUsage(
            uncachedInputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000
        )
        let estimate = PriceTable.estimate(usage, model: "gpt-4o-mini")
        // 0.15 + 0.60 + 0.075
        XCTAssertEqual(estimate.amountUSD ?? 0, 0.825, accuracy: 0.0001)
    }

    func testCacheReadUsesCachePrice() {
        let withCache = TokenUsage(uncachedInputTokens: 0, outputTokens: 0, cacheReadTokens: 1_000_000)
        let estimate = PriceTable.estimate(withCache, model: "gpt-4o")
        XCTAssertEqual(estimate.amountUSD ?? 0, 1.25, accuracy: 0.0001)
    }

    func testZeroUsageCostsZero() {
        let estimate = PriceTable.estimate(
            TokenUsage(uncachedInputTokens: 0, outputTokens: 0),
            model: "deepseek-chat"
        )
        XCTAssertEqual(estimate.amountUSD, 0)
    }

    func testCaseInsensitiveMatching() {
        XCTAssertNotNil(PriceTable.price(for: "Claude-Sonnet-4-5"))
    }
}
