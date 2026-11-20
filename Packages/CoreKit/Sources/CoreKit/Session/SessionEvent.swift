import Foundation

public typealias SessionID = UUID

public enum TurnEndReason: String, Codable, Sendable, Equatable {
    case completed
    case cancelled
    case failed
}

/// 会话日志里的一条事件。只追加，不改写。
///
/// 消息类事件是"表面"（surface）事件，带 `SurfaceOp`；其余是过程事件，
/// 只用于回放与诊断，不进模型上下文。
public enum SessionEvent: Codable, Sendable, Equatable {
    case turnStart(turn: Int)
    case turnEnd(turn: Int, reason: TurnEndReason)
    case stepStart(turn: Int, step: Int)
    case stepEnd(turn: Int, step: Int)

    case systemMessage(Message)
    case userMessage(Message)
    case contextMessage(Message)
    case assistantMessage(Message, usage: TokenUsage?, interrupted: Bool)

    /// 一次没有留下任何内容的失败尝试。不产生可选消息，只留证据。
    case assistantAttempt(turn: Int, step: Int, failure: LlmFailure)

    case titleGenerated(String)
}

public extension SessionEvent {
    /// 该事件是否产生一条模型可见的消息。
    var surfaceMessage: Message? {
        switch self {
        case let .systemMessage(message),
             let .userMessage(message),
             let .contextMessage(message),
             let .assistantMessage(message, _, _):
            message
        default:
            nil
        }
    }

    /// 事件类型标签，用于入库与诊断。
    var kind: String {
        switch self {
        case .turnStart: "turn/start"
        case .turnEnd: "turn/end"
        case .stepStart: "step/start"
        case .stepEnd: "step/end"
        case .systemMessage: "system/message"
        case .userMessage: "user/message"
        case .contextMessage: "context/message"
        case .assistantMessage: "assistant/message"
        case .assistantAttempt: "assistant/attempt"
        case .titleGenerated: "title/generated"
        }
    }
}

/// 消息在表面上的操作。
///
/// `replace` 让"压缩""重生成""编辑重发"共用同一条机制：新节点覆盖一段旧区间，
/// 旧事件仍留在日志里，可回滚、可审计。
public enum SurfaceOp: Codable, Sendable, Equatable {
    case append
    case replace(startSeq: Int64, endSeq: Int64)
}

public struct SessionRecord: Codable, Sendable, Equatable {
    public var seq: Int64
    public var sessionID: SessionID
    public var time: Date
    public var event: SessionEvent
    public var surfaceOp: SurfaceOp?

    public init(
        seq: Int64,
        sessionID: SessionID,
        time: Date,
        event: SessionEvent,
        surfaceOp: SurfaceOp? = nil
    ) {
        self.seq = seq
        self.sessionID = sessionID
        self.time = time
        self.event = event
        self.surfaceOp = surfaceOp
    }
}

/// 会话元信息。
public struct SessionSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: SessionID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var provider: String?
    public var model: String?
    public var archived: Bool

    public init(
        id: SessionID,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        provider: String? = nil,
        model: String? = nil,
        archived: Bool = false
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.provider = provider
        self.model = model
        self.archived = archived
    }
}
