import CoreKit
import Foundation
import XCTest
@testable import LLMKit

private struct StubAdapter: LlmAdapter {
    let profile: ProviderProfile
    var chunks: [StreamChunk] = [.textDelta(index: 0, text: "ok"), .finish(.stop, meta: nil)]

    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            for chunk in chunks {
                continuation.yield(chunk)
            }
            continuation.finish()
        }
    }
}

private func profile(_ id: String, name: String? = nil) -> ProviderProfile {
    .openAICompatible(id: id, name: name ?? id, baseURL: "https://\(id).test/v1")
}

final class LlmRuntimeTests: XCTestCase {
    private var options: GenerateOptions {
        GenerateOptions(
            provider: "a",
            model: "m",
            messages: [Message(role: .user, blocks: [.text("hi")], source: .user)]
        )
    }

    func testRoutesToRegisteredAdapter() async throws {
        let runtime = LlmRuntime()
        _ = try await runtime.register(providers: ["a"], adapter: StubAdapter(profile: profile("a")))

        let chunks = try await collect(await runtime.stream(options))
        XCTAssertEqual(try assemble(chunks).blocks, [.text("ok")])
    }

    func testUnknownProviderYieldsNoAdapterFailure() async throws {
        let runtime = LlmRuntime()
        let chunks = try await collect(await runtime.stream(options))
        guard case let .finish(.error(failure), _) = chunks.last else {
            return XCTFail("期望失败结束，实际 \(String(describing: chunks.last))")
        }
        XCTAssertEqual(failure.code, .noAdapter)
    }

    func testDuplicateProviderRejectedWithoutMutation() async throws {
        let runtime = LlmRuntime()
        _ = try await runtime.register(providers: ["a"], adapter: StubAdapter(profile: profile("a")))

        do {
            _ = try await runtime.register(providers: ["a"], adapter: StubAdapter(profile: profile("a2")))
            XCTFail("应当拒绝重复路由")
        } catch let error as LlmRuntime.RegistrationError {
            XCTAssertEqual(error, .duplicateProvider("a"))
        }

        // 原路由仍然可用
        let name = await runtime.adapter(for: "a")?.profile.name
        XCTAssertEqual(name, "a")
    }

    /// 替换是原子的：替换后旧名字不再可达，新名字可达。
    func testReplaceMovesRoutes() async throws {
        let runtime = LlmRuntime()
        let registration = try await runtime.register(
            providers: ["a"],
            adapter: StubAdapter(profile: profile("a"))
        )

        try await registration.replace(providers: ["b"])

        let old = await runtime.adapter(for: "a")
        let new = await runtime.adapter(for: "b")
        XCTAssertNil(old)
        XCTAssertNotNil(new)
    }

    func testReplaceRejectsConflictWithOtherRegistration() async throws {
        let runtime = LlmRuntime()
        _ = try await runtime.register(providers: ["a"], adapter: StubAdapter(profile: profile("a")))
        let second = try await runtime.register(providers: ["b"], adapter: StubAdapter(profile: profile("b")))

        do {
            try await second.replace(providers: ["a"])
            XCTFail("应当拒绝抢占已被占用的路由")
        } catch let error as LlmRuntime.RegistrationError {
            XCTAssertEqual(error, .duplicateProvider("a"))
        }

        // 第二个注册保持原状
        let stillB = await runtime.adapter(for: "b")
        XCTAssertNotNil(stillB)
    }

    func testDisposeRemovesRoutes() async throws {
        let runtime = LlmRuntime()
        let registration = try await runtime.register(
            providers: ["a", "a2"],
            adapter: StubAdapter(profile: profile("a"))
        )
        await registration.dispose()

        let a = await runtime.adapter(for: "a")
        let list = await runtime.providers()
        XCTAssertNil(a)
        XCTAssertTrue(list.isEmpty)
    }

    func testMultipleProvidersShareOneAdapter() async throws {
        let runtime = LlmRuntime()
        let adapter = StubAdapter(profile: profile("shared", name: "共享"))
        _ = try await runtime.register(providers: ["a", "a2", "a3"], adapter: adapter)

        let list = await runtime.providers()
        XCTAssertEqual(list.map(\.provider), ["a", "a2", "a3"])
        XCTAssertEqual(Set(list.map(\.name)), ["共享"])
    }
}
