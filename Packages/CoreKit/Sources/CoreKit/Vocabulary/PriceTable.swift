import Foundation

/// 一个模型的计价（美元 / 百万 token）。
public struct ModelPrice: Sendable, Equatable {
    public var inputPerMillion: Double
    public var outputPerMillion: Double
    public var cacheReadPerMillion: Double?

    public init(inputPerMillion: Double, outputPerMillion: Double, cacheReadPerMillion: Double? = nil) {
        self.inputPerMillion = inputPerMillion
        self.outputPerMillion = outputPerMillion
        self.cacheReadPerMillion = cacheReadPerMillion
    }
}

public struct CostEstimate: Sendable, Equatable {
    /// 价格表里没有这个模型时为 nil——**不要拿 0 假装算出来了**。
    public var amountUSD: Double?
    public var matchedModel: String?

    public var isAvailable: Bool { amountUSD != nil }
}

/// 内置价格表。
///
/// ⚠️ 这些是**估算值**，写在代码里意味着它会过时。厂商调价、推出新模型之后，
/// 这里算出来的数字只能当量级参考。做精确账单请以厂商后台为准。
///
/// 匹配规则：模型 id 里包含键名即命中；按键长度倒序匹配，避免 `gpt-4o` 抢先匹配掉 `gpt-4o-mini`。
public enum PriceTable {
    static let entries: [(key: String, price: ModelPrice)] = [
        ("gpt-4o-mini", ModelPrice(inputPerMillion: 0.15, outputPerMillion: 0.60, cacheReadPerMillion: 0.075)),
        ("gpt-4o", ModelPrice(inputPerMillion: 2.50, outputPerMillion: 10.00, cacheReadPerMillion: 1.25)),
        ("gpt-5", ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.125)),
        ("claude-sonnet-4", ModelPrice(inputPerMillion: 3.00, outputPerMillion: 15.00, cacheReadPerMillion: 0.30)),
        ("claude-3-5-sonnet", ModelPrice(inputPerMillion: 3.00, outputPerMillion: 15.00, cacheReadPerMillion: 0.30)),
        ("claude-opus-4", ModelPrice(inputPerMillion: 15.00, outputPerMillion: 75.00, cacheReadPerMillion: 1.50)),
        ("deepseek-chat", ModelPrice(inputPerMillion: 0.27, outputPerMillion: 1.10, cacheReadPerMillion: 0.07)),
        ("deepseek-reasoner", ModelPrice(inputPerMillion: 0.55, outputPerMillion: 2.19, cacheReadPerMillion: 0.14)),
        ("gemini-2.5-flash", ModelPrice(inputPerMillion: 0.30, outputPerMillion: 2.50, cacheReadPerMillion: 0.075)),
        ("gemini-2.5-pro", ModelPrice(inputPerMillion: 1.25, outputPerMillion: 10.00, cacheReadPerMillion: 0.31)),
        ("qwen", ModelPrice(inputPerMillion: 0.30, outputPerMillion: 1.20))
    ]

    public static func price(for model: String) -> (key: String, price: ModelPrice)? {
        let lowercased = model.lowercased()
        let sorted = entries.sorted { $0.key.count > $1.key.count }
        for entry in sorted where lowercased.contains(entry.key) {
            return (entry.key, entry.price)
        }
        return nil
    }

    /// 按互斥计数算钱：未缓存输入 + 缓存读（按缓存价）+ 输出。
    public static func estimate(_ usage: TokenUsage, model: String) -> CostEstimate {
        guard let match = price(for: model) else {
            return CostEstimate(amountUSD: nil, matchedModel: nil)
        }
        let price = match.price
        let million = 1_000_000.0

        var amount = Double(usage.uncachedInputTokens) / million * price.inputPerMillion
        amount += Double(usage.outputTokens) / million * price.outputPerMillion

        if let cacheRead = usage.cacheReadTokens, cacheRead > 0 {
            let cachePrice = price.cacheReadPerMillion ?? price.inputPerMillion
            amount += Double(cacheRead) / million * cachePrice
        }
        // 缓存写入通常按输入价计（各家不同，这里取输入价，误差在可接受范围）。
        if let cacheWrite = usage.cacheWriteTokens, cacheWrite > 0 {
            amount += Double(cacheWrite) / million * price.inputPerMillion
        }

        return CostEstimate(amountUSD: amount, matchedModel: match.key)
    }
}
