import CoreKit
import Foundation

/// 厂商路由表。
///
/// 为什么需要一个"表"而不是直接持有适配器：
/// - 设置页改了密钥或地址，要能换掉某条路由，而**不影响在途请求**；
/// - 同一个适配器实例可以同时服务多个厂商路由（OpenAI 兼容族就是这样）；
/// - 路由不存在时要返回结构化的 `noAdapter` 失败，而不是崩溃或静默。
public actor LlmRuntime {
    public enum RegistrationError: Error, Equatable {
        case duplicateProvider(String)
        case emptyProviderName
    }

    private struct Entry {
        let adapter: any LlmAdapter
        var providers: [String]
    }

    private var entries: [UUID: Entry] = [:]
    private var routes: [String: UUID] = [:]

    public init() {}

    /// 注册一组厂商路由。任何一条与既有路由冲突则整体失败，不留下半截状态。
    public func register(providers: [String], adapter: any LlmAdapter) throws -> Registration {
        let candidates = try validate(providers, excluding: nil)
        let id = UUID()
        entries[id] = Entry(adapter: adapter, providers: candidates)
        for provider in candidates {
            routes[provider] = id
        }
        return Registration(runtime: self, id: id)
    }

    /// 原子替换某次注册的全部路由。候选集先整体校验，再一次性生效。
    public func replace(registration id: UUID, with providers: [String]) throws {
        guard var entry = entries[id] else { return }
        let candidates = try validate(providers, excluding: id)

        for provider in entry.providers {
            routes[provider] = nil
        }
        entry.providers = candidates
        entries[id] = entry
        for provider in candidates {
            routes[provider] = id
        }
    }

    public func dispose(registration id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        for provider in entry.providers {
            routes[provider] = nil
        }
    }

    public func adapter(for provider: String) -> (any LlmAdapter)? {
        guard let id = routes[provider] else { return nil }
        return entries[id]?.adapter
    }

    /// 已注册路由，按名字排序，供设置页展示。
    public func providers() -> [(provider: String, name: String)] {
        routes.keys.sorted().map { provider in
            let name = routes[provider].flatMap { entries[$0]?.adapter.profile.name } ?? provider
            return (provider, name)
        }
    }

    public func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let adapter = await self.adapter(for: options.provider) else {
                    continuation.yield(.finish(
                        .error(LlmFailure(
                            message: "未注册的厂商：\(options.provider)",
                            code: .noAdapter
                        )),
                        meta: nil
                    ))
                    continuation.finish()
                    return
                }
                do {
                    for try await chunk in adapter.stream(options) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.yield(.finish(
                        .aborted(LlmFailure(message: "已取消", code: .cancelled)),
                        meta: nil
                    ))
                    continuation.finish()
                } catch let failure as LlmFailure {
                    continuation.yield(.finish(.error(failure), meta: nil))
                    continuation.finish()
                } catch {
                    continuation.yield(.finish(
                        .error(LlmFailure(message: error.localizedDescription, code: .network)),
                        meta: nil
                    ))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func validate(_ providers: [String], excluding id: UUID?) throws -> [String] {
        var seen = Set<String>()
        for provider in providers {
            guard !provider.isEmpty else { throw RegistrationError.emptyProviderName }
            guard seen.insert(provider).inserted else {
                throw RegistrationError.duplicateProvider(provider)
            }
            if let owner = routes[provider], owner != id {
                throw RegistrationError.duplicateProvider(provider)
            }
        }
        return providers
    }
}

/// 一次注册的句柄。可以先整体校验再替换，保证路由不出现空窗。
public struct Registration: Sendable {
    private let runtime: LlmRuntime
    private let id: UUID

    init(runtime: LlmRuntime, id: UUID) {
        self.runtime = runtime
        self.id = id
    }

    public func replace(providers: [String]) async throws {
        try await runtime.replace(registration: id, with: providers)
    }

    public func dispose() async {
        await runtime.dispose(registration: id)
    }
}
