import CoreKit
import Foundation
import XCTest
@testable import LLMKit

final class ServerToolTests: XCTestCase {
    private var options: GenerateOptions {
        GenerateOptions(
            provider: "deepseek",
            model: "deepseek-flash",
            messages: [Message(role: .user, blocks: [.text("DeepSeek V4 有什么新的")], source: .user)],
            serverTools: [
                .init(wireType: "deepseek_web_search"),
                .init(wireType: "deepseek_read_url")
            ]
        )
    }

    // MARK: - 请求

    func testDeclaresServerTools() throws {
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(options)
        let tools = built.objectValue?["tools"]?.arrayValue ?? []
        XCTAssertEqual(tools.count, 2)
        XCTAssertEqual(tools[0].objectValue?["type"], .string("deepseek_web_search"))
        XCTAssertEqual(tools[0].objectValue?["name"], .string("deepseek_web_search"))
        XCTAssertEqual(tools[1].objectValue?["type"], .string("deepseek_read_url"))
    }

    /// 没允许联网时不声明工具——这是"关闭联网"的唯一正确做法
    /// （`tool_choice: none` 会连 URL 阅读一起关掉）。
    func testNoToolsWhenNotRequested() {
        var plain = options
        plain.serverTools = []
        let built = AnthropicRequestBuilder(profile: .anthropic()).body(plain)
        XCTAssertNil(built.objectValue?["tools"])
    }

    // MARK: - 回传

    /// 厂商私有块必须原样拼回请求，包括 signature。
    func testProviderBlocksAreReplayedVerbatim() throws {
        let payload = JSONValue.object([
            "type": .string("web_fetch_tool_result"),
            "tool_use_id": .string("srvtoolu_1"),
            "signature": .string("ENCRYPTED-PAGE"),
            "kind": .string("read_link")
        ])
        var replay = options
        replay.messages = [
            Message(role: .user, blocks: [.text("读一下 example.com")], source: .user),
            Message(
                role: .assistant,
                blocks: [
                    .providerBlock(ProviderBlock(type: "web_fetch_tool_result", payload: payload)),
                    .text("这个域名是保留给文档示例用的。")
                ],
                source: .model(provider: "deepseek", model: "deepseek-flash", meta: nil)
            ),
            Message(role: .user, blocks: [.text("引用第一句")], source: .user)
        ]

        let built = AnthropicRequestBuilder(profile: .anthropic()).body(replay)
        let messages = built.objectValue?["messages"]?.arrayValue ?? []
        let assistant = try XCTUnwrap(messages.first { $0.objectValue?["role"] == .string("assistant") })
        let blocks = try XCTUnwrap(assistant.objectValue?["content"]?.arrayValue)

        let replayed = try XCTUnwrap(blocks.first { $0.objectValue?["type"] == .string("web_fetch_tool_result") })
        XCTAssertEqual(replayed.objectValue?["signature"], .string("ENCRYPTED-PAGE"))
        XCTAssertEqual(replayed.objectValue?["tool_use_id"], .string("srvtoolu_1"))
    }

    // MARK: - 流解析

    func testParsesServerToolBlocksAndCitations() throws {
        let sse = """
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"server_tool_use","id":"srvtoolu_s_1","name":"deepseek_web_search","input":{"action":"search","queries":["DeepSeek V4"]},"kind":"search"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"web_search_tool_result","tool_use_id":"srvtoolu_s_1","content":[{"type":"web_search_result","title":"标题","url":"https://a.test/1"}],"kind":"search"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: content_block_start
        data: {"type":"content_block_start","index":2,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"V4 加了工具调用。"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":2,"delta":{"type":"citations_delta","citation":{"type":"web_search_result_location","url":"https://a.test/1","title":"标题"}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":2}

        """
        var parser = AnthropicStreamParser()
        var chunks = parser.feed(Data(sse.utf8))
        chunks += parser.finish()

        var assembler = BlockAssembler()
        for chunk in chunks { assembler.push(chunk) }
        let blocks = try assembler.blocks()

        XCTAssertEqual(blocks.count, 4, "工具调用 + 搜索结果 + 正文 + 引用")

        guard case let .providerBlock(call) = blocks[0] else { return XCTFail("第一个块应是工具调用") }
        XCTAssertEqual(call.type, "server_tool_use")
        XCTAssertEqual(call.payload.objectValue?["kind"], .string("search"))

        guard case let .providerBlock(result) = blocks[1] else { return XCTFail("第二个块应是搜索结果") }
        XCTAssertEqual(result.type, "web_search_tool_result")

        XCTAssertEqual(blocks[2], .text("V4 加了工具调用。"))
        guard case .citation = blocks[3] else { return XCTFail("最后一个块应是引用") }
    }

    /// 引用作为独立块产出，UI 才能单独渲染来源卡。
    func testCitationBecomesItsOwnBlock() throws {
        let sse = """
        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"答案"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"citations_delta","citation":{"url":"https://b.test/2","title":"来源"}}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        """
        var parser = AnthropicStreamParser()
        var chunks = parser.feed(Data(sse.utf8))
        chunks += parser.finish()

        var assembler = BlockAssembler()
        for chunk in chunks { assembler.push(chunk) }
        let blocks = try assembler.blocks()

        let citations = blocks.compactMap { block -> Citation? in
            if case let .citation(value) = block { value } else { nil }
        }
        XCTAssertEqual(citations.count, 1)
        XCTAssertEqual(citations.first?.url.absoluteString, "https://b.test/2")
        XCTAssertEqual(citations.first?.title, "来源")
    }
}

final class ProviderBlockTests: XCTestCase {
    func testRoundTripsThroughCodable() throws {
        let block = ContentBlock.providerBlock(ProviderBlock(
            type: "web_fetch_tool_result",
            payload: .object(["signature": .string("abc")])
        ))
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ContentBlock.self, from: data)
        XCTAssertEqual(decoded, block)
    }

    func testContributesNoVisibleText() {
        let block = ContentBlock.providerBlock(ProviderBlock(type: "x", payload: .null))
        XCTAssertEqual(block.plainText, "")
    }
}
