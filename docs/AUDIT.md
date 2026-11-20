# 代码审计（2026-11-20）

范围：`Packages/`（5 个包，约 1.4 万行）+ `App/igent`（19 个文件，约 3.7 千行）+ 测试（约 6.9 千行）。
方法：全文人工审阅关键路径 + 三个并行的专项审计（CoreKit/StorageKit、LLMKit 适配器、App 层与安全）+ 干净构建看告警。

结论前置：**没有发现密钥泄漏、SQL 注入、Sendable 违规**；但发现 **2 个会丢数据的缺陷、3 个会让功能静默失效的缺陷**。以下全部已修复并配了回归测试。

---

## 一、已修复（按严重度）

### C1 附件清理会删光所有图片（数据丢失）
`AttachmentStore.prune` 用 `url.path.replacingOccurrences(of: root.path + "/", with: "")` 求相对路径。
`FileManager.enumerator(at:)` 会规范化符号链接（iOS 上是 `/var` → `/private/var`），而 `root.path` 不会——
于是 root 前缀在子路径里根本对不上，算出的"相对路径"是垃圾串，`referenced` 永远不含它，**每个文件都被判为孤儿**。

叠加两个放大器：
- `bootstrap()` 无条件调用清理；数据库打开失败走内存兜底时 `referencedAttachmentPaths()` 返回**空集**，
  等于把所有历史图片删光。
- 选图是"先落盘、发送时才入事件"，清理跑在中间会把还没发送的图片删掉。

修复：规范化 root + 前缀不匹配就跳过（宁可不删）、`bootError != nil` 时不清理、10 分钟宽限期。
回归测试：`testPruneKeepsReferencedFiles`。

### C2 压缩区间倒置，第二次压缩静默失效
`Surface.build` 把 replace 节点存成**新事件的 seq**，`messageSeqs` 因此非单调（测试里甚至断言成 `[3, 2]`）。
`CompactionService` 取 `prefix(n).first/.last` 作为 `replace(start:end)`，第二次压缩就得到 `start > end`，
`removeAll { seq >= start && seq <= end }` 什么都不删，摘要被插到最前面——**摘要越堆越多，上下文一点没瘦**，
界面还显示"已压缩"。

修复：替换节点承接区间起点 seq（保持单调）+ 压缩服务用 `min/max` 防御。
回归测试 `testSecondCompactionShadowsTheFirstSummary`——已验证它在旧代码下失败、新代码下通过。

### H1 「停止」之后整个输入条卡死
`stop()` 取消了**消费端**任务，而复位 `isStreaming` 的唯一位置在 `consume(.finished)`。
消费端被取消就再也收不到 `.finished`，`isStreaming` 永远为 true，发送按钮从此失效。
修复：只取消生产端（编排器在取消时会落库部分内容并发 `.finished`），另加 3 秒兜底与回合序号防止误清新回合。

### H2 切换会话后「停止」静默失效
编排器只有一个 `activeTask`，切到 B 再发消息会覆盖它；A 结束时 `defer` 又把槽位清成 nil。
修复：按会话维护 `activeTasks`/`activeTokens`，`cancel(in:)` 定向取消，收尾时校验令牌。

### H3 空响应被当成正常结束
四个解析器在 `finish()` 里一律 `finishReason ?? .stop`。代理返回 HTML、连接被截断、或服务端没按 SSE 回时，
用户看到的是"发出去了、没有任何回复、也没有报错"。
修复：记录是否产出过内容，无结束标记且无内容时归为 `.emptyResponse`（有内容但无结束标记则保持宽容）。

### H4 4xx 分类用过宽子串，且会触发不可逆操作
`body.contains("context")` 就判定为超窗——而超窗会**触发压缩**，压缩会永久遮蔽历史。
一个被拒的 `context` 字段就能压掉真实对话。其余 4xx 一律归为"密钥无效"，把参数错误显示成密钥问题。
修复：只认厂商的明确措辞（`context_length_exceeded`、`prompt is too long` 等），新增 `.invalidRequest` 类别。

### M1 重新压缩的持久化残留
`usage_log` 没有外键、删除会话时不清理 → 孤儿行只增不减。修复：删除时连带清理；补 `busy_timeout`、会话索引（v2 迁移）。

### M2 附件被跨会话误删（内容寻址共享）
删除会话无法判断"这个文件还有没有人用"。修复：按引用集合反向清理（`referencedAttachmentPaths` + `prune`）。

