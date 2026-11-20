import CoreKit
import Foundation
import XCTest
@testable import LLMKit

enum Fixture {
    static func data(_ name: String, _ ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") else {
            throw XCTSkip("缺少夹具 \(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }

    static func json(_ name: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data(name, "json"))
    }

    static func sse(_ name: String) throws -> Data {
        try data(name, "sse")
    }
}

/// 按固定字节数切片回放录制流，模拟真实网络分片。
struct FixtureTransport: StreamTransport {
    let data: Data
    var chunkSize: Int = 16

    func bytes(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            var index = data.startIndex
            while index < data.endIndex {
                let end = data.index(index, offsetBy: chunkSize, limitedBy: data.endIndex) ?? data.endIndex
                continuation.yield(data[index..<end])
                index = end
            }
            continuation.finish()
        }
    }
}

func collect(_ stream: AsyncThrowingStream<StreamChunk, Error>) async throws -> [StreamChunk] {
    var chunks: [StreamChunk] = []
    for try await chunk in stream {
        chunks.append(chunk)
    }
    return chunks
}

func assemble(_ chunks: [StreamChunk]) throws -> (blocks: [ContentBlock], usage: TokenUsage?, finish: FinishReason) {
    var assembler = BlockAssembler()
    for chunk in chunks {
        assembler.push(chunk)
    }
    return (try assembler.blocks(), assembler.usage, assembler.finish)
}
