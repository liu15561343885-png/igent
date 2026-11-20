# igent 执行方案 v2

> iOS 18+ / SwiftUI / Swift 6 · 单人自用 · 不涉及上架与备案 · 允许服务端检索工具 · 支持 Skill
>
> 架构基线：本机 DeepSeek Harness（`0.2.1-rc.2`，`/Applications/DeepSeek Harness.app/Contents/Resources/dsh/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/`）的 LLM / Session / Web / Skill 四层。保留其**词汇与边界**，剥离其**工具运行时与插件机制**。

---

## 0. 相对 v1 的四处实质变化

| # | v1 做法 | v2 做法（对齐 DSH） | 为什么值得改 |
|---|---|---|---|
| 1 | 消息 = `role + parts[]`，直接落库 | **事件日志 + Surface**：append-only event log，消息由事件投影出来；压缩/重生成/编辑都是 `surface replace` | 重生成、编辑重发、分支、压缩共享同一套机制，不用各写一遍；审计与回放天然成立 |
| 2 | 流式事件 = `textDelta` 等扁平枚举 | **`StreamChunk` 带 block index + `block-start/end/usage/finish` 契约 + `BlockAssembler`** | 多块交错（思维链与正文同时流）、中断截断、usage 先于 finish，都有确定语义 |
| 3 | 我给了"预设 JSON + 适配器"两个概念 | **适配器（按协议族）× ProviderProfile（声明式路由目录）× 注册表可原子替换** | 新增厂商只加数据；改配置不重启会话；"未内置厂商"与"内置厂商改地址"走同一条路径 |
| 4 | 未考虑 skill | **Skill 以 `instructions` / `catalog` 形态的 context 注入；激活由"编排器选 + 用户选"决定，不经模型** | DSH 的 skill 有两条通路，"用户显式调用"本就不经工具，直接保留；被删的只有 `skill` 工具那条 |

另外两处沿用并强化：**web seam（search/fetch 分离）+ 模型原生 grounding 映射到同一 seam**；**token meter 的 disjoint usage 计量 + 按路由定价**。

---

## 1. 约束与范围

| 项 | 结论 |
|---|---|
| 平台 | iOS 18+，iPhone 优先，iPad 自适应 |
| 语言/框架 | Swift 6 严格并发、SwiftUI、Observation、系统 SQLite（零第三方依赖） |
| 分发 | 自用：Xcode 直装 / TestFlight / 自签，无需审核 |
| 后端 | 无。纯客户端 BYOK |
| 数据边界 | **完全本地**：无后端、无中继、无桥接、无遥测。唯一出站流量是直连用户配置的厂商 API |
| 工具调用 | **不存在**。模型永不产生 call，步骤由编排器决定 |
| 服务端检索 | 允许（OpenAI `web_search`、Gemini `google_search`、Anthropic `web_search_20250305`、xAI Live Search、Perplexity） |
| 联网兜底 | 自建 search→fetch→extract 管线 |
| 多厂商 | 四个协议族适配器 + 声明式 Profile，覆盖任意 OpenAI 兼容端点与自定义形态 |
| Skill | 支持。Markdown + frontmatter，`Documents/Skills/` 可外部编辑；三层激活（常驻/手动/自动），**不依赖工具调用** |

### 1.1 核心设计决定：把"工具循环"换成"固定步骤表"

DSH 的循环是 `模型出 tool-call → 执行 → 结果回灌 → 再要一步`。本 App 删除这条通路，改为**编排器预定的步骤表**：

```
turn
 ├─ step 1  [可选] 查询改写      purpose = .queryRewrite    （小模型、低 token）
 ├─ step 2  [可选] 检索 + 抓取   无模型调用，纯 HTTP         → context/message
 └─ step 3  回答                grounding 或注入 context    → assistant/message
```

模型只在 step 3（或 step 1）被调用一次，输出即为终态。**用户感知是"它自己会查"，实际是确定性编排**——这正是"保留 agent 体验、去掉工具调用"的落点。

---

## 2. 从 DSH 抄什么、不抄什么

### 2.1 抄（词汇与边界）

| DSH 包 | 概念 | 在 App 里的位置 |
|---|---|---|
| `dsh-llm/types.ts` | `ContentBlock`（text/reasoning/image/file/tool-call…）、`FinishReason`、`TokenUsage`（disjoint）、`StreamChunk`、`LlmFailure`、`GenerateOptions` | `Core/Vocabulary` |
| `dsh-llm/assembler.ts` | `BlockAssembler`：chunk → blocks，含 `interruptedBlocks()` | `Core/Assembler` |
| `dsh-llm/index.ts` | `LlmAdapter` 抽象 + `registerAdapter(providers, adapter)` + 原子 `replace(routes)` | `LLM/LlmRuntime` |
| `dsh-llm/retry-policy.ts` | provider 持有重试策略：mode(normal/always) + maxRetries + retryableCodes + backoff(jitter) | `LLM/RetryPolicy` |
| `dsh-llm/error.ts` | 稳定错误码（AUTH / RATE_LIMIT / QUOTA / CONTEXT_WINDOW_EXCEEDED / EMPTY_RESPONSE / IMAGE_OFFLOAD_REQUIRED…） | `Core/LlmErrorCode` |
| `dsh-session/types.ts` | `SessionEventMap`（turn/step/message…）、`SurfaceOp = append \| replace`、`SessionSeq` | `Core/Session` |
| `dsh-agent-loop` | turn / step 边界语义、`assistant/attempt`（失败不留痕）、`interrupted: true` | `Core/Orchestrator`（单步版） |
| `dsh-compaction` | `compaction/summary` 记录被 shadow 的区间与 shadow 价格 → 紧跟一条替换消息 | `Core/Compaction` |
| `dsh-token-meter` | 请求压力 = surface 全量 replay 定价；provider usage 仅在信封匹配时复用 | `Core/TokenMeter` |
| `dsh-web/types.ts` | `WebSearchRequest/Result`（sources: url/title/snippet/publishedAt）、`WebFetchRequest/Result`（body kind: html/text/json…） | `Web/Seam` |
| `dsh-attachment/types.ts` | `ImageAttachmentRef`：内容寻址 id + 校验过的 mediaType + 字节数 + 尺寸 + 原始尺寸 | `Storage/Attachments` |
| `dsh-session-title-llm` | 首次提问后异步生成标题（`purpose = .sessionTitle`） | `Features/Chat` |
| `dsh-skill` | `SkillSummary`/`SkillDefinition`、`invocation` 策略、name 去重与 rank 优先级、渐进加载（list 拿摘要 / get 拿正文）、`renderSkillContent` | `Core/Skills` |
| `dsh-tool-skill` 的 catalog 部分 | `<available_skills>` 以 `catalog` 形态发布为 context，集合变化时替换 | `Core/Skills`（不抄 loader 工具） |
| `dsh-skill-filesystem` | 目录型 + 扁平 Markdown、YAML frontmatter、多根目录与优先级、变更监听 | `Core/Skills/FileSystemSkillProvider` |
| `SkillInvocationSource` | 用户显式调用 → 正文以 `instructions` 形态注入 context | `Core/Skills`（**这正是无工具版的核心**） |

### 2.2 不抄

| 不抄 | 原因 |
|---|---|
| cordis DI / plugin loader / service 注入 / waterfall 事件（`llm/stream` 拦截） | 305 个包的插件化是为可扩展产品设计的；单人自用只需 protocol + 一个 actor |
| 工具运行时：`dsh-tools`、tool-call 块、tool/result 事件、审批、沙箱、MCP、subagent、workflow、jobs、terminal、fs | 需求明确删除 |
| `dsh-tool-skill` 的 `skill` 加载工具与 `modelInvocable` 通路 | 无工具可调；改由编排器路由 + 用户手动选择替代（见 §9） |
| JSONL 持久化 + v0→v4 迁移链 | 用 SQLite schemaVersion 单调迁移即可 |
| `DeveloperMessage` / tool-addition / tool-removal / `ToolUpdate` | 无工具可增量声明 |
| 完整 `ReplayEnvelope` 与 raw chunk 全量落库 | 只保留 `ProviderMeta`（responseId、native stop reason）+ 调试环形缓冲 |
| Branded 幻影类型 | Swift 侧用 `typealias`/`struct` 包装即可，不引入 phantom brand |
| 一概念一 package 的粒度 | 合并为 ~8 个 SPM target |

