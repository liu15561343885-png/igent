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
        /// 模型上下文窗口，用于自动压缩的阈值判断。
        public var contextWindow: Int
        /// 本轮允许模型使用的服务端工具。非空表示"让模型自己决定要不要联网"。
        public var serverTools: [ServerToolRequest]

        public init(
            provider: String,
            model: String,
            system: String? = nil,
            temperature: Double? = nil,
            maxTokens: Int? = nil,
            contextWindow: Int = 128_000,
            serverTools: [ServerToolRequest] = []
        ) {
            self.provider = provider
            self.model = model
            self.system = system
            self.temperature = temperature
            self.maxTokens = maxTokens
            self.contextWindow = contextWindow
            self.serverTools = serverTools
        }
    }

    private let store: SessionStore
    private let runtime: LlmRuntime
    private let compactor: CompactionService
    private var activeTask: Task<Void, Never>?

    /// 自动压缩策略。设为 nil 可关闭（手动压缩仍然可用）。
    private(set) var policy: CompactionPolicy?

    public func setPolicy(_ policy: CompactionPolicy?) {
        self.policy = policy
    }

    public init(store: SessionStore, runtime: LlmRuntime, policy: CompactionPolicy? = .default) {
        self.store = store
        self.runtime = runtime
        self.compactor = CompactionService(store: store, runtime: runtime)
        self.policy = policy
    }

    public var isRunning: Bool { activeTask != nil }

    /// 发起一个回合，返回实时更新流。
    ///
    /// 传 blocks 而不是字符串：图片输入是"文字 + 图片"的组合消息，
    /// 用字符串签名会在加图片时被迫改一遍所有调用点。
    public func send(
        _ blocks: [ContentBlock],
        in sessionID: SessionID,
        configuration: Configuration
    ) -> AsyncStream<TurnUpdate> {
        AsyncStream { continuation in
            let task = Task {
                await self.run(
                    blocks,
                    sessionID: sessionID,
                    configuration: configuration,
                    continuation: continuation
                )
            }
            activeTask = task
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func send(
        _ text: String,
        in sessionID: SessionID,
        configuration: Configuration
    ) -> AsyncStream<TurnUpdate> {
        send([.text(text)], in: sessionID, configuration: configuration)
    }

    public func cancel() {
        activeTask?.cancel()
    }

    // MARK: - 执行

    private func run(
        _ blocks: [ContentBlock],
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
            var projection = try await store.projection(for: sessionID)

            // ① 开回合前先看压力：超过阈值就把较早的历史压掉再发，
            //    否则这一轮很可能直接撞上上下文上限。
            projection = await autoCompactIfNeeded(sessionID: sessionID, projection: projection, configuration: configuration)

            turn = projection.lastTurn + 1
            step = 1

            try await store.append(.turnStart(turn: turn), to: sessionID)
            let userMessage = Message(role: .user, blocks: blocks, source: .user)
            try await store.append(.userMessage(userMessage), to: sessionID, surfaceOp: .append)
            try await store.append(.stepStart(turn: turn, step: step), to: sessionID)
            continuation.yield(.started(turn: turn))

            var history = projection.messages + [userMessage]
            var recoveredFromOverflow = false

            while true {
                assembler = BlockAssembler()
                usage = nil
                meta = nil

                let options = GenerateOptions(
                    provider: configuration.provider,
                    model: configuration.model,
                    messages: history,
                    system: configuration.system,
                    temperature: configuration.temperature,
                    maxTokens: configuration.maxTokens,
                    serverTools: configuration.serverTools
                )

                do {
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

                // ② 厂商报上下文溢出：估算低估了，压缩一次再试。
                //    只重试一次——若压完还溢出，说明单条消息本身就超限，再试也没用。
                if case let .error(failure) = finish,
                   failure.code == .contextWindowExceeded,
                   policy?.overflowRecovery == true,
                   !recoveredFromOverflow {
                    recoveredFromOverflow = true
                    let compacted = await compactNow(sessionID: sessionID, configuration: configuration)
                    if compacted {
                        history = (try? await store.projection(for: sessionID).messages) ?? history
                        continue
                    }
                }
                break
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

    /// 估算当前请求的输入量，超过阈值就先压缩。
    private func autoCompactIfNeeded(
        sessionID: SessionID,
        projection: SurfaceProjection,
        configuration: Configuration
    ) async -> SurfaceProjection {
        guard let policy else { return projection }

        let inputTokens = TokenEstimator.estimate(projection.messages)
            + TokenEstimator.estimate(configuration.system)
        guard policy.shouldCompact(
            inputTokens: inputTokens,
            messageCount: projection.messages.count,
            contextWindow: configuration.contextWindow,
            reservedOutput: configuration.maxTokens ?? 4_096
        ) else {
            return projection
        }

        let compacted = await compactNow(sessionID: sessionID, configuration: configuration)
        guard compacted else { return projection }
        return (try? await store.projection(for: sessionID)) ?? projection
    }

    @discardableResult
    private func compactNow(sessionID: SessionID, configuration: Configuration) async -> Bool {
        guard let policy else { return false }
        let request = CompactionService.Request(
            sessionID: sessionID,
            provider: configuration.provider,
            model: configuration.model,
            keepRecentMessages: nil,
            policy: policy,
            contextWindow: configuration.contextWindow,
            reservedOutput: configuration.maxTokens ?? 4_096
        )
        return (try? await compactor.compact(request)) != nil
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
