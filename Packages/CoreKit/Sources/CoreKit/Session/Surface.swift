import Foundation

/// 由事件日志折叠出的"当前对话"。
///
/// 只读派生值，不落库：任何时候都可以从事件重算，因此投影出错不是灾难。
public struct SurfaceProjection: Sendable, Equatable {
    public var messages: [Message]
    public var lastTurn: Int
    public var isTurnOpen: Bool
    /// 每条消息对应的事件 seq，用于生成 replace 区间。
    public var messageSeqs: [Int64]

    public init(
        messages: [Message] = [],
        lastTurn: Int = 0,
        isTurnOpen: Bool = false,
        messageSeqs: [Int64] = []
    ) {
        self.messages = messages
        self.lastTurn = lastTurn
        self.isTurnOpen = isTurnOpen
        self.messageSeqs = messageSeqs
    }

    /// 最后一条助手消息的事件 seq（重生成时作为 replace 区间）。
    public var lastAssistantSeq: Int64? {
        for (index, message) in messages.enumerated().reversed() where message.role == .assistant {
            return messageSeqs[index]
        }
        return nil
    }

    /// 折叠规则：
    /// - `append` 接在尾部；
    /// - `replace(a, b)` 先移除 seq 落在 [a, b] 的现有节点，再追加新节点。
    public static func build(from records: [SessionRecord]) -> SurfaceProjection {
        var nodes: [(seq: Int64, message: Message)] = []
        var lastTurn = 0
        var isTurnOpen = false

        for record in records {
            if let message = record.event.surfaceMessage {
                switch record.surfaceOp ?? .append {
                case .append:
                    nodes.append((record.seq, message))
                case let .replace(startSeq, endSeq):
                    // 替换节点要占据**被替换区间的位置**，而不是追加到队尾。
                    // 压缩历史时这个区别是致命的：摘要若跑到最后，就排在了它本该归纳的
                    // "最近几轮"之后，模型会先读新对话再读摘要。
                    let insertAt = nodes.firstIndex { $0.seq >= startSeq } ?? nodes.count
                    nodes.removeAll { $0.seq >= startSeq && $0.seq <= endSeq }
                    nodes.insert((record.seq, message), at: min(insertAt, nodes.count))
                }
                continue
            }

            switch record.event {
            case let .turnStart(turn):
                lastTurn = turn
                isTurnOpen = true
            case let .turnEnd(turn, _):
                lastTurn = max(lastTurn, turn)
                isTurnOpen = false
            default:
                break
            }
        }

        return SurfaceProjection(
            messages: nodes.map(\.message),
            lastTurn: lastTurn,
            isTurnOpen: isTurnOpen,
            messageSeqs: nodes.map(\.seq)
        )
    }
}
