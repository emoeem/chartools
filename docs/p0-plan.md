# 工作流 #4 · P0 体验包 + 人味增强包（设计稿）

> 状态：待工作流 #3（dwfrun-590b63f8 → amend 后 dwfrun-36b344a9：SDK/APK/悬浮窗/持久化/桌面流）完成后启动。
> 启动前先核对 #3 的交付与遗留（APK 编译轮次、复核发现、settings_store 等文件名）。
> 本文是 #4 各子代理的执行规格：实现时以本文为准，先读现状再动手。
>
> 人味研究来源：BigDawnGhost/wenyi（译/润/审分离、术语闭环）；旧仓库 `cn/_reports/reply-naturalness-p0_report.md`
> 的 P1/P2 遗留清单；cn-humanizer / shuorenhua / qu-ai-wei 的中文 AI 腔特征（见文末参考链接）。

## ① 模型服务商预设（成本极低，隐私卖点）

- 新建 `app/lib/application/model_presets.dart`：
  `List<ModelPreset> {id, name, replyBaseUrl, judgeProtocolHint, needsKey, note}`
  内置四档：
  - `deepseek`（DeepSeek 官方，`https://api.deepseek.com`，判断协议自动 chat，需 key）
  - `ollama`（**本地离线**，`http://127.0.0.1:11434/v1`，无需 key，note 写明「完全离线，聊天内容不出本机」）
  - `openrouter`（`https://openrouter.ai/api/v1`，需 key）
  - `dashscope`（通义兼容模式，`https://dashscope.aliyuncs.com/compatible-mode/v1`，需 key）
- 设置页加「服务商」下拉：选中即回填地址并按需提示 key；手动改地址仍允许（预设只是起点，不锁死）。

## ② 首次运行引导

- 新建 `app/lib/ui/onboarding_page.dart`：三步（PageView + 指示器）
  1. 选场景（复用 `Scenarios.builtIns`，单选并记住）
  2. 选服务商预设 + 填 key（复用 ① 的下拉；可跳过 = 先用后配）
  3. 平台权限引导：Android → 引导开无障碍 + 悬浮窗权限（调既有通道）；Windows → 讲解粘贴分析流
- 完成写 `onboarded=true`（settings_store）；主入口检测未引导则先进引导页。

## ③ 上下文补充（分析前的一句话背景）

- `capture_page` 与 `desktop_assistant_page` 各加一个可选输入框「补充背景（如：今天是她生日）」。
- `CaptureSession` 增加 `extraContext` 字段；`_onSnapshot` 组装 `ChatContext(background: '用户补充：' + extra)` 传给 `judge`/`draftAndRank`（判断侧读 background，走 JevQuestions.BACKGROUND_NOTE 的既定语义）。
- 「换一组」保留 extraContext；清空输入框即移除。

## ④ 候选快速改写（refine UI 化）

- 每张候选卡加三个小按钮：`更短` / `更礼貌` / `换个说法`。
  指令映射：更短→「把这条改得更短，保留原意」；更礼貌→「把这条改得更礼貌委婉，不要卑微」；换个说法→「换一种说法，意思不变」。
- 走 `JevClient.refineReply(snapshot, relationship, original, instruction)`；成功后原位替换该卡文本（不重排序），busy 态只作用于该卡。
- 桌面流页面同样提供（同一份实现放 `CaptureSession`，两页复用）。

## ⑦ 采集应用黑名单（隐私信任）

- `settings_store` 增加 `blockedPackages`（持久化）；默认内置：`com.eg.android.AlipayGmobile`（支付宝）、`com.unionpay`（云闪付）、`com.android.bank` 前缀命中即拦（注释写明这是隐私底线清单，可在 UI 增删）。
- 通道 `configure` 增加 `blocked` 参数；Kotlin `CaptureService`：把现有 `BLOCKED_PKGS` 常量改为可配置集合，`isBlocked()` 先查黑名单再查白名单（黑名单优先——用户明确拉黑的包即使加了白名单也不采）。
- 采集页「采集范围」卡片增加黑名单区（FilterChip 列表，含「添加包名」输入框）。

