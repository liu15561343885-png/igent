import Foundation

/// 粗粒度的 token 估算。
///
/// 不追求精确——精确要按模型分词器算，四族四套词表，维护成本远大于收益。
/// 估算只用来判断"是不是快撑爆了"，误差 20% 以内完全够用。
public enum TokenEstimator {
    /// 每条消息的固定开销：角色标记、分隔符。
    static let perMessageOverhead = 4

    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var cjk = 0
        var other = 0
        for scalar in text.unicodeScalars {
            if (0x3000...0x9FFF).contains(scalar.value)
                || (0xAC00...0xD7AF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value) {
                cjk += 1
            } else {
                other += 1
            }
        }
        // 中文约 1.5 字符/token，英文约 4 字符/token。
        let cjkTokens = Double(cjk) / 1.6
        let otherTokens = Double(other) / 4.0
        return max(1, Int((cjkTokens + otherTokens).rounded(.up)))
    }

    public static func estimate(_ message: Message) -> Int {
        var total = perMessageOverhead
        for block in message.blocks {
            switch block {
            case let .text(value), let .reasoning(value):
                total += estimate(value)
            case let .context(evidence):
                total += estimate(evidence.digest)
                total += estimate(evidence.query)
                // 来源列表按标题与 URL 粗算
                total += evidence.sources.count * 16
            case .image:
                // 视觉 token 因厂商与尺寸差异很大，取一个保守中位数。
                total += 800
            case .citation:
                total += 8
            case let .document(document):
                total += estimate(document.promptText)
            case let .providerBlock(block):
                // 这些块的正文是密文或结构化 JSON，按体积粗估即可。
                total += max(8, roughSize(block.payload) / 4)
            }
        }
        return total
    }

    /// 递归统计 JSON 的字符规模，避免为了估 token 而先序列化一遍。
    static func roughSize(_ value: JSONValue) -> Int {
        switch value {
        case .null: 4
        case .bool: 5
        case .number: 8
        case let .string(text): text.count
        case let .array(items): items.reduce(0) { $0 + roughSize($1) + 1 }
        case let .object(fields): fields.reduce(0) { $0 + $1.key.count + roughSize($1.value) + 4 }
        }
    }

    public static func estimate(_ messages: [Message]) -> Int {
        messages.reduce(0) { $0 + estimate($1) }
    }

    public static func estimate(_ system: String?) -> Int {
        guard let system, !system.isEmpty else { return 0 }
        return estimate(system)
    }
}