---

## 3. 分层与目录

```
igent/
├─ igentApp/                     @main、依赖装配、Scene
├─ Core/
│  ├─ Vocabulary/                ContentBlock, Message, StreamChunk, FinishReason,
│  │                             TokenUsage, LlmFailure, LlmErrorCode, GenerateOptions
│  ├─ Assembler/                 BlockAssembler
│  ├─ Session/                   SessionEvent, SessionRecord, SurfaceOp, SessionStore(protocol)
│  ├─ Orchestrator/              TurnOrchestrator, StepPlan, TurnEndReason
│  ├─ Compaction/                CompactionService
│  ├─ Skills/                    SkillSummary, SkillDefinition, SkillRegistry,
│  │                             FileSystemSkillProvider, SkillRouter, SkillRenderer
│  └─ TokenMeter/                Estimator, RequestMeasurement, RoutePricing
├─ LLM/
│  ├─ LlmRuntime                 actor：注册表 + 路由 + 流式入口
│  ├─ Adapters/                   四族；Azure 是 ProviderProfile 变体，不单开适配器
│  │  ├─ OpenAICompatible/        含 Azure、DeepSeek、OpenRouter… 全部方言
│  │  ├─ OpenAIResponses/
│  │  ├─ Anthropic/
│  │  └─ Gemini/
│  ├─ Transport/                 SSEDecoder, HTTPTransport, RetryExecutor
│  └─ Profiles/                  ProviderProfile, ProviderDirectory, ModelDiscovery
├─ Web/
│  ├─ Seam                       WebSearchProvider, WebFetchProvider, GroundedSearchProvider
│  ├─ Providers/                 Tavily, Brave, Exa, Perplexity, DeepSeek, xAI
│  └─ Extract/                   Readability 启发式正文抽取
├─ Storage/
│  ├─ Database/                  SQLite 封装、迁移、EventStore、Projection
│  ├─ Keychain/
│  └─ Attachments/               内容寻址图片存储 + 下采样
├─ Features/
│  ├─ Chat/                      ChatView, ChatViewModel, Composer, MessageList
│  ├─ Providers/                 ProviderList, ProviderEditor, ModelPicker, ConnectionTest
│  ├─ Skills/                    SkillList, SkillDetail, SkillEditor, SkillPicker, SkillChip
│  ├─ Sources/                   引用卡片、预览
│  ├─ Inspect/                   请求检查器（原始 SSE 前 N 帧）
│  └─ Settings/
└─ UI/                           DesignSystem, MarkdownRenderer, StreamingTextView, Haptics
```

---

## 4. 核心词汇（Swift）

### 4.1 内容块

```swift
public enum BlockType: String, Codable, Sendable {
    case text, reasoning, image, context, citation
}

public enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case reasoning(String)
    /// 助手侧输出图片（图像模型），或用户输入图片
    case image(ImageAttachmentRef)
    /// 检索证据：模型看到的正文片段。**取代 dsh 的 tool-result**
    case context(ContextEvidence)
    /// 引用：UI 渲染上标与来源卡，模型侧不发送
    case citation(Citation)
}

public struct ContextEvidence: Codable, Sendable, Equatable {
    public var query: String
    public var sources: [WebSource]      // url / title / snippet / publishedAt
    public var digest: String            // 清洗+截断后的正文，带 [1][2] 编号
    public var fetchedAt: Date
    public var truncated: Bool
}
```

> 与 DSH 的差异：删除 `tool-call` / `tool-addition` / `tool-removal` / `file`（文件暂不做）；`context` 由**编排器**写入，模型永远无法写入。

### 4.2 消息

```swift
public enum MessageRole: String, Codable, Sendable {
    case system, user, assistant, context
}

/// 谁生产了这条消息。`form` 描述"是什么"，与生产者解耦（对齐 DSH 的 MessageSource + ContextForm）。
public enum MessageSource: Codable, Sendable {
    case user
    case model(provider: String, model: String, meta: ProviderMeta?)
    case systemPrompt
    case webEvidence(query: String)            // 检索证据
    case skillCatalog(entries: [SkillEntry])   // 目录，form = .catalog
    case skillInvocation(name: String)         // 正文，form = .instructions
    case compactionSummary(compactionID: UUID)
}

public struct Message: Codable, Sendable, Identifiable, Equatable {
    public let id: MessageID
    public let role: MessageRole
    public let blocks: [ContentBlock]
    public let source: MessageSource
    /// 压缩可否丢弃正文（skill 正文、检索片段可丢，用户原话不可丢）
    public let retention: Retention            // .durable / .ephemeral
    public let createdAt: Date
}

public enum Retention: String, Codable, Sendable {
    case durable      // 用户输入、助手回答、压缩摘要
    case ephemeral    // 检索证据、skill 正文、skill 目录
}
```

### 4.3 流式块（严格契约）

```swift
public enum StreamChunk: Sendable {
    case blockStart(index: Int, type: BlockType)
    case textDelta(index: Int, text: String)
    case reasoningDelta(index: Int, text: String)
    case blockEnd(index: Int, block: ContentBlock)
    case usage(TokenUsage)                  // 必须在 finish 之前，且之后不再有 chunk
    case finish(FinishReason, meta: ProviderMeta?)
}
```

契约（照搬 DSH 并写进适配器文档注释）：

1. `index` 唯一标识一个块，跨 delta 关联；允许**交错**（reasoning 与 text 同时流）。
2. 允许 delta-only 适配器不发 `block-start/end`；`BlockAssembler` 需容忍。
3. 已被 `block-end` 关闭的 index 再收到 delta → 丢弃（防上游异常撑爆内存）。
4. `usage` 至多一次；`finish` 恰一次且为终态；适配器抛错由 `LlmRuntime` 归一化为 `finish(.error/aborted)`。
5. 适配器私有元数据（response id、原生 stop reason）走 `finish.meta`，不进内容块。
6. **载体无关**：四族都走 SSE，但帧格式不同；`StreamChunk` 不感知传输层（将来换 WebSocket 也不改契约）。

### 4.4 终止原因 / 用量 / 失败

```swift
public enum FinishReason: Sendable, Equatable {
    case stop
    case maxTokens
    case contentFilter(String?)
    case aborted(LlmFailure)
    case error(LlmFailure)
}

/// 计数互斥：inputTokens 只含未缓存输入；缓存读/写单独计。
/// 计价输入 = input + cacheRead + cacheWrite。
public struct TokenUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int?
    public var cacheReadTokens: Int?
    public var cacheWriteTokens: Int?
    public var reasoningTokens: Int?
}

public struct LlmFailure: Error, Codable, Sendable {
    public var message: String
    public var code: LlmErrorCode
    public var status: Int?
    public var providerRetryAfterMs: Int?
    public var requestId: String?
}

public enum LlmErrorCode: String, Codable, Sendable {
    case auth, invalidCredential, rateLimit, quota, contextWindowExceeded
    case emptyResponse, noAdapter, cancelled, server, network
    case contentFilter, unsupportedCapability, imageTooLarge, decodeFailed
}
```

> `EMPTY_RESPONSE` 值得单独存在：厂商偶尔返回"正常结束但零内容"，直接落一条空消息会让 UI 静默失败，必须归类为可重试失败。

### 4.5 请求

```swift
public struct GenerateOptions: Sendable {
    public var provider: ProviderID
    public var model: String
    public var messages: [Message]
    public var system: String?
    public var temperature: Double?
    public var maxTokens: Int?
    public var stop: [String]?
    public var reasoning: ReasoningEffort?
    public var purpose: CallPurpose?        // .compaction / .sessionTitle / .queryRewrite
    public var extras: [String: JSONValue]  // 厂商私有参数逃生口
}
```

`purpose` 不只是标注：适配器可据此映射到 provider 的隐式路由（如摘要用便宜模型），计量也可分开统计。

---

## 5. 适配器层

### 5.1 协议

