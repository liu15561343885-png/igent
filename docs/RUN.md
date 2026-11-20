# 在真机上跑起来

> 面向：自己用，不涉及上架。全程不需要付费开发者账号。

## 一、签名（第一次会卡在这里）

1. 用 Xcode 打开仓库根目录的 `igent.xcodeproj`
2. 左侧选中项目 → TARGETS 里的 **igent** → **Signing & Capabilities**
3. 勾选 **Automatically manage signing**
4. **Team** 选你的 Apple ID（没有就 `Add an Account…`，免费账号即可）
5. 如果提示 Bundle Identifier 冲突，把 `local.igent` 改成唯一的，例如 `com.yourname.igent`

免费账号签出来的 App **7 天后会失效**，重新用 Xcode 跑一次即可。

## 二、安装

1. iPhone 用数据线连 Mac，解锁并「信任此电脑」
2. Xcode 顶部设备选择器选你的 iPhone（不是模拟器）
3. ⌘R 运行

第一次运行后，手机上会提示「不受信任的开发者」：

> 设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任

## 三、配置一个厂商

1. 打开 App →「添加厂商」
2. **协议族**：绝大多数厂商选「OpenAI 兼容」
3. **Base URL**：填到版本号为止，不要带 `/chat/completions`

| 厂商 | Base URL | 备注 |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | |
| DeepSeek | `https://api.deepseek.com/v1` | |
| Moonshot | `https://api.moonshot.cn/v1` | |
| 智谱 | `https://open.bigmodel.cn/api/paas/v4` | |
| 通义（兼容模式） | `https://dashscope.aliyuncs.com/compatible-mode/v1` | |
| OpenRouter | `https://openrouter.ai/api/v1` | |
| Anthropic | `https://api.anthropic.com/v1` | 协议族选 Anthropic |
| Gemini | `https://generativelanguage.googleapis.com/v1beta` | 协议族选 Gemini |
| Azure | `https://<资源名>.openai.azure.com` | 协议族选 OpenAI 兼容，模型填**部署名** |

4. 填 API Key
5. 回设置页 →「从厂商拉取模型列表」→ 点一个模型选中（拉不到就手打）

## 四、连不上时怎么查

**设置 → 请求记录**，点最近一条，能看到：

- 实际请求的完整 URL（少 `/v1`、路径拼错一眼可见）
- 请求头（密钥已显示为 `••••`，只确认格式对不对）
- 请求体原文（模型名、system、消息结构）
- 厂商返回的原始响应（错误信息通常就在里面）

常见错误对照：

| 现象 | 大概率原因 |
|---|---|
| `auth` | 密钥错、或该厂商要求的前缀不是 `Bearer` |
| `invalidCredential` + 400 | Base URL 少一段，或模型名不存在 |
| `network` | 端点域名写错，或网络需要代理 |
| 一直"正在输入"后失败 | 响应不是 SSE，可能打到了错误的路径 |
| `contextWindowExceeded` | 会话太长，需要压缩（后续版本） |

## 五、调试用的启动参数

在 Xcode 的 Scheme → Run → Arguments 里加：

| 参数 | 作用 |
|---|---|
| `-seedDemoConversation` | 灌一段示例对话，改界面时不用真的聊 |
| `-openSettings` | 启动直接打开设置页 |

两个参数都只在 `DEBUG` 构建里生效。

## 六、数据在哪

- 数据库：App 沙盒 `Library/Application Support/igent.sqlite`
- 密钥：钥匙串，service = `local.igent`，account = `provider.<id>`
- 删 App 会一起删掉；密钥因为存在钥匙串，可能需要手动清理（重置模拟器可清空）
