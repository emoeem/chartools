# 回复自然度 P0：先判后写、关系优先级、n 感知策略契约、避谈键

日期：2026-10-22 ｜ 范围：`cn/`（com.jev.probe 2.0）｜ 结论：**P0 五项全部落地，单测 615 全绿、构建通过；真机验收待做（见 §6）**

---

## 1. 用户要的是什么

> 「目前的问题就是生成出来的语句很诡异啊，非常的不自然啊，建议去网上看看类似的项目，看看别人是怎么处理这个问题的。」

先做了诊断（用 `RoleplayFixtureTest` 的 `-Droleplay.in/out` 通道把生产提示词逐字导出来看，不是读代码猜），再去调研外部同类项目，最后按结论实施。诊断的完整过程和外部参考清单在上一轮对话里；这里只落与实施相关的根因。

## 2. 根因 → 修复对照

| # | 根因（导出的提示词里实锤） | 修复 |
|---|---|---|
| 1 | **首轮起草盲写**：判断与起草并行，`ReplyClient.draftOnly` 没有 judgment 参数、`JevClient.draftStream` 硬编码 `judgment = null`。判断只影响排序，不影响写出来的字。 | 服务层改「先判后写」：判断回来带着它起草；等满 2 秒盲写兜底。`DraftTrigger` 纯类承载触发语义。`draftOnly`/`draftStream` 全链路加 judgment 参数；「再给 2 条」也带 `lastJudgment`。 |
| 2 | **关系串把一切框成伴侣**：`DEFAULT_REL` = 「对方是我的伴侣；from=me 的是我发的…」逐字进每轮提示词；联系人自己的关系只在背景块出现，正文行仍打全局关系（两行打架）。 | 默认改中性「朋友」；新增 `ChatContext?.effectiveRelationship`，判断/起草/排序/复查/微调五条路统一「联系人 > 全局」；联系人有关系时「关系：」全提示词只出现一次。 |
| 3 | **固定三策略与一切打架**：任何 n 都要求 safe/forward/angle「各一个」——n=2 算术上不可满足；判断说「少说两句」时仍强迫一条「推进话题」。 | 策略契约抽成 `strategyRule(n, intensity)`：n=1/2/n≥3 各自成立；收着档把 forward 重定义为「温和确认」，标签不变（下游 `normalizeStrategies`/排序/卡片标签零改动）。system 与 user 两侧共用 `Intensity.resolve`。 |
| 4 | **硬边界一词两义**：`SafetyGate` 拿它拦「对方的消息」，提示词拿它约束「我的措辞」。日常卡「家人、工作」→ 朋友说「工作好累」整轮没候选；销售卡「稳赚、保证收益」→ 客户问「能稳赚吗」恰好掐掉最该回的一轮。 | 人设卡新增 `避谈` 键（只约束我方措辞、明确「对方提到照常回应」）；日常卡删误拦词、销售卡改避谈；网调卡家人/前任保持硬边界。设置页/知识库页提示、`PersonaStatus` 回显同步。 |
| 5 | **低置信度判断被当事实**：`judgmentBlock` 无视 confidence，拿不准的「局势轻松/偏紧」定性照样念给写手。 | confidence < 0.5 降级为「把握不大，按字面承接」，不给场景定性；chat 协议缺失 confidence（解析为 0.0）按「没说」处理，不算低置信度。 |

顺带的一项采样修正：删掉「avoid 非空 → 温度 +0.1」——跨轮 avoid 现在几乎每轮非空，等于全局偷偷调参；反重复由 avoid 文本与复查第 6 条承担。

## 3. 改了什么（逐文件）