```swift
public protocol LlmAdapter: Sendable {
    func info(_ provider: ProviderID) -> ProviderInfo
    func retryPolicy(_ provider: ProviderID) -> RetryPolicy
    func listModels(_ provider: ProviderID) async throws -> [ModelInfo]
    func resolveModel(_ provider: ProviderID, _ model: String) async throws -> ResolvedModelInfo
    func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error>
}
```

调用 `stream` 即为唯一必需实现；其余给默认实现（空模型表、默认重试策略、按 profile 推断能力）。

### 5.2 注册表

```swift
public actor LlmRuntime {
    public func register(providers: [ProviderID], adapter: LlmAdapter) throws -> Registration
    public func stream(_ options: GenerateOptions) -> AsyncThrowingStream<StreamChunk, Error>

    /// 校验全部候选 → 单同步段替换，任何时刻不出现空窗
    public struct Registration: Sendable {
        public func replace(providers: [ProviderID]) throws
    }
}
```

`replace` 是做"改配置立刻生效、且不与在途请求撕裂"的关键：候选集先整体校验，再一次性换。

### 5.3 声明式 ProviderProfile

```json
{
  "id": "deepseek",
  "family": "openai-compatible",
  "name": "DeepSeek",
  "baseURL": "https://api.deepseek.com/v1",
  "auth": { "style": "bearer", "keyRef": "keychain://deepseek/default" },
  "headers": {},
  "capabilities": {
    "streaming": true, "vision": false, "imageOut": false,
    "nativeSearch": false, "reasoning": true, "streamUsage": true,
    "requiresMaxTokens": false, "systemStyle": "message"
  },
  "limits": { "contextWindow": 128000, "maxOutput": 8192, "maxImages": 0 },
  "models": [
    { "id": "deepseek-chat", "label": "V3.2" },
    { "id": "deepseek-reasoner", "label": "R1", "reasoning": ["low", "high"] }
  ],
  "pricing": { "currency": "USD", "in": 0.27, "out": 1.10, "cacheRead": 0.07 }
}
```

- `auth.style`：`bearer` / `x-api-key` / `query-key` / `header(name)` / `api-key`（Azure）。
- `systemStyle`：`message` / `topLevel`（Anthropic）/ `systemInstruction`（Gemini）。
- 未内置的厂商：UI 里填 baseURL + 鉴权 + 粘一个能力 JSON，走同一个 `openai-compatible` 适配器，无需发版。

### 5.4 模型发现（连接测试）

```swift
public struct ModelDiscoveryRequest: Sendable {
    public var provider: ProviderID?     // 编辑已有路由
    public var baseURL: String?
    public var family: ProviderFamily?
    public var apiKey: String?           // 仅本次使用，绝不落库
}
```

先打 `GET /v1/models`（Anthropic `/v1/models`、Gemini `models`），失败则退化为"发一条 `max_tokens=1` 的最小请求"验证鉴权。**编辑中的草稿直接可测**，不需要先保存。

### 5.5 四族差异清单（写进 fixture 用例）

| 项 | OpenAI 兼容 | OpenAI Responses | Anthropic | Gemini |
|---|---|---|---|---|
| 路径 | `/chat/completions` | `/responses` | `/messages` | `:streamGenerateContent?alt=sse` |
| 鉴权 | `Authorization: Bearer` | 同 | `x-api-key` + `anthropic-version` | `x-goog-api-key` |
| 系统提示 | messages[0] role=system | `instructions` | 顶层 `system` | `systemInstruction.parts` |
| 输出上限 | `max_completion_tokens`（新）/`max_tokens`（旧） | `max_output_tokens` | **必填** `max_tokens` | `generationConfig.maxOutputTokens` |
| SSE | `data: {...}` … `data: [DONE]` | 命名事件 `response.output_text.delta` 等 | 命名事件 `message_start`/`content_block_delta`/`message_delta`/`message_stop`/`ping` | `data: {...}` 完整响应体 |
| 思维链 | `reasoning_content`（DeepSeek）/`reasoning`（OpenRouter）/`enable_thinking`（Qwen） | `reasoning` item | `thinking_delta` + `signature_delta` | `parts[].thought` |
| 图片入 | `image_url`(data URI) | `input_image` | `source:{type:base64,media_type,data}` | `inlineData:{mimeType,data}` |
| 用量 | `stream_options.include_usage` | `response.completed.usage` | `message_start`/`message_delta` 两段 | 每帧 `usageMetadata` |
| 角色 | assistant | assistant | assistant | **`model`** |
| finish 映射 | `stop`/`length`/`content_filter` | `stop`/`max_output_tokens` | `end_turn`/`max_tokens`/`refusal` | `STOP`/`MAX_TOKENS`/`SAFETY` |

不接本机模型（Ollama / LM Studio）：全部走 HTTPS 云 API，因此 App 不需要本地网络权限，也不需要 ATS 的本地明文例外。

**Azure 不单开适配器。** 它的报文与 OpenAI Chat Completions 完全同构，差异只有三处：部署名进路径（`/openai/deployments/{deployment}/chat/completions`）、`api-version` 进查询串、鉴权走 `api-key` 头。这三处都能用 `ProviderProfile` 表达（`chatPath` 支持 `{model}` 占位与 `?query`、`auth` 支持任意头名），所以它是配置而不是代码。有单测钉住"Azure 报文与 OpenAI 逐字段相同"。

### 5.6 BlockAssembler

```swift
public struct BlockAssembler {
    public mutating func push(_ chunk: StreamChunk)
    public func blocks() -> [ContentBlock]
    /// 中断时只保留已闭合/未闭合但非空的 text/reasoning 块
    public func interruptedBlocks() -> [ContentBlock]
    public var usage: TokenUsage? { get }
    public var finish: FinishReason { get }   // 无 finish 视为 .stop
}
```

规则：按 index 累积 partial；`block-end` 覆盖并关闭；未知块未关闭 → 抛错（宁可失败也不要写坏历史）；中断剪枝只留可见内容。

---

## 6. 会话层：事件日志 + Surface

### 6.1 事件

```swift
public struct SessionRecord: Codable, Sendable {
    public let seq: Int64                 // 单调，会话内唯一
    public let sessionID: SessionID
    public let time: Date
    public let event: SessionEvent
    public let surface: SurfaceOp?        // 仅消息类事件有
}

public enum SessionEvent: Codable, Sendable {
    case turnStart(turn: Int)
    case turnEnd(turn: Int, reason: TurnEndReason)
    case stepStart(turn: Int, step: Int)
    case stepEnd(turn: Int, step: Int)
    case systemMessage(Message)
    case userMessage(Message)
    case contextMessage(Message)              // 检索证据
    case assistantMessage(Message, usage: TokenUsage?, interrupted: Bool)
    case assistantAttempt(turn: Int, step: Int, failure: LlmFailure)   // 失败不留痕
    case compactionStart(id: UUID, turn: Int?)
    case compactionSummary(id: UUID, summary: [ContentBlock],
                           shadowed: ClosedRange<Int64>, shadowedTokens: Int,
                           provider: String, model: String, usage: TokenUsage?)
    case compactionEnd(id: UUID, error: String?)
    case titleGenerated(String)
}

public enum SurfaceOp: Codable, Sendable {
    case append
    case replace(startSeq: Int64, endSeq: Int64)   // 闭区间，含端
}
```

### 6.2 Surface 一份机制覆盖四个功能

| 功能 | 实现 |
|---|---|
| 重生成 | 新 `assistant/message`，`surface = .replace(旧消息 seq, 旧消息 seq)` |
| 编辑用户消息并重发 | 新 `user/message` replace 旧 user（+ 其后 assistant 一并 shadow） |
| 上下文压缩 | `compaction/summary` 记录 shadowed 区间 → 紧跟一条 replace 的 `context/message`（摘要） |
| 分支 | `fork(atSeq:)`：复制前缀事件到新 session，记 `parentSession` + `forkedAtSeq` |

好处：**UI 只需读 surface（投影后的消息序列），历史一条不丢**；"删掉的"仍在日志里，可回滚。

### 6.3 关键投影

```swift
public struct SurfaceProjection: Sendable {
    public var messages: [Message]              // 按 surface 顺序，含被 replace 覆盖后的净结果
    public var lastTurn: Int
    public var lastStepBoundary: StepBoundary?
    public var isTurnOpen: Bool
}
```

