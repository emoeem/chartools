# 诊断与问题报告

助手会在本机记录每轮各步骤的处理情况，方便问题报告说明故障发生的位置。该功能供开发调试和希望报告问题的用户使用。

## 记录内容

每个事件在应用私有存储中占一行 JSON（`files/diagnostics/journal.jsonl`），最多保留最新的 1000 行。数据结构为 `jev.diagnostics/1`；事件定义见 `core/.../diagnostics/Diagnostics.kt`。

| 事件 | 字段 |
|---|---|
| `round` | 轮次 ID、启动原因（`analyse`、`read_again`）、场景、关系、冲突 |
| `read` | 是否成功或失败原因（`not_conversation`、`unstable`、`unavailable`、`not_at_latest`、`chat_changed`）、消息数量、对方的新消息数量、无法读取的行数、屏幕数、较早消息是否来自 15 分钟缓存（`cached`）、停止读取的原因、发送者模式（`uouo…`）、耗时毫秒数 |
| `analysis` | 下一步、检测到及不确定的行为和概率、线索、缺失的答案、摩擦分布、语气、提供的立场组、耗时、请求次数和当前费用；或跳过/失败原因 |
| `goal` | 立场 ID、是否为自定义目标、目标版本、用户补充信息的长度、补充信息是否已检查、微调开关、必需项（仅模板文案；引用用户补充信息的条目会省略）、避免项数量 |
| `candidates` | 每条回复的标签、长度、状态、总分、带等级概率的 G 和 E、每项检查的概率和结果；起草及检查耗时、请求次数和费用 |
| `error` | 步骤、错误类型、HTTP 状态；仅当详细信息由 Jev 自己生成时才记录一句说明（没有 HTTP 状态，或状态为 200 但响应无法使用）。绝不记录服务提供方的错误文本，因为其中可能引用请求内容 |
| `chat_change` | 对方新消息数量（如可计算）；屏幕上是否已切换到其他聊天 |
| `crash` | 后台工作中发生的意外异常：异常类型及其在 Jev 代码中的抛出位置 |
| `action` | `identify`（是否为已知聊天）、`remember_scene`、`fill`（已填入、询问是否替换、因其他聊天或内容无法读取而拒绝）、`copy`（以及是否为后备操作）、`use anyway`、`read again`、`read further`、`retry`、`recheck`、`cancel`、`resume`（继续当前聊天、聊天已更新、切换到其他聊天）、`close` |

绝不记录：消息文本、联系人姓名、回复文本、用户输入的目标、API 密钥、聊天身份哈希。`AssistantSessionTest.diagnosticsCarryNoChatOrReplyText` 会对此进行检查。

## 用户如何报告问题

- 报告某一轮：在面板中点击“目标与分析”，然后点击“报告问题”。报告会标明该轮次。勾选“包含目标和回复内容”后，会加入目标和起草的回复（不含聊天内容）。每轮结束后该选项会重置。
- 报告最近记录：打开 Jev 应用 ›“诊断信息”›“分享报告”。

两种方式都会打开 Android 分享面板，并生成 Markdown 报告（版本、设置，以及 `jsonl` 代码块中的近期事件）。你可以将报告粘贴到 GitHub issue，并使用“Bug report (WhatsApp assistant)”模板。除非你主动分享，否则不会上传任何内容。你可以在设置中关闭或清除日志。

## 如何阅读报告

按 `round` 对事件分组。常见流程为 `round → read → analysis → goal → candidates → action`。排查时可参考：

- 聊天读取错误：查看 `read.senders` 和 `read.latestTurn`。
- 立场选项异常：查看 `analysis.detected`、`unsure`、`next`。
- 回复异常：查看 `goal.switches`（是否开启了微调）、`candidates.replies[].hard`（哪项检查拦截或标记了回复）。
- 响应慢或费用高：查看 `ms`、`draftMs`、`checkMs`、`requests`、`cost`。
- 填入失败：查看 `name=fill` 的 `action` 事件。