## ⑥ 通道契约 fixture 测试（工程项）

- 新建 `packages/capture_android/test/fixtures/snapshot.json`：含全部字段的快照样例（title/note/provenance/messages/bubbleRects + overlay_action 事件样例）。
- Dart 侧：`capture_android_test.dart` 增加「fixture 解析」用例（逐字段断言）。
- Kotlin 侧：`android/src/test/kotlin/dev/chartools/capture/SnapshotJsonContractTest.kt` 读同一份 fixture（复制一份放 `android/src/test/resources/`，两份文件头部注明对方路径 + CI 增加 diff 步骤防漂移）。

## 门槛与收尾

- 门禁：`flutter analyze` + core/插件/app 三处测试 + `flutter build apk --debug`（Windows 构建若 VS 缺位照 #3 处理）。
- 独立复核：新 UI 的异步竞态（build 内不跑异步、dispose 清理）、黑名单优先级、refine 不重排序。
- 完成后更新 README 场景路线表与 docs/architecture.md。

---

# 人味增强包（#4 第二部分）

> 原 P1/P2 遗留（旧仓库 reply-naturalness 报告）+ wenyi 借鉴 + 去AI味项目思路。
> 本部分全部纯 Dart/UI，无新网络依赖。

## A1 禁令改正向示例

- `core/pipeline/reply_prompt.dart`：把 `registerBans`/部分 safetyBans 的纯禁令改写为「正向示范 + 反例对照」结构。
- **兼容锁**：`chat_copilot` 默认轮次的提示词输出必须与改前**逐字节一致**（同 #3 的场景兼容锁思路），改写仅在新增 `usePositiveExamples` 配置开启时生效（默认关，评测后再切默认）。

## A2 中文 AI 腔本地 linter

- 新建 `core/lib/src/pipeline/ai_flavor_linter.dart`：纯规则检测，零模型调用。特征清单（参照 cn-humanizer，取聊天域子集）：
  排比堆叠（连续 ≥3 个同构短句）、总结升华尾句（"总之/说到底"）、书面语高频词（"然而/因此/此外"在口语流里）、
  "不是…而是…"句式、句长方差过小（整组候选长度过度均匀）、每条都以问号结尾、emoji/语气词滥用。
- 输出 `FlavorHit {rule, evidence}` 列表；命中 ≥2 条的候选自动进 `refineReply` 重写（指令=命中规则的人话描述），重写失败保留原文并降权 0.1。
- 单测：每条规则一个正例/反例。

## A3 说话方式画像 few-shot

- 新建 `core/lib/src/persona_kb/style_profile.dart`：输入用户自己的历史消息（`side=='me'`），按「长度中位、口语密度」挑 3-5 条作为 `Note(type: style_sample)` 注入（`ReplyPrompt.knowledgeBlock` 的 `<user_style_examples>` 通道已就位，上限 3 条的现有规则保持）。
- app 侧：采集页加「学习我的说话方式」开关；桌面流从粘贴文本里的「我：」行学习。

## B7 「不用回」选项

- `CaptureSession`：`analysis.shouldReplyNow != null && < 0.5` 时，状态置 `canSkipReply=true`；采集页/悬浮窗显示「这条可以不回」按钮（点了就把本轮标记为已处理，不起草）。

## B8 「一条推荐+两条备选」

- 展示模式开关（settings_store）：默认主推 = 排序第一张大卡（含策略标签+概率），备选折叠为两行小字，点击展开。悬浮窗同构：主推大按钮 + 长按/展开看备选。

## 问题修复包（2026-11-11 项目自审发现，随 #4 一并修）

### F1 StrategyOrder 未接线（行为回归，high）

- 现状：`core/pipeline/strategy_order.dart` 已移植且带测试，但 **app 侧零调用**——旧仓库悬浮窗渲染前的「best_action→策略行提前」提升整条丢失，用户看到的是排序原始顺序。
- 修法：`CaptureSession` 在 `draftAndRank`/`regenerate` 拿到 ranked 后调
  `StrategyOrder.order(ranked, StrategyOrder.preferred(analysis.bestAction?.choice))`；桌面流同样接入。core 不动。