`SessionStore` 提供 `append(_:) -> Int64`、`events(after:)`、`surface()`、`fork(atSeq:)`，全部 `async`，actor 串行化。

---

## 7. 编排器（取代 agent loop）

```swift
public actor TurnOrchestrator {
    public func send(_ input: UserMessage) async   // 入队即返回
    public func cancel() async                     // 取消当前 turn
    public func whenIdle() async
}

enum StepPlan: Sendable {
    case answer                       // 普通对话
    case rewriteThenAnswer            // 自建检索：先改写查询
    case groundedAnswer(GroundingMode) // 厂商原生检索
}
```

一个 turn 的执行序列：

```
turn/start
  ├─ 组装 system（若变化）→ system/message (append)
  │    └─ 常驻 skill（always）在此按固定顺序拼入
  ├─ user/message (append)
  ├─ [plan == rewrite]  step/start(1) → 小模型改写 → step/end(1)
  │                      （改写结果只进内存，不落 surface）
  ├─ [skill]            手动选择 → 注入；自动模式 → 首轮路由一次 → context/message (append)
  ├─ [联网]              WebSearch → 并发 WebFetch → Extract → context/message (append)
  ├─ step/start(2 或 3)
  ├─ LlmRuntime.stream(...) → 边流边更新内存 draft → UI
  │    ├─ 正常     → assistant/message(usage) (append)
  │    └─ 取消     → assistant/message(interrupted: true) 或 assistant/attempt
  └─ step/end / turn/end(reason)
```

与 DSH 的一处有意差异：**没有 `dispatch` 与工具执行阶段**，因此 step 是纯"模型调用"，`stepEnd` 之后不会再有 `stepStart`（除固定的改写步）。

取消语义：`turn/end(.cancelled)` + 已产出内容按 `interruptedBlocks()` 落一条 `assistant/message(interrupted: true)`；一个字都没出则落 `assistant/attempt`。

---

## 8. 联网检索

### 8.1 seam（两件事分开，各自可换供应商）

```swift
public protocol WebSearchProvider: Sendable {
    var id: String { get }
    func search(_ request: WebSearchRequest) async throws -> WebSearchResult
}

public protocol WebFetchProvider: Sendable {
    func fetch(_ url: URL) async throws -> WebFetchResult
}

public struct WebSearchResult: Sendable {
    public var content: String?          // 供应商生成的答案（Perplexity 有）
    public var sources: [WebSource]
    public var truncated: Bool
}

public struct WebSource: Codable, Sendable, Identifiable {
    public var url: URL
    public var title: String?
    public var snippet: String?
    public var publishedAt: String?
    public var id: String { url.absoluteString }
}
```

`WebFetchedBody` 用闭合枚举：`.html(String)` / `.text(String)` / `.json(Data)` / `.binary(mediaType, Data)` / `.unsupported(mediaType)`。

### 8.1.1 DeepSeek：两种联网，分工不同

DeepSeek 同时提供两套能力，我们把它们放在不同层次上：

| | 服务端工具（Web Tools） | Search & Fetch API |
|---|---|---|
| 谁决定搜 | **模型自己** | 应用决定 |
| 能力 | 搜索 / 开页 / 页内查找，最多约 20 步 | 单次查询、单页抓取 |
| 计费 | 搜索免费，只算 token | $0.75 / 千次成功请求 |
| 用在哪 | 有服务端工具的厂商（DeepSeek） | 其他厂商的兜底路径 |

“联网搜索”开关因此有两种含义：

- 厂商声明了 `serverTools` → 把工具声明发给模型，**由它决定搜不搜、搜几次、开哪些页**；
- 没有 → 退回应用侧的一次性检索（检索 → 抓取 → 注入 context）。

### 8.1.2 服务端工具的实现要点

| 点 | 做法 |
|---|---|
| 声明 | `tools: [{type:"deepseek_web_search", name:"..."}, …]`，用 `ServerToolSpec` 数据描述，加一家的原生检索只加配置 |
| 关闭 | **不声明工具**。不能用 `tool_choice: none`——文档明确它会连 URL 阅读一起关掉 |
| 解析 | `server_tool_use` / `web_search_tool_result` / `web_fetch_tool_result` 一次性到达，当帧闭合 |
| 回传 | 新增 `ContentBlock.providerBlock`，**原样存、原样回传**。DeepSeek 把网页正文加密在 `signature` 里，丢了它上一轮读过的页就从上下文里消失 |
| 引用 | `citations_delta` → 独立的 `citation` 块，UI 渲染成来源卡 |
| UI | 气泡顶部显示“检索了哪些词 / 打开哪个站”，底部是来源卡 |

### 8.1.3 检索规划：让模型参与决策，但不引入工具循环

「GPT 主对话 + DeepSeek 检索」这个组合里，模型没法用 DeepSeek 的服务端工具
（那是 DeepSeek 私有的）。为了不让检索退化成"拿用户原话硬搜"，加了一层规划：

```
用户问题 → 一次小调用：{"search": true, "queries": ["…","…"]}
            ├─ search = false → 不检索，界面提示"模型判断本轮不需要联网"
            └─ search = true  → 并发执行 1–3 条检索式 → 合并成一条证据注入
```

关键区别：**这仍然不是工具调用**。模型不产出 call，也拿不到执行结果再决定下一步；
它只做一次规划，执行与注入由应用完成。所以"无工具循环"的约束没被打破。

代价：多一次小调用（`maxTokens: 160`）。收益：检索式从"一整段话"变成"带实体和年份的具体查询"。
规划失败时退回用户原话——检索能力不该因为规划挂了而失效。

多查询的结果会**合并成一条 context**（来源按 URL 去重），而不是发多个 context 块——
一次请求的上下文预算有限，割裂的资料反而更难读。

### 8.2 两条路径统一成 `context/message`

| 路径 | 做法 |
|---|---|
| **原生 grounding** | 适配器在请求体里加服务端检索声明（`web_search` / `google_search` / `web_search_20250305`），解析响应中的 `citations` / `groundingMetadata` / `url_citation` → 归一化为 `[WebSource]` → 落 `assistant/message` 的 `citation` 块 + 附加一条 `context/message` 供后续轮次引用 |
| **自建管线** | `search` → 取 top 3~5 → 并发 `fetch`（5s 超时、拒非 http(s)、上限 5MB）→ Readability 抽正文 → 去重 → 按 token 预算截断 → 编号注入 → `context/message` |

自建管线的注入模板（固定，不让模型自己找）：

```
以下为检索到的资料，引用时用 [n] 标注，不得使用资料之外的事实：
[1] {title} — {url}
{正文片段}
[2] ...
```

UI：正文里的 `[n]` 渲染为上标按钮，点开 `SFSafariViewController`；底部横向来源卡。

**实现（WebSeamKit）**

| 组件 | 说明 |
|---|---|
| `WebSearchProvider` | `Tavily`（带 answer 摘要）与 `Brave` 两实现 |
| `WebFetchProvider` / `HTTPFetcher` | 12s 超时、2MB 上限、只收 text/html |
| `HTMLTextExtractor` | 去脚本样式、块标签转换行、解码实体、收敛空白 |
| `WebContextBuilder` | 检索 → 并发抓前 3 页 → 拼带编号的证据 |

三条取舍写进了实现：

1. **并发抓取但只抓 3 页**。再多首字延迟明显变差，收益递减。
2. **单页失败不影响整体**：退回搜索摘要，来源列表仍保留（用户还能点开）。
3. **搜索失败也产出证据对象**（内容写失败原因），不让整轮对话因此崩掉。

---

## 9. Skill：无工具激活

### 9.1 问题的本质

DSH 里 skill 有两条通路，只有一条依赖工具：

| 通路 | DSH 机制 | 本 App |
|---|---|---|
| 用户显式调用 | 宿主把正文注入为 `instructions` 形态的 context 消息，**不经过模型决策** | **保留**（正好是我们要的） |
| 模型自主调用 | `skill` 工具按名加载 | **删除**（工具已删） |
| 目录广播 | `<available_skills>` 以 `catalog` 形态 context 发布 | **保留** |

