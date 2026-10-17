# Jev WhatsApp 版架构

一次完整流程：从点击气泡到把回复填入输入框

```
点击气泡
  → 读取屏幕上的聊天内容       assistant/service/WhatsApp.kt、a11y/、core/whatsapp、core/stitch
  → 这是谁？（仅首次询问）      core/scene、assistant/Settings（按聊天记忆）
  → 分析                        core/engine/Analysis.kt（请求 Jev 两次）
  → 选择立场、补充细节          core/engine/Goal.kt
  → 起草两条回复                core/engine/Drafting.kt（聊天请求一次，失败时重试一次）
  → 检查并评分每条回复          core/engine/CandidateCheck.kt（请求 Jev）
  → 填入输入框                  core/session/Fill.kt、assistant/service
  （由用户决定是否发送）
```

`core/session/AssistantSession.kt` 是负责运行上述流程并生成面板所绘制
`PanelState` 的状态机。`core/` 下的代码都是不依赖 Android 类型的纯 Kotlin，
因此整个流程可以在 JVM 上使用脚本化的模型网关进行单元测试。

## 模块

| 模块 | 类型 | 依赖 | 职责 |
|---|---|---|---|
| `core` | Kotlin/JVM 库 | 无（不依赖第三方库） | 引擎、场景、会话、WhatsApp 适配器、消息拼接、模型网关、诊断 |
| `a11y` | Android 库 | `core` | 将无障碍节点收集为 `ScreenDump`；检测消息行是否仍在移动 |
| `assistant` | Android 应用 | `core`、`a11y` | 无障碍服务、气泡与面板（普通 View）、读取循环、填入回复、设置、密钥库、诊断日志 |
| `probe` | Android 应用 | `a11y` | 用于开发的 WhatsApp 屏幕记录工具；不申请 `INTERNET` 权限 |

## 读取聊天内容

- `a11y/NodeCollector` 将当前窗口转换为 `ScreenDump`（视图 ID、边界、文本、内容描述）。
- `core/whatsapp/WhatsAppAdapter` 判断页面类型（聊天、聊天列表、群聊），并将消息行解析为消息：根据气泡靠左或靠右识别发件人，读取文本、引用文本、媒体类型（照片、文档、语音消息、视频、贴纸、已删除消息）、日期分隔线和系统通知。它依赖 WhatsApp 的资源 ID；`fixtures/screendumps/whatsapp-2.26.38.73/` 中记录的屏幕固定了预期结构。
- `assistant/service/WhatsApp.kt` 逐屏向上滚动消息列表，等待消息行稳定（`a11y/RowStability`），并在读取 24 条消息、到达聊天开头、滚动 5 屏或等待 8 秒时停止。随后滚回底部。
- `core/stitch/Stitcher` 将相邻屏幕中重叠的消息拼接为一个有序列表并去重。它会对最近消息生成指纹，以检测读取过程中聊天内容是否发生变化。
- 如果通过消息上方的成员名称识别出群聊，系统会拒绝处理。

## 对话与场景

`core/engine/Conversation` 将读取到的消息拆分为最新一轮（自你上次发言以来对方发送的消息）和更早的上下文，并提取特征：简短回复、消息形态、美式或英式拼写、缩写，以及最新一轮是否只有文件。

用户选择一个场景（工作、恋爱、朋友、家庭、一般）和关系类型，并可在适用时标记“正在争执”。`core/scene/` 中的每个场景都定义：

- **行为**：Jev 针对最新一轮回答的是/否问题（例如“要求给出截止时间”“设定界限”“提到升级处理”）。
- **判断矩阵**：针对每种行为和关系，标记对话所处的位置（`ABOVE`、`AT`、`BELOW`、`RARE`、`CUE`、`DEPENDS`）及后续步骤。这五张矩阵均经过人工审核，并在 `core/src/test/resources/approved/matrix.tsv` 中逐格固定。
- **立场组**：根据检测结果提供可选立场；每种立场按关系设定必含内容、应避免内容、承诺和道歉程度（固定于 `approved/apology.tsv`）。

## 分析

`AnalysisEngine` 会并行向 OpenRouter 的决策接口发送两次 Jev 请求（默认模型为 `typesafe/jev-1.13`）：一次根据整段对话询问行为、语气及必须选择的问题；另一次只针对最新一轮和此前四条消息询问摩擦因素。回答以概率表示。阈值会将回答归类为“检测到”“不确定”或“未检测到”；如果重要回答不确定，就让用户选择，而不是替用户猜测。分析结果包括后续步骤、立场组、提示和面板通知。

## 目标

`GoalBuilder` 会把选定立场转换为 `Goal`：包括摘要、必含内容、应避免内容、承诺、道歉程度、微调开关和用户补充的细节。用户输入的每条细节都会单独成为必含内容，因此遗漏它的回复无法排在首位。

## 起草回复

`Drafting` 会请求起草模型（默认 `deepseek/deepseek-chat-v3.1`，使用 OpenRouter 聊天补全接口）以 JSON 格式生成两条回复。提示词包含作为数据传入的对话、关系、情境、目标和拼写偏好。解析器会防御性处理代码围栏、替代键名、截断的 JSON、循环等情况，并清理输出。

## 检查与评分

`CandidateChecks` 会针对每条回复询问 Jev：

- **硬性检查**：未获用户要求却新增承诺（`new_commitment`）、替他人作出承诺（`commits_others`）、超出目标所涵盖内容（`beyond_goal`、`beyond_clarification`）、采取相反立场、越过对方设定的界限、陈述无人提供的事实（`unsupported_fact`），以及违反目标中“应避免”的内容。任何一项都可阻止使用该回复。
- **仅要求确认的检查**：请用户在使用前检查是否承认了过错、是否与先前提供的日期/时间/金额矛盾，以及是否包含未说明过的表态。
- **G，目标完成度**：分为六级，从“相反或缺失”到“完全完成”。缺少任何必含内容时，G 最高为 3。
- **E，表达效果**：语气及其与关系的契合程度。

评分公式为 `S = 0.7 G + 0.3 E`，满分 5 分，显示一位小数。每条回复都会获得一个状态，并按以下顺序排列：可用、等待确认、需要编辑、未评分、失败、需要重写。只有通过资格检查、判断结果没有分歧，且领先下一条超过 0.2 分的回复才会标为“首选”。

## 每轮限制

`RunBudget` 将每轮限制为最多 17 次模型请求、最多等待 90 秒。失败的请求会使用完全相同的请求内容重试一次；身份验证错误不会重试。用户可以随时取消。

## 填入回复

`core/session/Fill.kt` 会判断是否允许填入：必须仍处于同一个聊天中（通过标题哈希确认），且只有在征求用户同意后才会替换输入框中已有的草稿。随后服务会设置 WhatsApp 输入框的文本。代码中不存在点击发送按钮或触发输入法回车发送消息的路径。

## 诊断

`core/diagnostics/Diagnostics` 会为每个步骤（读取、分析、目标、候选回复、错误、操作）生成一行 JSON，记录计数、概率、评分和耗时，但不会记录文本。`assistant/DiagnosticLog` 会在私有存储中保留最近 1000 行，并生成可分享的报告。详见[诊断与问题报告](docs/DIAGNOSTICS.zh-CN.md)。
