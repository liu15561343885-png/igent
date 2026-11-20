# igent — 工作约定

## 仓库

- 远程：`https://github.com/liu15561343885-png/igent.git`
- 分支：`main`
- **每一次代码改动都必须提交并推送到远程。** 不允许只在本地留改动。

## 每次改动后的固定流程

```bash
./scripts/sync.sh "提交信息"
```

等价于：

```bash
git add -A
git commit -m "..."
git pull --rebase --autostash origin main
git push origin main
```

要求：

1. 一次逻辑改动一个提交，提交信息用中文、动词开头（`添加` / `修复` / `重构` / `调整`）。
2. 推送前若有冲突，先 `rebase` 解决，不要 `merge` 出无谓的合并提交。
3. 如果推送因认证失败，**不要伪造成功**——报告真实错误并停下。

## 禁止入库

- 任何 API Key、令牌、证书（`.env`、`*.p12`、`Secrets.swift`、`Local.xcconfig` 已在 `.gitignore`）
- `DerivedData/`、`build/`、`xcuserdata/`
- 运行时数据库与用户数据

## 代码约定

- Swift 6 严格并发；跨 actor 的值必须 `Sendable`。
- 厂商差异只能出现在 `LLM/Adapters/` 内，`Core/` 不得出现任何厂商字段名。
- 新增厂商优先加 `ProviderProfile` 数据，不加代码。
- 每个适配器改动必须同时补/更新对应的 golden fixture。

## 文档

- 方案与架构：`docs/PLAN.md`，是唯一事实来源；实现与文档不一致时，先改文档再改代码。