所以"可加入 skill"在无工具世界里只剩一个真问题：**谁来选**。把"模型选"换成"编排器选 + 用户选"。

### 9.2 三层激活策略

| 层 | 触发 | 额外成本 | 适用 |
|---|---|---|---|
| **常驻 `always`** | 会话/全局开关，装配时直接拼进 system | 0 次调用，但每轮占 token | 个人风格、输出格式、默认语言 |
| **手动 `manual`** | 输入框 `#` 补全，或会话顶部 pin | 0 次调用 | 明确知道用哪个 |
| **自动 `auto`** | 编排器路由：先本地关键词/描述匹配，不足时一次便宜模型调用（`purpose = .skillRoute`） | 0～1 次小调用 | 忘了有哪些 skill |

```swift
public protocol SkillRouter: Sendable {
    /// 只允许返回 candidates 里的 name，越界即视为路由失败
    func route(firstMessage: String, candidates: [SkillSummary]) async -> [String]
}
```

两个实现：

- `KeywordSkillRouter`：对 `description + whenToUse` 做分词/同义表匹配，零成本、零延迟。
- `LlmSkillRouter`：把目录（仅 name + description）发给最便宜的模型，要求返回 JSON 数组，最多 2 个。**约束在闭集内**，返回未知名字直接丢弃。

自动路由**只在会话首条消息做一次**，结果记入会话（"本会话已启用：周报助手"），后续轮次直接复用。不每轮增加延迟，行为也可预测；用户随时可改。

### 9.3 数据结构（对齐 `dsh-skill`）

```swift
public struct SkillSummary: Codable, Sendable, Identifiable {
    public let name: String            // kebab-case
    public let description: String     // 一行，路由用
    public let whenToUse: String?
    public let invocation: Set<Invocation>   // .always / .auto / .manual
    public let source: SkillSource           // .bundled / .user / .imported
    public let tokenEstimate: Int
}

public struct SkillDefinition: Sendable {
    public let summary: SkillSummary
    public let body: String                    // SKILL.md 正文
    public let resources: [String: String]     // frontmatter.include 声明的随附文件
    public let metadata: [String: String]
}
```

注册表按 `name` 去重，`user` 覆盖 `bundled`（对应 DSH 的 rank 优先级），同名时 UI 标注来源；`list()` 只返回摘要，`get(name)` 才加载正文——**渐进加载**，列表页不为 200 个 skill 付正文成本。

### 9.4 文件格式

`Documents/Skills/<name>/SKILL.md`（目录型，可带 `references/`、`templates/`）：

```markdown
---
name: weekly-report
description: 把零散记录整理成结构化周报
when_to_use: 用户提到"周报""本周总结""worklog"时
invocation: [auto, manual]
include: [templates/report.md]
version: 1.2
---

# 周报整理

按以下结构输出：…
```

- `include` 声明的文件在激活时一并内联，受 token 预算约束；**未声明的 `references/` 不发送**（无工具意味着模型没法自己去读）。
- 目录放在 `Documents/` 并开启 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，就能在「文件」App 和访达里直接编辑——自用场景下最舒服的写法：**Mac 上写 skill，手机上用**。
- 导入：Files 选择器 / 分享扩展 / `agentchat://skill/import?path=` / 直接拖进 Documents。
- App 内提供只读预览 + 简易编辑器（frontmatter 表单 + Markdown 正文）。
- 支持 iCloud Drive 同步该目录（若 Documents 在 iCloud 容器内，自动生效）。

### 9.5 注入方式：复用 context 事件

```swift
case skillCatalog(entries: [SkillEntry], update: Bool)      // catalog 形态
case skillInvocation(name: String, form: .instructions)     // instructions 形态
```

- **目录**：`context/message`，`source = .skillCatalog`，`retention = .durable`，内容为

  ```
  <available_skills>
  - weekly-report: 把零散记录整理成结构化周报
  - code-review: 按严格清单审查代码
  </available_skills>
  ```

  skill 集合变化时用 `surface.replace` 发一条 `update: true` 的新目录，避免堆叠。

- **注入**：`context/message`，`source = .skillInvocation(name)`，`retention = .ephemeral`，内容为

  ```
  <skill_content name="weekly-report">
  ...正文...
  </skill_content>
  ```

  `name` 做 XML 转义，正文原样嵌入（skill 是本地可信内容）。

- **常驻**：不走 surface，装配 system 时按固定顺序拼接（身份 → 风格 → 格式），变更即重建 system 节点。

`retention: .ephemeral` 让压缩可以安全丢弃旧 skill 正文，只在摘要里留一行"本会话曾使用 skill: weekly-report"。这与事件日志的设计自洽：**注入是 surface 事实，不是模型历史**。

### 9.6 与"无工具"的一致性边界

skill 只能**影响模型怎么说**，不能**让模型做什么**：

- ✅ 提示词模板、输出格式、领域知识、检查清单、few-shot 示例
- ❌ 声明"调用某工具"、要求读写文件、要求执行代码——写了也不生效

因此从 DSH 生态直接搬来的 skill 若含工具语义，相关段落会被忽略。skill 详情页显式提示这一点，避免预期落差。

### 9.6.1 实现记录：注入落点改了

方案原本写的是"以 `context` 消息注入"。实际实现改成**注入 system**，理由：

- 不需要为 skill 新增内容块类型（`ContextEvidence` 带 `<context>` 包装与来源列表，套在 skill 上语义不对）；
- 四族的 system 落点已经被 `systemStyle` 统一处理（message / topLevel / systemInstruction），复用现成机制；
- skill 本质就是指令，放 system 语义最正。

代价：system 每轮都可能变化，厂商的系统提示前缀缓存会失效。多轮长对话里这项开销真实存在，
但换来的是零新增事件类型、零新增渲染路径。

其余按方案落地：

| 项 | 实现 |
|---|---|
| 文件格式 | `Documents/Skills/<name>/SKILL.md` 或 `<name>.md`，frontmatter 同 DSH |
| 随附文件 | 只注入 `include` 显式声明的内容，且有路径穿越防护 |
| 自动路由 | **关键词 n-gram，不调模型**。中文没有空格，"用户提到周报"要切成 2~3 字片段才匹配得上"周报" |
| 常驻 | 每轮注入，开关存 UserDefaults |
| 首启示例 | 写一个 `concise-reply`，否则功能藏得太深 |

### 9.7 UI

skill 入口在**输入框左侧，用弹出气泡**（`.popover` + `presentationCompactAdaptation(.popover)`），
不是整屏 sheet：选 skill 是个轻动作，弹个气泡更接近 iMessage 的轻交互。

| 位置 | 内容 |
|---|---|
| 设置 → Skills | 列表（名称/描述/来源/开关/token 估算），点击预览与编辑 |
| 输入框 | `#` 触发补全；激活后上方显示可点掉的 chip |
| 会话顶部 | "已启用：周报助手（自动）"，点击切换 |
| 消息流 | 一行可折叠的"已注入 skill: weekly-report · 1,240 tokens" |
| 冲突提示 | 两个常驻 skill 指令矛盾时（正则粗检"必须/不要"同类句式），提示用户收敛 |

---

## 10. 计量与压缩

### 9.1 TokenMeter

```swift
public struct RequestMeasurement: Sendable {
    public var inputTokens: Int          // 估算
    public var breakdown: [BlockKind: Int]
    public var contextWindow: Int
    public var pressure: Double          // input / (window - reservedOutput)
}
```

- 估算：`chars / 4 * 1.2`（中日文 `chars / 1.6`），按 role 加固定框架开销；图片按路由定价（`visualTokens`）。
- 校准：每次拿到 provider `usage`，用 `inputTokens / 估算值` 作为该 model 的系数缓存，下一次估算即精确很多。
- 触发：`pressure > 0.75` 时提示或自动压缩。

### 9.2 压缩

```
if pressure > 0.75 && messages.count > 8:
    keep = 最近 4 轮 + system
    shadow = 其余
    summary = 一次 purpose=.compaction 的调用（便宜模型，maxTokens 受限）
    append compaction/summary(shadowed: shadow 的 seq 区间)
    append context/message(summary) with surface .replace(shadow)
    append compaction/end
```

