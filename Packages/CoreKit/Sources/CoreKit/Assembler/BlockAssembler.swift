import Foundation

public enum AssemblyError: Error, Equatable {
    /// 未知类型的块既没有 `blockEnd`，也没有可推导的文本内容。
    case unclosedUnknownBlock(index: Int, type: BlockType)
}

/// 把 `StreamChunk` 增量装配成 `ContentBlock` 列表。
///
/// 单一装配算法，UI 与持久化共用；禁止在别处再写一份拼接逻辑。
public struct BlockAssembler: Sendable {
    private struct Partial: Sendable {
        var type: BlockType
        var text: String = ""
        var block: ContentBlock?
    }

    private var partials: [Int: Partial] = [:]
    private var order: [Int] = []
    private var closed: Set<Int> = []
    private var _usage: TokenUsage?
    private var _finish: FinishReason?
    private var _meta: ProviderMeta?

    public init() {}

    public mutating func push(_ chunk: StreamChunk) {
        switch chunk {
        case let .blockStart(index, type):
            ensure(index: index, type: type)

        case let .textDelta(index, text):
            guard !closed.contains(index) else { return }
            var partial = ensure(index: index, type: .text)
            partial.text += text
            partials[index] = partial

        case let .reasoningDelta(index, text):
            guard !closed.contains(index) else { return }
            var partial = ensure(index: index, type: .reasoning)
            partial.text += text
            partials[index] = partial

        case let .blockEnd(index, block):
            var partial = ensure(index: index, type: block.type)
            partial.block = block
            partials[index] = partial
            closed.insert(index)

        case let .usage(usage):
            _usage = usage

        case let .finish(reason, meta):
            _finish = reason
            if let meta { _meta = meta }
        }
    }

    /// 装配全部块。未知类型且未闭合的块会抛错——宁可失败，也不写坏历史。
    public func blocks() throws -> [ContentBlock] {
        var result: [ContentBlock] = []
        for index in order {
            guard let partial = partials[index] else { continue }
            if let block = partial.block {
                result.append(block)
                continue
            }
            switch partial.type {
            case .text:
                if !partial.text.isEmpty { result.append(.text(partial.text)) }
            case .reasoning:
                if !partial.text.isEmpty { result.append(.reasoning(partial.text)) }
            default:
                throw AssemblyError.unclosedUnknownBlock(index: index, type: partial.type)
            }
        }
        return result
    }

    /// 中断时能安全定稿的前缀：已闭合块 + 有实质内容的未闭合 text/reasoning。
    /// 只有空白的内容不算产出。
    public func interruptedBlocks() -> [ContentBlock] {
        var result: [ContentBlock] = []
        for index in order {
            guard let partial = partials[index] else { continue }
            if let block = partial.block {
                result.append(block)
                continue
            }
            let hasSubstance = !partial.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            switch partial.type {
            case .text where hasSubstance:
                result.append(.text(partial.text))
            case .reasoning where hasSubstance:
                result.append(.reasoning(partial.text))
            default:
                continue
            }
        }
        return result
    }

    public var usage: TokenUsage? { _usage }
    public var finish: FinishReason { _finish ?? .stop }
    public var meta: ProviderMeta? { _meta }

    @discardableResult
    private mutating func ensure(index: Int, type: BlockType) -> Partial {
        if let existing = partials[index] { return existing }
        let created = Partial(type: type)
        partials[index] = created
        order.append(index)
        return created
    }
}
