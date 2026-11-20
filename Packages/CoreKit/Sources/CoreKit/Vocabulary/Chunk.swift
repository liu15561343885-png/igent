import Foundation

/// 适配器输出的原始流式协议。**这是全项目最重要的契约**，改动成本极高。
///
/// 契约：
/// 1. `index` 唯一标识一个块，跨 delta 关联；允许交错（reasoning 与 text 同时流）。
/// 2. 允许 delta-only 适配器不发 `blockStart`/`blockEnd`。
/// 3. 已被 `blockEnd` 关闭的 index 再收到 delta → 丢弃。
/// 4. `usage` 至多一次，且必须在 `finish` 之前；`finish` 恰一次且为终态。
/// 5. 适配器私有元数据走 `finish` 的 `meta`，不进内容块。
/// 6. 载体无关：各家 SSE 帧格式不同，都归一到这里。
public enum StreamChunk: Sendable, Equatable {
    case blockStart(index: Int, type: BlockType)
    case textDelta(index: Int, text: String)
    case reasoningDelta(index: Int, text: String)
    case blockEnd(index: Int, block: ContentBlock)
    case usage(TokenUsage)
    case finish(FinishReason, meta: ProviderMeta?)
}