摘要提示固定：保留人名/项目名/数字/决定/未完成事项；丢弃寒暄与重复。

UI 在压缩点显示一条可展开的"已压缩 12 条历史（点击查看原文）"。

**实现记录**

- 压缩是**手动**触发的（会话菜单 → 压缩上下文）。自动阈值压缩留到有真实用量数据之后再定，
  阈值拍脑袋定低了会误伤短对话。
- 落点用 `context` 消息 + `replace` 区间，不新增事件类型；摘要 `retention = .durable`，
  否则下一轮压缩会把它也压掉。
- **代价**：`replace` 必须让新节点占据被替换区间的位置。第一版实现是"删掉再追加"，
  摘要跑到了队尾——模型会先读到最近的对话，再读归纳它们的那段摘要，顺序完全反了。
  这条在 `SurfaceProjection` 里修掉并加了测试。

**自动压缩（参考 DSH `dsh-compaction-basic`）**

两个触发点：

| 时机 | 条件 | 动作 |
|---|---|---|
| 开回合前 | 估算输入 ≥ 窗口 × 0.8（扣掉输出预留） | 压缩较早历史，再发请求 |
| 厂商报 `contextWindowExceeded` | 只重试一次 | 压缩后重发同一轮 |

参数：

| 参数 | 值 | 说明 |
|---|---|---|
| `thresholdRatio` | 0.8 | 压力阈值占可用窗口的比例 |
| `retainRatio` | 0.16 | 保留尾部占可用窗口的比例 |
| `minimumMessages` | 8 | 短会话不压 |
| 保留下限 | **2 条** | 无论预算多小都要留，否则等于清空会话 |
| `overflowRecovery` | 开 | 估算低估时的兜底 |

估算器（`TokenEstimator`）：中文按 1.6 字符/token、其余按 4 字符/token，
每条消息 +4 开销，图片按 800 token 估。误差是必然的，所以溢出兜底必须存在——
**估算是为了少撞墙，不是为了精确**。

**成本显示**

- `PriceTable` 内置常见模型的价格（美元/百万 token），按模型 id 子串匹配、长键优先
  （否则 `gpt-4o` 会抢先匹配掉 `gpt-4o-mini`）。
- 价格表写在代码里意味着会过时，所以 UI 只说"≈"，查不到价格时**只显示 token**，
  不拿 0 假装算出来了。
- 输入框上方一条细状态：`本轮 ↑1234 ↓567 · ≈$0.0021`；会话菜单里有累计统计。

**会话标题**

- 首轮结束后一次短调用（`maxTokens: 32`，`purpose = .sessionTitle`），失败静默放弃。
- 已经是自定义标题就不覆盖。

**导出**

- Markdown，不是 JSON：导出的第一用途是"存一份、发给别人看"。
- 思维链默认不导出（可选），图片留占位而不是静默丢掉。

---

## 11. 图片能力

### 11.1 输入：视觉理解（已实现）

三条硬规则，缺一条都会出错：

| 规则 | 为什么 |
|---|---|
| **应用 EXIF 方向** | 手机竖拍的像素是横的，方向存在 EXIF 里。不转正的话模型看到躺倒的图，用户以为传对了 |
| **长边 ≤ 1568** | 三家上限不同，1568 是都能接受的保守值。只缩不放，放大只会白增字节 |
| **统一成 JPEG** | HEIC 三家都不认；PNG 体积太大。`UTType.identifier` 是 `public.jpeg`，厂商要的是 MIME `image/jpeg`——这个坑踩过一次 |

附件存储用**内容寻址 + 两级分桶**（`ab/<sha256>.jpg`），同一张图只存一份。
路径存**相对**的：iOS 沙盒绝对路径在重装、备份恢复后会变，存绝对路径等于埋雷。

解析时机放在**请求前异步批量**，不在序列化同步路径上做 base64——几 MB 的图编码会卡住调用方。
能力门控：`vision == false` 时直接丢弃图片，而且**不去读盘**（有测试断言解析器零调用）。

### 11.2 输出：生成（已实现 · 同步两族）

| 族 | 端点 | 返回 |
|---|---|---|
| OpenAI Images | `POST /images/generations` | `b64_json` 或 `url`（都要处理，厂商不保证） |
| Gemini Images | `POST /models/{model}:generateContent` + `responseModalities` | `inlineData` |

**图片厂商与对话厂商分开配置**：能聊天的厂商不一定能画图（DeepSeek、Kimi 都没有图像模型），
能画图的也可能不是同一个账号。所以设置里是独立的一组：协议族 / Base URL / 模型 / Key，
Key 存钥匙串的独立账号 `imageprovider`。

**未做异步 job**（BFL / fal / Replicate 的 submit+poll）。原因：这几家的提交载荷、
轮询地址、状态枚举各不相同，没有一份实测过的规格，硬写等于猜。要做的话需要
`ImageJob` 表 + 前台轮询 + 冷启动续查，是独立的一块。

两个实现细节：
- `gpt-image-1` **不接受** `response_format`，请求体里不能出现它（有测试钉住）。
- Gemini 只返回文字而不返回图（模型判定不该画）时，要当成空结果报错，而不是当成成功。

```swift
public protocol ImageAdapter: Sendable {
    func generate(_ request: ImageRequest) -> AsyncThrowingStream<ImageJobEvent, Error>
}

public enum ImageJobEvent: Sendable {
    case submitted(jobID: String)
    case progress(Double?)
    case completed(ImageAttachmentRef)
    case failed(LlmFailure)
}
```

两种形态：

| 形态 | 厂商 | 实现 |
|---|---|---|
| 同步 | OpenAI `images/generations`（`b64_json`）、Gemini 图像模型（`inlineData`） | 一次请求，直接落盘 |
| 异步 | BFL FLUX（`polling_url`）、fal、Replicate | `ImageJob` 表 + 前台轮询 + 冷启动续查 |

落盘：内容寻址（sha256 分桶）；DB 存 `ImageAttachmentRef`（mediaType / bytes / width / height / originalDimensions），与 DSH 的 attachment 结构一致。

---

## 12. 存储（SQLite，零依赖）

> **偏离记录**：原计划用 GRDB。实测时 GitHub 拉取依赖失败（HTTP/2 framing + 连接超时），
> 且本项目只需 prepare/bind/step 三个动作。改为直接用系统 `libsqlite3`，
> 代价是迁移与查询要手写（约 300 行），收益是**构建完全离线、无第三方依赖**。
> FTS5 需要时再单独评估（系统 SQLite 通常已编译进去）。

```sql
CREATE TABLE session (
  id TEXT PRIMARY KEY, title TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL,
  parent_id TEXT, forked_at_seq INTEGER,
  provider TEXT, model TEXT, system_prompt TEXT,
  archived INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE event (
  session_id TEXT NOT NULL, seq INTEGER NOT NULL,
  time REAL NOT NULL, type TEXT NOT NULL,
  payload BLOB NOT NULL,          -- JSON
  surface_op TEXT,                -- NULL | 'append' | 'replace:start:end'
  PRIMARY KEY (session_id, seq)
);

-- 投影：只读加速层，可由 event 重建
CREATE TABLE surface_node (
  session_id TEXT NOT NULL, seq INTEGER NOT NULL,
  role TEXT NOT NULL, blocks BLOB NOT NULL,
  token_estimate INTEGER, active INTEGER NOT NULL DEFAULT 1,
  PRIMARY KEY (session_id, seq)
);

CREATE VIRTUAL TABLE message_fts USING fts5(body, session_id UNINDEXED, seq UNINDEXED, tokenize='unicode61');

CREATE TABLE attachment (
  id TEXT PRIMARY KEY, media_type TEXT NOT NULL, bytes INTEGER NOT NULL,
  width INTEGER, height INTEGER, path TEXT NOT NULL, created_at REAL NOT NULL
);

CREATE TABLE provider_profile (
  id TEXT PRIMARY KEY, family TEXT NOT NULL, base_url TEXT,
  auth BLOB, capabilities BLOB, models BLOB, pricing BLOB,
  sort INTEGER, enabled INTEGER NOT NULL DEFAULT 1
);

CREATE TABLE usage_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT, turn INTEGER, step INTEGER,
  provider TEXT, model TEXT, purpose TEXT, usage BLOB, at REAL NOT NULL
);

CREATE TABLE image_job (
  id TEXT PRIMARY KEY, provider TEXT, state TEXT, request BLOB,
  outputs BLOB, updated_at REAL NOT NULL
);

CREATE TABLE search_cache (
  query_hash TEXT PRIMARY KEY, result BLOB, fetched_at REAL NOT NULL
);

-- Skill：文件才是真相，库只是索引缓存（可随时重建）
CREATE TABLE skill_index (
  name TEXT PRIMARY KEY,            -- kebab-case
  description TEXT NOT NULL, when_to_use TEXT,
  invocation TEXT NOT NULL,         -- "always,auto,manual"
  source TEXT NOT NULL,             -- bundled / user / imported
  path TEXT, body_sha256 TEXT, token_estimate INTEGER,
  updated_at REAL NOT NULL
);

-- 会话级激活决策，避免每轮重复路由
CREATE TABLE session_skill (
  session_id TEXT NOT NULL, name TEXT NOT NULL,
  mode TEXT NOT NULL,               -- always / manual / auto
  routed_at REAL, PRIMARY KEY (session_id, name)
);
```

