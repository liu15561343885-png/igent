import Foundation

/// 输入框上方小气泡里可以显示的信息。
enum UsageBubbleItem: String, CaseIterable, Identifiable {
    case tokens
    case cacheHit
    case context
    case cost

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tokens: "本轮 token"
        case .cacheHit: "缓存命中率"
        case .context: "上下文占用"
        case .cost: "本轮成本"
        }
    }

    var detail: String {
        switch self {
        case .tokens: "↑ 输入 ↓ 输出"
        case .cacheHit: "会话累计的缓存读 / 计价输入"
        case .context: "当前消息估算量占模型窗口的比例"
        case .cost: "按内置价格表估算，仅供参考"
        }
    }
}

extension Int {
    /// 1234 → 1.2k，避免气泡被大数字撑开。
    var compactTokenText: String {
        if self >= 1_000_000 {
            return String(format: "%.1fM", Double(self) / 1_000_000)
        }
        if self >= 1_000 {
            return String(format: "%.1fk", Double(self) / 1_000)
        }
        return "\(self)"
    }
}