### F2 API Key 明文存储（隐私，high）

- 现状：`settings_store.dart` 把整个 `JevConfig`（含 replyKey/judgeKey）整包 JSON 明文存进 shared_preferences。旧仓库有 `ApiKeyVault`（Android Keystore 加密），未移植。
- 修法：app 加 `flutter_secure_storage`（Android 走 Keystore、Windows 走 DPAPI），key 字段单独存安全区，settings_store 其余字段不变；首版迁移：读到旧明文即搬入安全区并删除原值。

### F3 快照并发堆积（medium）

- 现状：`CaptureSession._onSnapshot` 忙时被新快照直接覆盖（busy 态反复重置），OCR 抖动时可能堆叠重复的 judge 调用。
- 修法：忙时只记 `_pending = snapshot`；当前轮结束后消化 pending（签名相同则丢弃）。
- **实现回写（2026-11-11，#4 落地，上两条「修法」规格原文已被有意取代）**：实际实现为「轮次 token」——每个快照进门 `_round` 先 +1 并记下手里的序号，每处 await 返回后只有仍是最新轮才写 state / 推悬浮窗，被更新快照（或确认动作）抢了先的旧轮次整体作废。取舍：**新内容立即响应优于排队**——排队方案会把 OCR 抖动期间的 N 屏快照串成一串延迟分析，用户看到的是迟到的旧建议；token 方案永远只呈现最新一屏，旧轮请求即使已完成也落地即弃，不会写回（无重复 judge 结果覆盖）。同签名重放由既有的签名去重拦（忙碌中不打断在途轮）。见 `app/lib/application/capture_session.dart` 的 `_round` / `_onSnapshot` / `_runRound` 注释。

# 外部审查借鉴（2026-11-11，用户提供的旧项目审查报告）

> 报告针对旧仓库 main 分支；逐条映射到 chartools-next 的现状与路线。

## 已被重写直接解决（不再列为任务）

| 报告建议 | chartools-next 现状 |
|---|---|
| 拆分 domain / ai / memory / android-capture / ui 五层，domain 不依赖 Android SDK | ✅ 已完成：`packages/core`（纯 Dart 零依赖 = domain+ai+memory）、`capture_android` 插件、`app` UI；core 模型无任何 Android 类型（旧 ChatModels.kt 的 android.graphics.Rect 问题不存在） |
| ChatCaptureService 1758 行职责拆解 | ✅ 已完成：829 行只采集产快照，判断/起草/复查编排在 Dart 侧（可测、双端共享） |
| 保留判断/生成分离、适配器三态契约、a11y/ocr/inject 来源标识 | ✅ 逐字移植，另增 `Provenance.desktop` |
| 保留 PersonaProfile「浏览信息 ≠ 提示词正文」分离原则 | 记为联系人档案（#5）的设计约束 |

## 吸收进 #4（在 P0 体验包 + 人味包 + 问题修复包之外新增）

- **G1 隐私预览**：发送前可查看「本轮将发送：最近 N 条消息 + 联系人备注 + X 条知识库笔记」（判/写两路分开列）。低成本、高信任价值，采集页与桌面流都加。

## 吸收进 #5

- **G2 适配器能力描述**：`AdapterCapabilities {canReadMessages, canIdentifySender, canReadHistory, canFillInput, allowsOcrFallback, verifiedAppVersion}`，首页按 App 展示能力而非笼统「已适配」；「未验证的新版本显示兼容性未知」。
- **G3 采集置信度门控**：快照附带置信度/不确定原因；`provenance==ocr` 且说话人不可归属 → 不自动分析或要求用户确认（简版可先在 UI 标注「来源不可靠」）。身份不明确宁可拒绝，不猜测。
- **G4 适配器验收规范**：窗口识别/消息解析/发送者识别/空窗口/OCR 兜底/输入框歧义/应用升级 七项检查表，统一各适配器测试结构。
- **G5 中文对话 Benchmark**（升级原 A5 评测集）：样本 schema
  `{conversation, relationship, expected_intent, expected_risk, expected_action, forbidden_commitments, forbidden_facts, acceptable_reply_traits}`；
  指标含意图/风险/关系/立场/事实一致性/自然度/边界遵守/排序一致性 + 延迟 P95、单轮费用；
  **高风险错判代价不对称**：漏判高风险 ≠ 误判普通对话，分开报告。
