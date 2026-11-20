import CoreKit
import Foundation
import XCTest
@testable import LLMKit

/// 线程安全的请求捕获器，用来断言"最终发出去的报文长什么样"。
final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var value: URLRequest?

    var request: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ request: URLRequest) {
        lock.lock()
        value = request
        lock.unlock()
    }
}

struct CapturingTransport: StreamTransport {
    let capture: Capture

    func bytes(for request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        capture.set(request)
        return AsyncThrowingStream { $0.finish() }
    }
}

struct StubImageResolver: ImageResolver {
    var payloads: [String: ResolvedImage]
    var counter: Counter?

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func increment() { lock.lock(); value += 1; lock.unlock() }
    }

    func resolve(_ refs: [ImageAttachmentRef]) async -> [String: ResolvedImage] {
        counter?.increment()
        var result: [String: ResolvedImage] = [:]
        for ref in refs {
            if let payload = payloads[ref.id] { result[ref.id] = payload }
        }
        return result
    }
}

final class ImagePayloadTests: XCTestCase {
    private let reference = ImageAttachmentRef(
        id: "sha-1",
        mediaType: "image/jpeg",
        byteCount: 3,
        width: 64,
        height: 48
    )

    private var options: GenerateOptions {
        GenerateOptions(
            provider: "p",
            model: "m",
            messages: [
                Message(role: .user, blocks: [.text("这是什么"), .image(reference)], source: .user)
            ]
        )
    }

    private func payloadMap() -> [String: ResolvedImage] {
        [reference.id: ResolvedImage(mediaType: "image/jpeg", base64: "QUJD")]
    }

    private func body(of capture: Capture) throws -> JSONValue {
        let request = try XCTUnwrap(capture.request)
        let data = try XCTUnwrap(request.httpBody)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    // MARK: - 四族各自的图片字段

    func testOpenAIEmitsDataURL() async throws {
        let capture = Capture()
        let profile = ProviderProfile.openAICompatible(
            id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1",
            capabilities: Capabilities(vision: true)
        )
        let adapter = OpenAICompatibleAdapter(
            profile: profile, apiKey: "k",
            transport: CapturingTransport(capture: capture),
            imageResolver: StubImageResolver(payloads: payloadMap())
        )
        _ = try await collect(adapter.stream(options))

        let messages = try body(of: capture).objectValue?["messages"]?.arrayValue ?? []
        let parts = messages.last?.objectValue?["content"]?.arrayValue ?? []
        let imageURL = parts.first { $0.objectValue?["type"] == .string("image_url") }
        XCTAssertEqual(
            imageURL?.objectValue?["image_url"]?.objectValue?["url"],
            .string("data:image/jpeg;base64,QUJD")
        )
    }

    func testAnthropicEmitsBase64Source() async throws {
        let capture = Capture()
        let adapter = AnthropicAdapter(
            apiKey: "k",
            transport: CapturingTransport(capture: capture),
            imageResolver: StubImageResolver(payloads: payloadMap())
        )
        _ = try await collect(adapter.stream(options))

        let content = try body(of: capture).objectValue?["messages"]?.arrayValue?
            .last?.objectValue?["content"]?.arrayValue ?? []
        let image = content.first { $0.objectValue?["type"] == .string("image") }
        XCTAssertEqual(image?.objectValue?["source"]?.objectValue?["data"], .string("QUJD"))
        XCTAssertEqual(image?.objectValue?["source"]?.objectValue?["media_type"], .string("image/jpeg"))
    }

    func testGeminiEmitsInlineData() async throws {
        let capture = Capture()
        let adapter = GeminiAdapter(
            apiKey: "k",
            transport: CapturingTransport(capture: capture),
            imageResolver: StubImageResolver(payloads: payloadMap())
        )
        _ = try await collect(adapter.stream(options))

        let parts = try body(of: capture).objectValue?["contents"]?.arrayValue?
            .last?.objectValue?["parts"]?.arrayValue ?? []
        let inline = parts.first { $0.objectValue?["inlineData"] != nil }
        XCTAssertEqual(inline?.objectValue?["inlineData"]?.objectValue?["data"], .string("QUJD"))
        XCTAssertEqual(inline?.objectValue?["inlineData"]?.objectValue?["mimeType"], .string("image/jpeg"))
    }

    func testResponsesEmitsInputImage() async throws {
        let capture = Capture()
        let adapter = OpenAIResponsesAdapter(
            apiKey: "k",
            transport: CapturingTransport(capture: capture),
            imageResolver: StubImageResolver(payloads: payloadMap())
        )
        _ = try await collect(adapter.stream(options))

        let content = try body(of: capture).objectValue?["input"]?.arrayValue?
            .last?.objectValue?["content"]?.arrayValue ?? []
        let image = content.first { $0.objectValue?["type"] == .string("input_image") }
        XCTAssertEqual(image?.objectValue?["image_url"], .string("data:image/jpeg;base64,QUJD"))
    }

    // MARK: - 能力门控

    /// 不支持视觉的厂商：图片直接丢弃，不发出去让厂商报 400。
    func testImageDroppedWhenVisionUnsupported() async throws {
        let capture = Capture()
        let counter = StubImageResolver.Counter()
        let profile = ProviderProfile.openAICompatible(
            id: "text-only", name: "Text", baseURL: "https://x.test/v1",
            capabilities: Capabilities(vision: false)
        )
        let adapter = OpenAICompatibleAdapter(
            profile: profile, apiKey: "k",
            transport: CapturingTransport(capture: capture),
            imageResolver: StubImageResolver(payloads: payloadMap(), counter: counter)
        )
        _ = try await collect(adapter.stream(options))

        let messages = try body(of: capture).objectValue?["messages"]?.arrayValue ?? []
        let text = messages.last?.objectValue?["content"]
        XCTAssertEqual(text, .string("这是什么"), "只剩文字，图片被丢弃")
        XCTAssertEqual(counter.count, 0, "不支持视觉时不该去读盘解析图片")
    }

    /// 没有 resolver 时退化为纯文本，不能崩。
    func testMissingResolverDoesNotCrash() async throws {
        let capture = Capture()
        let profile = ProviderProfile.openAICompatible(
            id: "v", name: "V", baseURL: "https://x.test/v1",
            capabilities: Capabilities(vision: true)
        )
        let adapter = OpenAICompatibleAdapter(
            profile: profile, apiKey: "k",
            transport: CapturingTransport(capture: capture)
        )
        _ = try await collect(adapter.stream(options))
        let messages = try body(of: capture).objectValue?["messages"]?.arrayValue ?? []
        XCTAssertEqual(messages.last?.objectValue?["content"], .string("这是什么"))
    }

    /// 同一张图在一条请求里出现多次，只解析一次。
    func testDuplicateReferencesResolvedOnce() {
        var repeated = options
        repeated.messages.append(
            Message(role: .user, blocks: [.image(reference)], source: .user)
        )
        XCTAssertEqual(collectImageRefs(repeated).count, 1)
    }
}