**主代码**
| 文件 | 改动 |
|---|---|
| `core/Intensity.kt` | 新增 `resolve(mode, judgment)`；`intensityBlock` 改用它 |
| `core/Prefs.kt` | `DEFAULT_REL` → 「朋友」，注释说明为什么 |
| `core/kb/KbModels.kt` | 新增顶层扩展 `ChatContext?.effectiveRelationship(default)` |
| `jev/ReplyPrompt.kt` | `judgmentBlock` 低置信度降级（`LOW_CONFIDENCE=0.5`，0.0 视为未说）；`systemPrompt`/`draftSystemPrompt` 加 `intensity` 参数；新增 `strategyRule`；`draftUserPrompt` 的「关系：」行改为 `relationshipLine`（联系人有关系时不再重复全局关系） |
| `jev/ReplyClient.kt` | `draftOnly` 加 `judgment` 参数；`draftAsk` 统一档位解析并传给 system、温度回归 `prefs.replyTemperature`；`review` 的关系先过 `effectiveRelationship` |
| `jev/JevClient.kt` | `draftOnly`/`draftStream` 加 `judgment` 并透传（`draftStream` 原来硬编码 null） |
| `jev/ReplyReview.kt` | 注释钉住「调用方必须传 effectiveRelationship 的结果」的约定 |
| `capture/DraftTrigger.kt`（新） | 先判后写的触发器：fire 恰好一次、判断优先、盲写不带判断；`WAIT_MS=2000` |
| `capture/ChatCaptureService.kt` | runAnalysis 重排为「判断 → 触发起草 → 2 秒盲写兜底」；`rel` 四处改 `effectiveRelationship`；top-up 带 `lastJudgment`；新增 Trace `draft start judged=…` |
| `core/kb/PersonaCard.kt` | 新字段 `avoid` + 键别名（避谈/回避/avoid）+ `splitBoundaries` 复用 + `promptText` 渲染 + structured 判定包含 avoid |
| `core/kb/PersonaPresets.kt` | 日常卡删「硬边界：家人、工作」；销售卡「稳赚、保证收益」改避谈；类注释补两种边界的区别 |
| `core/kb/PersonaStatus.kt` | `line`/`short` 回显避谈 |
| `SettingsActivity.kt` | 关系描述标签与说明、人设键列表、`PERSONA_SKELETON` 补避谈 |
| `KnowledgeActivity.kt` | 联系人人设提示补避谈语义与关系优先级说明 |

**测试（603 → 615，+12）**
| 文件 | 用例 |
|---|---|
| `jev/ReplyPromptTest.kt` | +6：联系人关系压过全局（且「关系：」恰一次）/ 无联系人时全局恰一次 / 低置信度不给定性 / confidence 0.0 不算低 / n=2 两策略 / 收着档不令推进（含自然档逐字不变的对照） |
| `capture/DraftTriggerTest.kt`（新） | +3：判断先到带上判断且超时被挡 / 超时先盲写且迟到判断被丢 / error 判断按 null 传 |
| `core/kb/PersonaCardTest.kt` | +1：避谈是独立键、不进硬边界、不拦轮、单独一行也算结构化 |
| `core/kb/PersonaPresetsTest.kt` | +1：日常/销售不拦普通提及、销售避谈进提示词、网调家人仍拦；通用循环断言放宽（日常卡按设计无约束面） |
| `core/IntensityTest.kt` | +1：`resolve` 手选原样、自动映射 |

## 4. 验收

### 4.1 单测与构建（本机真实输出）

```
$ bash gradlew :app:testDebugUnitTest --console=plain
BUILD SUCCESSFUL
suites=72 tests=615 failures=0 errors=0 skipped=2     ← 改前 603

$ bash gradlew :app:assembleDebug --console=plain
BUILD SUCCESSFUL
app/build/outputs/apk/debug/app-debug.apk  34,962,307 字节
```

### 4.2 生产提示词导出（`RoleplayFixtureTest` 回放，判断 casual_chat 1/9、全局关系默认值）

user 提示词（改动后首轮起草实际发送的形状）：

