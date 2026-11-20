import XCTest
@testable import CoreKit

final class SSEDecoderTests: XCTestCase {
    private func events(from text: String) -> [SSEEvent] {
        var decoder = SSEDecoder()
        var result = decoder.feed(Array(text.utf8))
        result += decoder.finish()
        return result
    }

    func testSingleFrame() {
        XCTAssertEqual(
            events(from: "data: hello\n\n"),
            [SSEEvent(data: "hello")]
        )
    }

    func testMultipleFramesInOneFeed() {
        XCTAssertEqual(
            events(from: "data: a\n\ndata: b\n\n"),
            [SSEEvent(data: "a"), SSEEvent(data: "b")]
        )
    }

    func testMultilineDataJoinedWithNewline() {
        XCTAssertEqual(
            events(from: "data: line1\ndata: line2\n\n"),
            [SSEEvent(data: "line1\nline2")]
        )
    }

    func testCRLFTerminator() {
        XCTAssertEqual(
            events(from: "data: x\r\n\r\n"),
            [SSEEvent(data: "x")]
        )
    }

    func testCommentLinesIgnored() {
        XCTAssertEqual(events(from: ": keep-alive\n\n"), [])
    }

    func testEventNameField() {
        XCTAssertEqual(
            events(from: "event: content_block_delta\ndata: {}\n\n"),
            [SSEEvent(event: "content_block_delta", data: "{}")]
        )
    }

    func testDoneSentinelIsJustData() {
        XCTAssertEqual(
            events(from: "data: [DONE]\n\n"),
            [SSEEvent(data: "[DONE]")]
        )
    }

    func testFlushWithoutTrailingBlankLine() {
        var decoder = SSEDecoder()
        XCTAssertEqual(decoder.feed(Array("data: tail".utf8)), [])
        XCTAssertEqual(decoder.finish(), [SSEEvent(data: "tail")])
    }

    func testEmptyDataFieldProducesEmptyEvent() {
        XCTAssertEqual(events(from: "data:\n\n"), [SSEEvent(data: "")])
    }

    /// 核心用例：把一帧含中文的字节逐个喂入，任何时刻都不得解出半个字符。
    func testByteByByteUTF8() {
        let payload = "data: 中文流式\n\n"
        var decoder = SSEDecoder()
        var collected: [SSEEvent] = []
        for byte in Array(payload.utf8) {
            collected += decoder.feed([byte])
        }
        collected += decoder.finish()
        XCTAssertEqual(collected, [SSEEvent(data: "中文流式")])
    }

    /// 两个帧被任意切分：切点落在 data 中间、行尾、空行中间都要正确。
    func testArbitraryChunkBoundaries() {
        let payload = "data: 一\n\ndata: 二\n\n"
        let bytes = Array(payload.utf8)
        for split in 1..<bytes.count {
            var decoder = SSEDecoder()
            var collected = decoder.feed(bytes[0..<split])
            collected += decoder.feed(bytes[split...])
            collected += decoder.finish()
            XCTAssertEqual(
                collected,
                [SSEEvent(data: "一"), SSEEvent(data: "二")],
                "split at \(split) produced \(collected)"
            )
        }
    }

    func testEventWithoutDataIsDropped() {
        XCTAssertEqual(events(from: "event: ping\n\n"), [])
    }
}
