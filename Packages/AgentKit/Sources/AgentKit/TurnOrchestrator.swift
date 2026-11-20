import CoreKit
import Foundation
import LLMKit
import StorageKit

/// 编排器对外的实时事件。
public enum TurnUpdate: Sendable {
    /// 回合已开启，用户消息已落库。
    case started(turn: Int)
    /// 一块流式数据，UI 直接消费。
    case chunk(StreamChunk)
    /// 回合结束。无论成功、失败还是被取消都会来一次。
    case finished(TurnResult)
}

public struct TurnResult: Sendable {
    public var turn: Int
    public var projection: SurfaceProjection
    public var finish: FinishReason
    public var usage: TokenUsage?
    public var interrupted: Bool
}

/// 一次回合的执行者。
///
/// 这是"无工具 agent"的全部循环：开回合 → 落用户消息 → 调模型 → 流式转发 →
/// 落助手消息 → 关回合。没有步骤表、没有工具分派、没有审批。
///
/// 取消语义：中断时把已产出的可见前缀落成 `interrupted: true` 的助手消息；
/// 一个字都没出则落 `assistant/attempt`，不留空消息。
public actor TurnOrchestrator {
    public struct Configuration: Sendable, Equatable {
        public var provider: String
        public var model: String
        public var system: String?
        public var temperature: Double?
        public var maxTokens: Int?

        public init(
            provider: String,
            model: String,
            system: String? = nil,
            temperature: Double? = nil,
            maxTokens: Int? = nil
        ) {
            self.provider = provider
            self.model = model
            self.system = system
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
    }

    private let store: SessionStore
    private let runtime: LlmRuntime
    private var activeTask: Task<Void, Never>?

    public init(store: SessionStore, runtime: LlmRuntime) {
        self.store = store
        self.runtime = runtime
    }

    public var isRunning: Bool { activeTask != nil }

    /// 发起一个回合，返回实时更新流。
    public func send(
        _ text: String,
        in sessionID: SessionID,
        configuration: Configuration
    ) -> AsyncStream<TurnUpdate> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(
                    text,
                    sessionID: sessionID,
                    configuration: configuration,
                    continuation: continuation
                )
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func cancel() {
        activeTask?.cancel()
    }

    // MARK: - 执行

    private func run(
        _ text: String,
        sessionID: SessionID,
        configuration: Configuration,
        continuation: AsyncStream<TurnUpdate>.Continuation
    ) async {
        defer {
            activeTask = nil
            continuation.finish()
        }

        var assembler = BlockAssembler()
        var usage: TokenUsage?
        var finish: FinishReason = .stop
        var meta: ProviderMeta?
        var turn = 0
        var step = 0

        do {
            let projection = try await store.projection(for: sessionID)
            turn = projection.lastTurn + 1
            step = 1

            try await store.append(.turnStart(turn: turn), to: sessionID)
            let userMessage = Message(role: .user, blocks: [.text(text)], source: .user)
            try await store.append(.userMessage(userMessage), to: sessionID, surfaceOp: .append)
            try await store.append(.stepStart(turn: turn, step: step), to: sessionID)
            continuation.yield(.started(turn: turn))

            let options = GenerateOptions(
                provider: configuration.provider,
                model: configuration.model,
                messages: projection.messages + [userMessage],
                system: configuration.system,
                temperature: configuration.temperature,
                maxTokens: configuration.maxTokens
            )

            for try await chunk in await runtime.stream(options) {
                if Task.isCancelled { break }
                assembler.push(chunk)
                if case let .usage(value) = chunk { usage = value }
                if case let .finish(reason, providerMeta) = chunk {
                    finish = reason
                    meta = providerMeta
                }
                continuation.yield(.chunk(chunk))
            }
        } catch {
            finish = .error(Self.failure(from: error))
        }

        if Task.isCancelled, !finish.isFailure {
            finish = .aborted(LlmFailure(message: "已取消", code: .cancelled))
        }

        // 落库：中断只保留有实质内容的前缀。
        do {
            let interrupted = finish.isFailure
            let blocks = interrupted ? assembler.interruptedBlocks() : (try? assembler.blocks()) ?? []

            if blocks.isEmpty {
                if case let .error(failure) = finish {
                    try await store.append(
                        .assistantAttempt(turn: turn, step: step, failure: failure),
                        to: sessionID
                    )
                } else if case let .aborted(failure) = finish {
                    try await store.append(
                        .assistantAttempt(turn: turn, step: step, failure: failure),
                        to: sessionID
                    )
                }
            } else {
                let message = Message(
                    role: .assistant,
                    blocks: blocks,
                    source: .model(
                        provider: configuration.provider,
                        model: configuration.model,
                        meta: meta
                    )
                )
                try await store.append(
                    .assistantMessage(message, usage: usage, interrupted: interrupted),
                    to: sessionID,
                    surfaceOp: .append
                )
                if let usage {
                    try await store.logUsage(
                        sessionID: sessionID,
                        turn: turn,
                        step: step,
                        provider: configuration.provider,
                        model: configuration.model,
                        purpose: nil,
                        usage: usage
                    )
                }
            }

            if step > 0 {
                try await store.append(.stepEnd(turn: turn, step: step), to: sessionID)
            }
            if turn > 0 {
                try await store.append(
                    .turnEnd(turn: turn, reason: Self.reason(for: finish, interrupted: Task.isCancelled)),
                    to: sessionID
                )
            }

            let projection = try await store.projection(for: sessionID)
            continuation.yield(.finished(TurnResult(
                turn: turn,
                projection: projection,
                finish: finish,
                usage: usage,
                interrupted: finish.isFailure
            )))
        } catch {
            // 落库失败时不再尝试写日志，直接把错误交给上层。
            continuation.yield(.finished(TurnResult(
                turn: turn,
                projection: SurfaceProjection(),
                finish: .error(Self.failure(from: error)),
                usage: usage,
                interrupted: true
            )))
        }
    }

    private static func failure(from error: Error) -> LlmFailure {
        if let failure = error as? LlmFailure { return failure }
        if error is CancellationError {
            return LlmFailure(message: "已取消", code: .cancelled)
        }
        return LlmFailure(message: error.localizedDescription, code: .network)
    }

    private static func reason(for finish: FinishReason, interrupted: Bool) -> TurnEndReason {
        if interrupted { return .cancelled }
        switch finish {
        case .error, .aborted: return .failed
        case .stop, .maxTokens, .contentFilter: return .completed
        }
    }
}