```
判断结果（先按它读局势，再写回复）：
- 对方这条的真实意图：只是日常闲聊或打趣
- 紧张/危险程度：1/9
- 对方此刻需要的是：什么都不需要，别过度反应
- 现在最该做的是：少说两句，别扩大
- 局势轻松：保持同等轻松的语气，短句就好，不要沉重、不要突然深情、不要道歉。

关系：朋友

最近对话：
对方：王总那边方案我发过去了
我：好
对方：他说折扣再谈谈

请给出 3 条候选回复。
```

- 判断块在场（改动前首轮起草没有这段——`draftOnly` 塞不进 judgment）；
- `关系：` 恰好一次、是中性默认（改动前这里会是「对方是我的伴侣；from=me…」）；
- system 的自然档 n=3 策略契约逐字未变（`theDefaultRoundKeepsThePromptUnchanged` 兼容锁继续通过）。

### 4.3 对照：改动前同一通道导出的提示词

见上一轮诊断（`app/build/prompt_out2.json`）：无判断块 + 「关系：对方是我的伴侣；from=me 的是我发的，from=other 的是对方发的」。

## 5. 设计取舍（写下来免得被改回去）

- **2 秒盲写兜底而不是纯串行**：纯串行会把判断路由的 30 秒超时直接加到候选延迟上；2 秒上限保证「判断挂了候选照样来」，代价是盲写轮回到旧行为（有 Trace `draft start judged=false` 可查）。
- **收着档重定义 forward 而不是换策略标签**：safe/forward/angle 三个键贯穿 `normalizeStrategies`、`StrategyOrder`、卡片标签；引入新键的涟漪远大于收益。
- **自然档 n=3 契约逐字不动**：`theDefaultRoundKeepsThePromptUnchanged` 锁的是「自动+自然=没这个功能之前的提示词」，任何改写都要先解锁这条再谈。
- **confidence==0.0 视为未说**：`ChatJudge` 对缺失字段填 0.0；当作低置信度会让省略字段的 chat 模型每轮降级。
- **`ReplyReview.user` 不自己解析关系**：它没有 ctx 参数，约定由调用方传 effective 值——单一事实来源在 `effectiveRelationship` 一处。

## 6. 自验缺口（没验到的明说）

1. **真机没测**：先判后写的编排跑在 Android Handler 上，JVM 只钉了 `DraftTrigger` 语义；需要真机确认三件事——判断先回时 Trace `draft start judged=true`、判断路由断开时 2 秒后 `judged=false` 且候选照来、会话切换后迟到的触发不产生幽灵候选。
2. **无 API 密钥，实况 A/B 没跑**（`JEV_REPLY_KEY`/`DEEPSEEK_API_KEY`/`OPENROUTER_API_KEY` 均未设置）。建议跑法：同一批日常对话，改前/改后各跑一遍 `eval_roleplay.py` 式盲评；这次修复改的是「模型看到的事实」，预期「诡异」投诉的大头应消失，但文风类的 AI 腔不属于本轮。
3. **延迟变化未实测**：常见路径候选晚到约一个判断耗时（Jev ≈900ms；chat 协议判断最多多等 2 秒）。用户对速度敏感的话，2 秒可调（`DraftTrigger.WAIT_MS`）。
4. **旧安装的既有值不迁移**：设置过关系/存过旧人设卡的用户保持原样；只有「从未设置」的安装拿到新默认「朋友」。人设库里播种过的旧「日常/销售·跟单」卡**不会自动更新**（播种只在文件不存在时发生），要吃到避谈语义需要在设置页重新「恢复内置模板」或手改。

## 7. 后续（P1/P2，未做）

自动「我的说话方式」画像（从 `side=="me"` 的消息提取句长/标点/口头禅 + 1–2 条真实消息 few-shot，外部研究一致结论是「给样例比描述风格有效」）；技能正文/语气样例的预算与重排（注意 SKILL.md 的安全边界在文末，盲截会丢）；system 提示词从禁令清单改正向示例 + 中文 AI 腔 linter；日常场景评测集（20–30 条，覆盖朋友/同事/销售/暧昧）；候选展示改「一条推荐+备选」并允许「这条不用回」；记录用户实际填了哪条用于排序与画像。