- 写入策略：流式期间只在内存累积 draft；`assistant/message` 一次性写入（含 usage），避免高频写。
- 一致性：`surface_node` 与 `event` 同事务写；启动时若检测到不一致，从 event 重建。
- iCloud 同步：自用阶段不做；表结构不阻挠（主键均为 UUID/文本）。

---

## 13. 错误与重试

```swift
public struct RetryPolicy: Sendable {
    public enum Mode: Sendable { case normal(maxRetries: Int), always }
    public var mode: Mode
    public var retryableCodes: Set<LlmErrorCode>
    public var initialDelayMs: Int      // 500
    public var maxDelayMs: Int          // 10_000
    public var jitterRatio: Double      // 0.1
}
```

- 可重试：`rateLimit`、`server`、`network`、`emptyResponse`、`decodeFailed`。
- 不可重试：`auth`、`invalidCredential`、`quota`、`contextWindowExceeded`、`contentFilter`、`unsupportedCapability`。
- `providerRetryAfterMs` 存在时**覆盖**本地退避。
- 重试对用户可见（"第 2 次重试，12s 后"），可手动取消。
- 流已吐出首个 token 后**不重试**（避免重复内容），只在未出 token 时重连。

---

## 14. 流式渲染

- `LlmRuntime.stream` → `AsyncThrowingStream` → ViewModel 合并到 `draft: AssistantDraft`。
- **视觉基线：iMessage**（气泡无尾巴、连续圆角、成组间距、短对话贴底、材质输入条）。
  本机 Xcode 16.4 只带 iOS 18.5 SDK，**无法使用 iOS 26/27 的 Liquid Glass 组件**，
  暂用 iOS 18 等效手段：`.ultraThinMaterial`、`.defaultScrollAnchor(.bottom)`、
  弹簧动画、`Color.primary.opacity(0.08)` 的自适应气泡底色。升级 SDK 后可再对齐。
- 刷新节流：每 33ms 提交一次 UI 更新（约 30fps），用 `AsyncStream(bufferingPolicy: .bufferingNewest(1))` 做合并。
- **输入条分两层**：上面是输入行（skill 气泡 + 文本框 + 发送），下面是模式行（联网搜索 / 生成图片两个药丸开关）。
- **两个模式互斥**：开一个自动关另一个。由 `ChatViewModel` 保证，不靠界面禁用——
  否则"边检索边画图"这种无意义状态迟早会从某个入口漏出来。
- Markdown：块级解析缓存；只重解析"最后一个未闭合块"，已完成块直接复用已渲染视图。
- 思维链：单独折叠区，默认收起，显示"已思考 12s · 1,842 tokens"。
- 滚动锚定：用户未上滑时自动吸底；一旦上滑则固定位置，并显示"回到最新"按钮。
- 无障碍：动态字体；VoiceOver 仅在生成结束播报整段，不逐 token。

---

## 15. 工程组织

- 单 Xcode 工程 + 4 个本地 SPM 包：`CoreKit`、`LLMKit`、`WebSeamKit`、`StorageKit`（便于单测与编译隔离）。
- 注意：**不要叫 `WebKit`**，会与 Apple 的 WebKit framework 模块名冲突。
- 现状：`igent.xcodeproj`（objectVersion 77 + 文件系统同步组，**新增文件无需改工程文件**）+ `Packages/CoreKit` + `Packages/LLMKit` 已就位，模拟器可运行。
- 构建：`xcodebuild -project igent.xcodeproj -scheme igent -destination 'platform=iOS Simulator,name=iPhone 16' build`
- 单测：`cd Packages/CoreKit && swift test`
- 工程由 `scripts/gen_xcodeproj.py` 一次性生成；**之后请在 Xcode 里编辑，不要重跑该脚本**（会覆盖）。
- 依赖：**目前零第三方依赖**（SQLite 走系统库）。后续按需引入 swift-markdown、Splash、SwiftMath、SwiftSoup。
- 测试：
  - 每个适配器一组 golden fixture（`.json` 请求体 + `.sse` 原始流），断言 `[StreamChunk]` 与最终 `[ContentBlock]`。
  - `SSEDecoder` 单独测：跨 chunk 半截 UTF-8、`\r\n`、多行 data、`[DONE]`、空帧。
  - `BlockAssembler` 性质测试：任意 chunk 序列 → 结果与"全量拼接后一次解析"一致。
  - `SurfaceProjection` 测试：append/replace 序列 → 净消息列表。
- CI：`xcodebuild test`（本地 git hook 即可，自用不必上云）。

---

## 16. 分阶段计划（自用版，约 8 周）

| 阶段 | 工期 | 交付 | 验收 |
|---|---|---|---|
| **P0 词汇与传输** | 3–4 天 | `CoreKit` 词汇 + `SSEDecoder` + `BlockAssembler` + `OpenAICompatibleAdapter`、`AnthropicAdapter` | 两个 fixture 回放出相同 `[ContentBlock]`；异常流不崩 |
| **P1 能聊** | 1.5 周 | App 骨架、SQLite 事件日志、流式渲染、Provider 设置、Keychain、模型发现 | OpenAI 兼容 + Anthropic 各接一个真实 Key 连续对话 20 轮无异常 |
| **P2 四族齐** | 1 周 | Gemini、Responses、Azure；思维链渲染；请求检查器；错误/重试 | 同一段对话在 4 家都能流式、取消、报错可读 |
| **P3 图片** | 1 周 | 图片输入（下采样/EXIF/HEIC）、三家视觉映射、图像生成（同步+异步 job） | 一张照片在 3 家都被正确描述；异步任务杀进程后能续 |
| **P4 联网** | 1 周 | Web seam、原生 grounding 三家、自建管线、引用 UI、来源预览 | 无原生检索的模型也能给出可点击的 `[n]` 引用 |
| **P5 Skill** | 3–4 天 | frontmatter 解析、文件 provider、`Documents/Skills/` 外编辑、三层激活、chip 与注入展示 | 手写一个 skill 放进 Documents，用 `#` 与自动两种方式都能激活；**把 DSH 的 skill 目录整段拷进来，一个字不改也能用** |
| **P6 会话管理** | 1 周 | 压缩、TokenMeter、成本、自动标题、搜索、导出、分支/重生成 | 50 轮长会话触发压缩后仍能正确追问 |
| **P7 打磨** | 3–5 天 | iPad 布局、键盘、快捷指令、暗色、iCloud 备份（可选） | 日常自用替换掉现用客户端 |

**关键路径**：P0 的 `StreamChunk` 契约和 `BlockAssembler` 一旦定错，后面阶段全部返工。建议 P0 先写 fixture 再写适配器（测试先行）。

**进度**（2026-11-20）：功能全部落地 + 自动压缩 + DeepSeek 两套联网 + 检索规划（模型决定搜不搜/搜什么，非工具调用）。**264 单测**，六个包全绿。未做：图片异步 job、真实 Key 联调。

