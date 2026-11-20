import XCTest
@testable import AgentKit

final class InterjectHintTests: XCTestCase {
    func testAppendsToExistingSystem() {
        let result = InterjectHint.system(base: "你是助理。")
        XCTAssertTrue(result.hasPrefix("你是助理。\n\n"))
        XCTAssertTrue(result.contains("插话"))
    }

    func testUsesHintAloneWhenNoSystem() {
        XCTAssertEqual(InterjectHint.system(base: nil), InterjectHint.instruction)
        XCTAssertEqual(InterjectHint.system(base: ""), InterjectHint.instruction)
    }

    /// 提示必须明确"保留仍然成立的部分"，否则模型容易从头重写。
    func testHintDiscouragesRepeating() {
        XCTAssertTrue(InterjectHint.instruction.contains("不要重复"))
        XCTAssertTrue(InterjectHint.instruction.contains("保留"))
    }

    func testUserTextIsMarked() {
        XCTAssertEqual(InterjectHint.userText("换个角度"), "【插话】换个角度")
    }
}