### M3 数据库打开失败时二次关闭（use-after-free）
`init` 抛错路径 `sqlite3_close(handle)` 后没有置空，Swift 仍会跑 `deinit` → 二次 close。修复：置空后抛出。

### M4 文档解析失败把用户输入一起丢掉
发送时先清空草稿/图片/附件，OCR 失败只恢复了附件。修复：失败时把草稿与图片一并还回去。

### M5 图像生成失败留下"看不见的消息"
提示词已落库但界面没刷新，用户重打会多出一条。修复：失败路径 `reload()`。

### M6 自动压缩关闭状态在重启后失效
策略只在 `didSet` 里应用，`init` 赋默认值不触发观察者。修复：`bootstrap()` 里显式 `setPolicy`。

### M7 首次引导永远看不到
`bootstrap` 无条件建会话，`RootView` 的"无会话且无厂商"条件永远不成立。修复：无厂商时不建会话。

### M8 检索正文可闭合证据块（提示注入）
`sanitize` 写了但从未被调用，`render` 直接用原始 digest。修复：接上，并补测试。

### M9 请求日志可能记录密钥
`AuthStyle.queryKey` 把密钥拼进查询串，日志原样保存并显示在检查器里；自定义鉴权头（如 `x-auth-token`）也不在固定清单内。
修复：查询参数按名字脱敏、头部改成名字模式匹配。

---

## 二、未修复（有意留下，附理由）

| 项 | 位置 | 说明 |
|---|---|---|
| `try!` 两处 | `AppEnvironment.swift:97,108` | 附件根目录与内存库都建不出来时直接崩溃。是"最后一根稻草"路径，改成静默降级需要引入空实现，收益低于复杂度。**建议**：改成记录 `bootError` + 只读空库。 |
| Gemini 不合并同角色消息 | `GeminiRequestBuilder.swift:30` | 连续两条 user 会被 400 拒绝。当前主用 GPT，未触发；用 Gemini 前必须修（照抄 Anthropic 的 merge 循环）。 |
| 主线程做 Keychain 读取 | `ChatView.swift:261-271` | 每次 body 求值读 3 次钥匙串，流式时约 30 次/秒。功能正确，长会话滚动会掉帧。 |
| 规划/调研/标题的用量不入库 | `SearchPlanner` / `WebResearch` / `TitleService` | 成本统计偏低。 |
| 调研/OCR/生图不经请求日志 | `CapabilitySettings.swift:113` | 这些路径失败时检查器里看不到，与界面文案不符。 |
| 搜索/OCR 共用一个钥匙串条目 | `CapabilitySettings.swift:29` | 切到 Tavily/Brave 会把 DeepSeek 的 Key 发过去。 |
| 三个 `*Revision` 计数器无人读取 | `AppEnvironment.swift:50-55` | 写而不读，改设置后界面可能不刷新。 |
| Keychain 先删后加 | `Keychain.swift:28-40` | 添加失败会丢掉原 Key；设置页逐键写入。 |

---

## 三、文档与代码不一致（`docs/PLAN.md`）

| 文档 | 代码 |
|---|---|
| `send(_:) async` 入队即返回、`whenIdle()`、`StepPlan` | 直接返回 `AsyncStream<TurnUpdate>`，无队列 |
| `RetryPolicy` / 退避 / 用户可见重试 | 完全没有；`providerRetryAfterMs` 解析后无人使用 |
| schema 含 FTS5、surface_node、image_job… | 只有 4 张表 |
| "可展开查看压缩原文" | 只有一段 alert 文案 |
| "压缩仅手动" | 默认自动压缩，且是活的开关 |
| 4 个 SPM 包 | 5 个 |
| 284 单测 | 300 |

---

## 四、测试与覆盖

- 全量：**300 单测**，六个目标全绿。
- 干净构建：0 警告（修掉了 7 处 `try?` 未使用告警）。
- 本轮新增回归测试：附件清理保留引用文件、连续两次压缩、空响应、错误分类、日志脱敏、`invalidRequest` 分支。
- 仍无覆盖：Keychain（需真机）、迁移升级路径、真实网络。

## 五、方法上的教训

这一轮里我自己制造的两次事故都很典型：

1. **用字符串替换打补丁却不断言锚点**——`serverTools` 开关、文档卡片都因此"看起来加了、其实没生效"，编译仍然通过。现在所有补丁脚本必须 `assert` 锚点 + 事后 `grep` 验证。
2. **新增的清理逻辑没有"保留"方向的测试**——只测了"该删的删了"，没测"该留的留下了"，于是把全部图片删光的实现通过了测试。
   **破坏性操作必须双向测试**。