- **G6 Prompt injection 信任边界**：聊天内容/导入文档/技能一律视为不可信数据；技能只能影响表达不能改安全规则（safetyBans 永远在上的现有结构保持）；注入对抗测试用例。
- **G7 反馈学习结构化**（升级原 A6）：用户对候选标注「太正式/太热情/不够直接/事实对但表达不合适/不该承诺/这类先问我」→ 结构化个人表达偏好，可查可改可删，不覆盖人设与事实记忆。
- **G8 长期记忆「确认后入库」**：模型猜测不当事实保存，用户主动确认才进联系人/台账。

## 上架前清单（发布时）

targetSdk/compileSdk 36（Android 16，Google Play 2026-08-31 起）+ 专项回归无障碍/悬浮窗行为；分支保护 + CI 必绿才可合并（push 到 GitHub 后配置）。

## 报告的「不要做」清单（与我们方向一致，照单全收）

不做自动发送/自动点击；不为架构时髦改 Compose（我们走 Flutter 是既定决策）；cn/global 不强行合并（n/a）；BM25 先补检索评测再谈向量库；不把更多模型调用当更好质量。

## 参考项目（#5 设计期再读）

jev-chat/jev-chat-jarvis（上游，定期对照吸收修复）；shengjidaguai-china/goutoujunshi-jev-chat（事实/未知区分、停止条件）；aryankumarx/replyfy（悬浮窗交互、语气选择、限流重试）；kuafuai/andee（屏幕上下文抽象、权限能力管理）；Stijnman/emotional-messaging-helper（本地 Ollama + 关系记忆，佐证①的 Ollama 档）。

# 部署上线清单（#4 完成后执行，用户 2026-11-11 已拍板）

1. **发布策略**：直接更新 `emoeem/chartools` main —— 旧 Kotlin 代码以 `legacy` 分支保留（用 GitHub API 从当前 main SHA 建 legacy 分支，不依赖全量克隆），main 换成 chartools-new 的全新历史（单次初始提交，内容含 README 指引「旧版见 legacy 分支」）。
2. **认证**：`gh auth login` 设备码流程（用户在 github.com/login/device 输入一次性代码），随后 `gh auth setup-git` 配置推送凭据；git user.name/email 从 `gh api user` 读取。
3. **Release 管线**：新增 `.github/workflows/release.yml` —— push tag（如 v2.0.0-alpha.1）时构建 debug APK + Windows 产物并附到 GitHub Release。
4. **推送后验证**：Actions 两个 job 全绿；仓库页 README 渲染正确；Release 资产可下载。
5. 网络注意：推送走 github.com，本机连通性差时改用重试/分批推送；clone 旧仓库不必要（legacy 分支用 API 建）。

## 参考链接（子代理可 WebFetch）

- wenyi: https://github.com/BigDawnGhost/wenyi
- cn-humanizer: https://github.com/0xtresser/cn-humanizer
- shuorenhua: https://github.com/MrGeDiao/shuorenhua
- qu-ai-wei: https://github.com/LifelongLazyLearner/qu-ai-wei
- 旧仓库自然度报告: https://raw.githubusercontent.com/emoeem/chartools/HEAD/cn/_reports/reply-naturalness-p0_report.md

## #5 候选（本轮不做）

A4 润色路由、A5 评测集+盲评、A6 用户选择回灌、C9 用量/缓存统计、C10 会话 checkpoint、Windows 全局热键、联系人档案简版。