**P5 排在 P6 之前**：skill 依赖 `context/message` 与 surface 替换，这两样已在 P1 就位；而压缩（P6）需要把 skill 正文标记为 `ephemeral`，先有 skill 才好验证压缩是否正确丢弃。

---

## 17. 风险与对策

| 风险 | 对策 |
|---|---|
| 厂商改接口 | fixture 回归；Profile 声明式，改能力/地址不用发版 |
| 流式解析边界（半截 UTF-8/JSON） | `SSEDecoder` 用 `[UInt8]` 缓冲，攒到 `\n\n` 再解码，绝不对半截字节 `String(decoding:)` |
| 中断丢内容 | `interruptedBlocks()` + `interrupted: true`；草稿内存态 + 首 token 即开始计时 |
| 上下文爆炸 | `pressure` 预估 + 自动压缩 + 单轮 maxTokens 上限 |
| 多厂商参数错配 | `Capabilities` 驱动 UI 与序列化；`extras` 逃生口兜底 |
| 事件日志膨胀 | 只存终态消息 + usage；raw SSE 只进 2MB 环形缓冲（不落库） |
| 常驻 skill 指令互相打架 | 注入前做粗检（同类"必须/不要"句式冲突），UI 提示收敛；常驻数量限制 3 个以内 |
| skill 正文吃掉上下文 | 激活时显示 token 估算；超过预算的 skill 强制 `include` 白名单，不允许整目录内联 |
| 自用无审核 → 无质量闸门 | P1 起每天真实使用，问题立刻暴露 |

---

## 18. 下一步（按顺序）

1. 定 `StreamChunk` / `ContentBlock` / `SessionEvent` 三份 Swift 定义（P0 第一步，之后基本冻结）。
2. ~~建 Xcode 工程 + 4 个 SPM 包骨架，接 GRDB 与第一个空迁移。~~（已完成，改用系统 SQLite）
3. 写 `SSEDecoder` + 两个 fixture，跑通 OpenAI 兼容与 Anthropic。
4. 接 SwiftUI 最小聊天界面，真实 Key 跑通流式。
5. 加 skill：先只做 `always` + `manual` 两层（不写路由器），验证注入链路正确；`auto` 路由后补。
6. 之后按 P2→P7 推进。

---

## 19. 参考实现：dshgo 与可选桥接

### 19.1 dshgo 是什么（不是自包含 App）

| 仓库 | 形态 |
|---|---|
| `xiazhi88/dshgo` ★65 | Android App + PC 端代理插件。插件把 `dsh web` 从 `127.0.0.1:3080` 经 `:3081` 转发到局域网，改写 Host/Origin 绕开栅栏 |
| `just-a-FA-for-name/DSHgo` ★261 | APK 内置 Tailscale 内核 + PC 端 dsh 插件，开包即用 |
| `Asukaleo-aa/dshgo-harmony` ★8 | 前者的鸿蒙移植（ArkTS/ArkUI + ArkWeb） |

共同点：**手机上跑的是客户端，智能在电脑上**。它们解决的是"把 Mac 上的 DSH 搬到手机"，不是"在手机上做一个 AI App"。

但 `xiazhi88/dshgo` 的 `android/docs/PROTOCOL.md` 是一份真机实测过的协议文档，价值很高。

### 19.2 为什么它对本方案几乎"免费"

DSH 的 API 词汇和 igent 的 Core 词汇本来就是同一套，所以桥接不需要语义翻译：

| DSH RPC | igent |
|---|---|
| `POST /api/session/list` | 会话列表 |
| `session/follow` + `assistantStream:true` | `StreamChunk` 流（同 block 语义） |
| `session/page` → `records[].event{seq,type,data,surfaceOp}` | `SessionRecord` / `SurfaceOp` |
| `session/prompt` `{requestId,sessionId,mode,content}` | `TurnOrchestrator.send()` |
| `$events`（`api-session/*`、`approval/request`…） | 会话列表实时刷新 |
| `tokenUsage{uncachedInputTokens,cacheReadTokens,cacheWriteTokens}` | `TokenUsage`（字段名一致） |
| `contextBreakdown{systemTokens,toolsTokens,messageTokens}` | `RequestMeasurement.breakdown` |

也就是说 `DSHBridgeAdapter` 是**第 5 个适配器**，不是第二套架构。

### 19.3 但不作为主线

| 理由 | 说明 |
|---|---|
| 图片生成 | DSH 没有这个能力，纯客户端模式做不到需求第三条 |
| 工具会回来 | 桥接即获得 DSH 全部工具，"去掉工具调用"在桥接模式下无法成立 |
| Mac 必须开机 | 出门、睡眠、断网即不可用 |
| 版本耦合 | `session/list` 与 `/api/remote.mux` 需 DSH ≥ `0.1.2-alpha.2`；cookie 30 天且绑定 `dsh web` 进程，重启即失效 |
| 部署成本 | 必须跑 PC 代理（Host/Origin 栅栏 + launch token + 两个 polyfill） |

### 19.4 采纳的四件事

1. **skill 格式与 DSH 完全兼容**（硬指标）：`name` / `description` / `whenToUse` 一字不改，`~/.dsh/skills`、`~/.agents/skills` 里的内容拷进 `Documents/Skills/` 即可用。
2. **`StreamChunk` 载体无关**：直连走 SSE，桥接走 WS `item` 帧，归一到同一契约（见 §4.3 第 6 条）。
3. **用法字段命名对齐 DSH**：`uncachedInputTokens` / `cacheReadTokens` / `cacheWriteTokens`，迁移与对比零成本。
4. **移动端经验**：连接状态徽章、指数退避重连、流式转发不重建视图、分块可续传上传。

### 19.5 不抄

- **内置 Tailscale**：iOS 需 NetworkExtension + VPN 描述文件，自用也麻烦；真要异地访问，系统级 Tailscale 更合适。
- **WebView 套壳 SPA**：dshgo 这么做是为了复用 DSH 前端；igent 的流式渲染必须原生，WebView 会让长文滚动与键盘交互变糟。
- **绕 `/api` 栅栏**：那是"电脑当服务器"的场景，igent 不需要。

### 19.6 桥接：已排除

"完全本地"是硬约束，因此不做 `DSHBridgeAdapter`。上面 §19.2 的映射表保留，只作为**词汇对齐的证据**——它证明了 Core 词汇与线上协议同构，将来若要对接别的载体（自建端点协议、WebSocket）成本同样很低。

代价说清楚：放弃桥接 = 放弃"Mac 上已配好的厂商与 skill 自动同步到手机"。替代方案是手工把 `~/.dsh/skills` 里的目录拷进 `Documents/Skills/`，一次性的，可接受。

---

## 附录 A：与 DSH 的一一对应

```
dsh-llm/types.ts        → Core/Vocabulary/{Content,Chunk,Usage,Failure,Options}.swift
dsh-llm/assembler.ts    → Core/Assembler/BlockAssembler.swift
dsh-llm/index.ts        → LLM/LlmRuntime.swift + LLM/LlmAdapter.swift
dsh-llm/error.ts        → Core/Vocabulary/LlmErrorCode.swift
dsh-llm/retry-policy.ts → LLM/RetryPolicy.swift
dsh-session/types.ts    → Core/Session/{SessionEvent,SurfaceOp,SessionStore}.swift
dsh-agent-loop          → Core/Orchestrator/TurnOrchestrator.swift（去掉 dispatch/tools）
dsh-compaction          → Core/Compaction/CompactionService.swift
dsh-token-meter         → Core/TokenMeter/TokenMeter.swift
dsh-web/types.ts        → Web/Seam/{Search,Fetch}.swift
dsh-attachment/types.ts → Core/Vocabulary/ImageAttachmentRef.swift
dsh-skill               → Core/Skills/{SkillRegistry,SkillSummary,SkillDefinition}.swift
dsh-skill-filesystem    → Core/Skills/FileSystemSkillProvider.swift
dsh-tool-skill (catalog)→ Core/Skills/SkillRenderer.swift（只保留 <available_skills> 发布，删掉 loader 工具）
dsh-llm-deepseek        → LLM/Adapters/OpenAICompatible/（方言特化）
```
