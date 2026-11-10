# 架构决策记录（ADR）

记录 chartools-next 相对旧仓库 `emoeem/chartools` 的关键决策。旧仓库冻结为参考实现，其 Kotlin 源码见 `_reference/chartools/cn/app/src/main/java/com/jev/probe/`。

## 1. 为什么是 Flutter，而不是继续 Kotlin

- 旧应用是 Android 专属（Kotlin + 传统 View），用户要求 PC + 手机可用。
- 目标平台定为 **Android + Windows**（iOS 系统层面禁止读其他 App 屏幕，产品形态需重设计，暂不纳入）。
- Flutter 一套代码出 Android/Windows，UI 生态成熟；符合「换一种语言重写」的诉求。
- 备选曾考虑 Kotlin Multiplatform（复用最大化但不换语言）、React Native（桌面成熟度弱）、Tauri v2（移动端较新）。

## 2. 移植边界：什么重写，什么保留

| 层 | 处置 | 理由 |
|---|---|---|
| 领域层（模型客户端/流水线/提示词/人设知识库/安全） | **Dart 重写**（`packages/core`） | 与平台无关，双端共享，可纯 Dart 测试 |
| 采集层 Android（无障碍/OCR/Xposed） | **Kotlin 原样进插件**（阶段 2） | 天然只能是 Kotlin，且已含安全加固；重写无收益 |
| 采集层 Windows（热键/剪贴板/UIA/OCR） | **dart:ffi 新写**（阶段 3） | 旧仓库没有对应物 |
| UI | **Flutter 重写**（`app/`） | 手机悬浮条 + 桌面侧边窗，双端自适应 |

## 3. 包结构

```
chartools-next/
├── app/                      Flutter 应用（ui / application / domain 三层）
├── packages/core/            纯 Dart 领域包，零第三方依赖
│   ├── src/models/           Msg / ChatSnapshot / Analysis / RankedReply
│   ├── src/jev_client/       HTTP+SSE 传输、题集、chat 协议归一化
│   ├── src/pipeline/         JudgeClient / ReplyClient / ReplyPrompt / JevClient 门面
│   ├── src/persona_kb/       PersonaCard / ChatContext / Ledger / StyleSource / TopicScope
│   ├── src/safety/           SafetyGate（起草前预检：阻断 / 谨慎 / 放行）
│   ├── src/scenarios/        场景模板（一套引擎 × 多场景）
│   └── src/config/           JevConfig（旧 Prefs 的无 Android 依赖子集）
├── packages/capture_android/ 阶段 2：封装旧 Kotlin 采集服务（已落地，见 §6）
├── packages/capture_windows/ 阶段 3：热键 + 剪贴板 + 选中文本（+ OCR）（未创建，见 §6.3）
└── docs/
```

Pub workspace（根 `pubspec.yaml`）聚合全部成员，共享锁文件；core 保持 `sdk: ^3.6.0` 零依赖。

## 4. 关键机制移植对照

| 机制 | 旧仓库 | chartools-next | 语义要点 |
|---|---|---|---|
| 传输 | OkHttp + okhttp-sse | `dart:io` HttpClient + 自解析 SSE | 3 次尝试；429/5xx/传输失败重试，其余 4xx 终止；流式永不重试 |
| 取消 | HttpScope + call.cancel() | HttpScope + `request.abort()` | 粘性取消：注册即检查 |
| 判断协议 | decisions（Jev/TypeSafe）+ chat（OpenAI 兼容） | 同 | chat 的 `response_format` 被拒（400/422）时去字段重试一次 |
| 富化降级 | JudgeRetry.shouldDropEnrichment | 同（400/404/413/415/422 丢弃 background/history 重试） | 未验证字段可降级、不可致命 |
| 缓存键 | ReplyCacheKey（14 分量 + 长度前缀防撞） | 同 | 任何分量变更必须改变键；测试逐分量变异 |
| 安全预检 | SafetyGate（词表 + 人设卡边界 + 安全词/黄灯） | 同 | 阻断抛 SafetyBlockedException，文案原样给用户 |
| 推进档位 | Intensity.AUTO→SOFT/NATURAL/FORWARD | 同 | system 策略契约与 user 档位块必须用同一解析结果 |
| 证据复查 | ReplyReview（fail-open，六条标准） | 同 | 复查只可能改好，不可能改坏或变少 |
| 场景扩展 | 无（硬编码聊天副驾） | **新增** ScenarioTemplate | chat_copilot 为默认，输出与无场景逐字节一致（兼容锁） |

## 5. 场景模板的注入规则

`ScenarioTemplate = {id, name, description, platforms, systemAddendum, userAddendum}`：

- `systemAddendum` 追加在默认 system prompt 末尾；
- `userAddendum` 插在 user prompt 最后一行「请给出 N 条候选回复。」之前；
- `id == 'chat_copilot'` 或 null 时，两段均为空串，提示词与没有场景功能之前**逐字节一致**——这是兼容锁，测试钉住。

首发 5 个场景见 `docs/scenarios.md`。

## 6. 阶段 2/3 落地记录

阶段 2（Android 采集层移植）与阶段 3（Windows 入口）实际落地的接缝与数据流。
场景与采集来源的对应关系见 `docs/scenarios.md`；落地状态对齐见 6.5。

### 6.1 采集服务接缝协议（Android）

无障碍服务与 Flutter 引擎是两个生命周期独立的组件，接缝按「谁后到，谁挂接」设计：

- **三条通道**：
  - `capture_android/snapshots`（EventChannel）：快照 JSON 流（`CaptureService.kt:54`）；
  - `capture_android/control`（MethodChannel）：configure / isRunning /
    openAccessibilitySettings / refill / manualOcr / showSuggestions /
    hideSuggestions（`CaptureService.kt:58`，处理入口 `handleControl` 在 756 行）;
  - `capture_android`（插件自有 MethodChannel）：canDrawOverlays /
    openOverlaySettings——悬浮窗权限的查/跳与采集服务是否启用无关，挂在插件
    通道（`CaptureAndroidPlugin.kt:29,48-68`）；control 由服务注册，服务未启用
    时整条不存在，所以不能复用。
- **挂接顺序**：插件 onAttachedToEngine 把 BinaryMessenger 存进
  `CaptureService.flutterMessenger` 并对已连接的服务实例调
  `attachEngineChannels`（热重启换 messenger 后重挂）；服务后连接时由服务取
  静态 messenger 自挂（`CaptureService.kt:157-164`、`CaptureAndroidPlugin.kt:33-34`）。
- **快照载荷**：JSON 字符串 `title/note/provenance/messages[{side,text}]/
  bubbleRects[…{left,top,right,bottom,side}]`（`snapshotJson`，
  `CaptureService.kt:675`）；服务端按 `signature()` 去重并保留最近一条
  （pending-latest），Dart 晚连接订阅时立即补发（`CaptureService.kt:138-150`）。
  原生侧 300ms 同包名防抖；快照为空且 `ocrFallback` 开启时走截屏 OCR 兜底。
- **职责切分**：原生只做「读窗口 → 出快照」与回填；判断/起草编排在 Dart 侧
  `CaptureSession`（app/lib/application/capture_session.dart）。旧
  ChatCaptureService 的 jev 分析、注入层、消息门控（NewMessageGate）、白名单
  不随迁（`CaptureService.kt:30-34`）。
- **回填语义**：refill 只填输入框（ACTION_SET_TEXT，剪贴板 PASTE 兜底），从不
  发送；找不到可写输入框返回 false，调用方退回剪贴板复制
  （`CaptureService.kt:44-45,796`）。
- **事件分流**：悬浮窗按钮事件与快照共用同一条 EventChannel（原生 eventSink
  单字段，Dart 侧只订阅一次、按事件里的 `type` 分流），事件形如
  `{type:'overlay_action', action, index}`（`emitOverlayAction`，
  `CaptureService.kt:729`；分流见 `capture_android.dart:61-82`）。
- **保活**：KeepAliveService 前台服务（specialUse）压住 MIUI/HyperOS 对无障碍
  进程的冻结（插件 AndroidManifest + `CaptureService.kt:867`）。

### 6.2 悬浮窗通道

- OverlayController 自旧仓库（1037 行）逐字移植，TYPE_APPLICATION_OVERLAY
  窗口，**只做展示层、不调模型**——候选由 Dart 经 control 通道 showSuggestions
  推入，载荷 `{list:[{text,strategy,prob}], title}`（`OverlayController.kt:45-53`
  移植说明、`CaptureService.kt:716` 载荷解析）。
- 「填入/复制」按钮经 onOverlayAction 交回 Dart；`CaptureSession` 用
  `_overlayCandidates`（最近一次推入的候选列表）解释事件里的下标：refill 成功
  → 收起悬浮窗（填入即收起），失败 → 退回剪贴板；copy → 写剪贴板
  （capture_session.dart:213-234）。
- 开关单一事实来源：`SettingsStore.overlayEnabled` 一份 ValueNotifier，设置页
  与采集页写、CaptureSession 读；关掉立即收起，打开等下一批建议落地再弹
  （capture_session.dart:88-91）。
- 权限：SYSTEM_ALERT_WINDOW 无运行时对话框——开关打开前先 canDrawOverlays
  查询，未授权引导去系统设置页（ACTION_MANAGE_OVERLAY_PERMISSION 按本应用
  包名直达），授权回来后用户再开一次（app/lib/ui/capture_page.dart:117-120）。

### 6.3 桌面粘贴流（Windows，阶段 3 首步）

- **入口互斥**：Android 显「采集助手」、Windows 显「粘贴分析」，同一时刻只出
  现一个（app/lib/main.dart:54-77 的 if / else if）。
- **流程**：粘贴文本 → `TranscriptParser` 按行解析（`我：/我:` → me、
  `对方：/对方:` → other，全半角冒号都认；无前缀行**不归属**，side 用
  SIDE_UNKNOWN `'?'`——与旧仓库 OcrGrouping 同值同理由：未知必须保持未知，
  否则满屏自己的消息会被读成来话）→ ChatSnapshot 打 `Provenance.desktop`
  来源标记 → 与 Android 采集同一条 judge → draftAndRank 流水线
  （desktop_assistant_page.dart:51-103、transcript_parser.dart:40-56）。
- 未归属行数写进快照 note 并原样展示，文案样式对齐旧仓库 OCR 的部分未知注记
  （desktop_assistant_page.dart:47-49）。
- 桌面候选以列表展示，「复制」写剪贴板；**没有热键与原生窗口采集**——后续接入
  原生采集时只换快照来路，页面与流水线不动（desktop_assistant_page.dart:11-12）。
  `capture_windows` 插件未创建（根 pubspec.yaml workspace 注释：属阶段 3，
  落地后追加）。
- 相对旧仓库的新增：`Provenance.desktop` 来源标记（旧仓库只有 a11y/ocr/inject）。

### 6.4 持久化

- `SettingsStore` 整包 JSON：`config`（JevConfig 全字段）+ `relationship`
  （默认「朋友」）+ `overlayEnabled`（默认开）序列化成一个字符串，存
  shared_preferences 键 `settings`（settings_store.dart:27,72-83）。对应旧仓库
  Prefs.kt 的三组偏好；旧仓库每项一个 key，这里整包对称存取，也给
  `JevConfig.toJson` 一个位置。
- 启动即读（app/lib/main.dart:13-15）：存档缺失、整包 JSON 损坏、平台通道
  不可用一律按默认值起——坏存档不挡启动；写盘失败提示「已生效但写盘失败」，
  内存里的新值照常生效。
- 旧遗留「API Key 随 JevConfig 明文落盘」已由 #4 收掉：key 单独存安全区
  （Android Keystore / Windows DPAPI），旧明文存档自动迁移，见 7.5。

### 6.5 与场景路线的对齐

| 场景（scenarios.md） | 采集来源 | 落地状态 |
|---|---|---|
| `chat_copilot` 个人聊天副驾 | 无障碍/OCR | 已实现：Android 采集页 + 悬浮窗 |
| `support_agent` 客服/销售坐席辅助 | 热键 + 选中文本 | 模板已内置，采集源未落地 |
| `language_learning` 外语学习陪练 | 剪贴板/选中文本 | 模板已内置；暂可走桌面粘贴分析 |
| `live_interaction` 直播/社群互动助手 | 弹幕/评论流粘贴 | 模板已内置，采集源未落地 |
| `social_a11y` 社交辅助（无障碍） | 同聊天副驾 | 模板已内置；采集链路与聊天副驾共享（已落地），场景模板未接入会话 |

五个模板都在首页展示（`Scenarios.builtIns`），提示词注入机制在 core 就位
（`ReplyPrompt` 的 systemAddendum/userAddendum 形参），但流水线上游不传场景：
`ReplyClient` 调 `ReplyPrompt` 时不带 scenario（reply_client.dart:357-381），
app 两个分析入口也不选场景——当前实际请求都是默认 chat_copilot（附加段为空，
兼容锁语义不变）。

## 7. #4 落地记录（P0 体验包 + 人味增强包）

#4 在 §6 的三层上补「开箱即用」与「人味」：core 新增 AI 腔 linter 与说话方式画像
（仍是纯 Dart 零依赖），app 新增服务商预设 / 首次运行引导 / 快速改写 / 隐私预览等
接线，插件侧只动黑名单一处。本节只记接缝与不变式，规格原文见 `docs/p0-plan.md`。

### 7.1 服务商预设（①）

- `app/lib/application/model_presets.dart`：`ModelPreset {id, name, replyBaseUrl,
  judgeProtocolHint, needsKey, note}` 纯数据（改 id 等于让已保存的选择失效）。
  内置四档 `ModelPresets.builtIns`，顺序即下拉顺序：`deepseek`（`https://api.deepseek.com`，
  需 key）、`ollama`（`http://127.0.0.1:11434/v1`，**无需 key**，note「完全离线，
  聊天内容不出本机」）、`openrouter`（`https://openrouter.ai/api/v1`，需 key）、
  `dashscope`（`https://dashscope.aliyuncs.com/compatible-mode/v1`，需 key）。
- **预设只是起点、不是锁死**：设置页与引导页第二步共用 `ModelPresetPicker`
  （`onboarding_page.dart:15`），选中即把 `replyBaseUrl` 回填进地址框并按
  `hintLines` 提示 key 要求，手改地址仍允许；按地址反查（`byBaseUrl`，两边
  trim 去尾斜杠后比较）匹配不上显示「自定义」占位，不据此锁地址。
- 预设**不改判断路由**：`judgeProtocolHint` 只陈述事实——DeepSeek 档提示
  「判断路由若也指向 DeepSeek，判断协议自动用 chat」，对应 core 的
  `effectiveJudgeProtocol()` 对 `judgeProvider == 'deepseek'` 返回 chat
  （`jev_config.dart:121-123`）；预设本身不做任何改写。Ollama 档 key 留空即可用
  （HTTP 层的空 `Authorization: Bearer` 头会被它忽略）。

### 7.2 中文 AI 腔本地 linter（A2）

`core/lib/src/pipeline/ai_flavor_linter.dart`：纯规则、零模型调用，输出
`FlavorHit {rule, evidence}`。规则清单（7 条）：

| rule | 特征 | 判定要点 |
|---|---|---|
| `parallel_stack` 排比堆叠 | 连续 ≥3 个同构短句 | 句读切分后短句须 2–12 字；同头（前两字相同）或同长两种同构 |
| `summary_tail` 总结升华尾句 | 总之/说到底/总而言之/归根结底/归根到底/综上所述/由此可见 | 只认**最后一个句读**，句中出现不算 |
| `written_word` 书面语高频词 | 然而/因此/此外/与此同时/值得注意的是/不可否认/众所周知 | 出现任意一个即命中；刻意不含「不过/可是/所以」这类口语正常词 |
| `not_but` 「不是…而是…」 | 对比句式 | 中间允许逗号停顿、不跨句、跨度 ≤24 字防误连 |
| `emoji_abuse` emoji/语气词滥用 | emoji 或语气词（呀啦哦呗嘛哟咯喔哇捏嘿） | 两者**各自** ≥3 次才算；不含 吗/呢/吧/啊/哈（真人聊天太常见） |
| `uniform_length` 句长方差过小 | 整组特征 | ≥3 条、每条 ≥10 字、长度变异系数 < 0.12；命中挂**每一条** |
| `all_question` 每条都以问号结尾 | 整组特征 | ≥2 条全部 ？/? 收尾；命中挂**每一条** |

- 两层入口：`lint` 查单条、`lintGroup` 查整组——整组特征（长度均匀、清一色问号）
  只有把几条放一起才看得出来。
- **挂接点**：`JevClient.draftAndRank` 终榜（排序 + 证据复查）之后
  （`jev_client.dart:280-336`）。命中数 ≥ `rewriteThreshold`（= 2，单一特征不动手：
  一次误伤的 refine 是真金白银和延迟）才走 `refineReply`，改写指令 =
  `refineInstruction` 的人话描述（只说怎么改，不把坏例句放回提示词）。重写成功
  **原位换文本**，概率/策略/排序标记/复查备注全保留，绝不重排；失败或空 → 保留
  原文、概率降 0.1（不低于 0），排序里仍可见。
- 开关经参数 `aiFlavorLintEnabled`（默认开）传入而非读配置——core 不反依赖 app；
  开关进 `draftAndRank` 缓存键（`jev_client.dart:110-112`），切换不会命中旧缓存。
- 测试：`ai_flavor_linter_test.dart` 每条规则正例/反例 + 整组挂载 + 指令文案 +
  draftAndRank 挂接（stub server）。

### 7.3 说话方式画像 few-shot（A3）

- `core/lib/src/persona_kb/style_profile.dart`：`buildStyleSamples(List<Msg>,
  {max = 3}) → List<Note>(type: style_sample)`，标题「我的说话方式样例」。输入只取
  `side == 'me'` 的消息——悬浮窗快照与桌面粘贴的「我：」行两种来源同一路径。
- **挑选规则**（先过滤后打分）：复读去重（折叠空白、不折大小写——大小写本身是
  表达方式）；命令句排除（任务指令前缀清单 + ≤4 字、无语气词无标点、非人称开头的
  纯短促命令，短应答白名单「收到/ok/666」与人称开头例外，判不准宁可放行）；>1000
  字整条排除（挑前过滤而非截断——粘贴的段子/文档不该教「我怎么说话」）；<2 字排除。
  合格池 < 2 条（`styleSamplesMinPool`）返回空表，调用方按「本轮无样例」处理不报错。
- **打分** = 0.5 × 长度接近中位数（合格池右中位）+ 0.5 × 口语密度（单字语气词
  1/次、口头禅词组 2/次、emoji/波浪号 1、同字符连打 ≥3 记 2，密度封顶 1）；并列按
  原始出现顺序排，同一份输入永远选出同一批。
- **条数**：硬上限 `styleSamplesHardMax = 5`，默认 3 与 `ReplyPrompt.knowledgeBlock`
  的 `<user_style_examples>` 通道一轮最多引用 3 条对齐（`reply_prompt.dart:101-103`）；
  选中的原文不截断（每条 5000 字引用上限是 knowledgeBlock 既有规则，两边不重复干活）。
- **只进写作路**：`ChatContext.background()` 渲染笔记时跳过
  `noteTypeStyleSample`（`kb_models.dart:163-165`），判断路的 state 拿不到样例，
  写作路的 `<user_style_examples>` 正常引用。app 侧开关「学习我的说话方式」：
  采集页从快照我方消息挑（`capture_page.dart:302-310`），桌面页从粘贴文本的
  「我：」行挑（`desktop_assistant_page.dart:273-278`），都经
  `CaptureSession.buildContext` 组装（`capture_session.dart:150-187`）。

### 7.4 采集应用黑名单（⑦）

- **清单单一事实来源在 Dart**：`SettingsStore.blockedPackages`（可编辑 notifier，
  随整包 JSON 持久化），默认 `{com.eg.android.AlipayGmobile 支付宝, com.unionpay
  云闪付, cn.soulapp.android Soul}`——Soul 是旧 `BLOCKED_PKGS` 原有成员（防截屏
  应用），随黑名单可配置化并入默认值，避免首次 configure 把它冲掉
  （`settings_store.dart:88-106`）。
- **前缀底线不可被 UI 清空**：`com.android.bank` 前缀不持久化、不进可编辑集合，
  硬编码在 Kotlin `isBlocked()` 里（`CaptureService.kt:113-116`）。
- **通道与优先级**：`configure` 新增 `blocked` 参数（`capture_android.dart:104-109`
  → `CaptureService.kt:790-791`），`ServiceConfig.blockedPackages` 为 @Volatile
  可配置集合（`CaptureService.kt:79-83`）；`isBlocked()` **先查黑名单再查白名单**
  （`CaptureService.kt:380-383`）——用户明确拉黑的包即使加了白名单也不采。
  Kotlin 默认集合只在 configure 到来之前兜底。
- **UI**：采集页「采集范围」卡黑名单区（FilterChip 点按移除 + 「添加包名」输入框），
  增删走唯一写入口并立即重推 configure，改完即生效（`capture_page.dart:77-90,
  383-389`）；`main.dart` 注入与设置页共享同一份 notifier（`main.dart:89-90`）。

### 7.5 API Key 安全区存储与迁移（F2）

- 依赖：`flutter_secure_storage ^10.3.4`（`app/pubspec.yaml:28`）——Android 走
  Keystore、Windows 走 DPAPI，均为系统级加密；门面不传自定义选项。改动全在 app
  层，core 仍是零第三方依赖。
- **存储形状**：`replyKey/judgeKey` 单独存安全区键 `config.replyKey/config.judgeKey`；
  `SettingsStore.toJson` 写盘前把这两个字段从 config JSON 移除——shared_preferences
  里不再出现 key 明文（`settings_store.dart:44-51, 248-253`）。
- **写序**：`save()` 先安全区后 prefs——第二步失败时安全区已持有新 key，下次启动
  读到的是新值；反过来则可能旧 key 留在安全区、静默复活盖掉用户刚改的 key
  （`settings_store.dart:234-243`）。空串 key 写安全区改为删除（不留空串密钥）；
  安全区读失败按「没存过」处理，不挡其余字段加载。
- **迁移（幂等）**：`load()` 里 `_migratePlainKeys`——旧存档 config 读到非空明文
  key → 写安全区 → 从存档删键并立即重写整包；删键后重写**不走 `save()`**（此刻
  内存还没灌入存档值，走 save 会把默认值覆盖上盘）；安全区写失败则原样保留明文
  （宁可维持旧明文行为也不弄丢 key），下次启动再迁；迁移过的存档无这两个键，
  直接跳过（`settings_store.dart:197-232`）。

### 7.6 兼容锁策略（A1 + #4 新增默认路径的不变式）

- **A1 禁令改正向示例**：`JevConfig.usePositiveExamples` 默认 false
  （`jev_config.dart:85`），`ReplyClient` 透传进 `ReplyPrompt`
  （`reply_client.dart:379-381`）。**关闭（默认）时** `_safetyBans`/`_registerBans`
  走原分支，提示词输出与改前逐字节一致；**开启时**同一条红线改为「正向示范 +
  反例对照」，反例只写类别、不写坏例句（防模型原样抄回）。测试钉住：默认与显式
  关闭逐字节一致、开启态六条安全红线一条不少（safetyBans 永远在上，即 G6 的
  信任边界）、语域放开分支不受开关影响、`draftSystemPrompt` 透传
  （`ai_flavor_linter_test.dart` 的「A1 正向示范开关」组）。配置字段已进
  JevConfig 的 JSON round trip（`jev_config.dart:214, 242`），评测后再切默认。
- **既有场景兼容锁不变**（§5）：`chat_copilot` 附加段为空、提示词与无场景参数
  逐字节一致（`reply_prompt_test.dart:741-763`）。#4 引导页第一步记住的场景 id
  （`SettingsStore.scenarioId`）目前只有引导页写，流水线消费附加段的接线仍属
  后续工作流——当前实际请求全部跑默认 chat_copilot。
- **新增默认路径的逐字节不变式**：补充背景与风格学习都关时 `buildContext`
  返回 null，请求与旧版「不带 ctx」一致（载荷、缓存键都不动，
  `capture_session.dart:146-149`）；linter 无命中的候选原样返回，不改概率不重排
  （`jev_client.dart:301-305`）。

## 8. 隐私与风险立场（不因重写而改变）

- 聊天文字发送到用户自配的模型服务商；截图仅本机 OCR；历史默认关闭、仅存本地。
- 无障碍读屏 + 回填在部分聊天 App 条款下有封号风险；桌面端走官网分发。
- 起草前 SafetyGate 预检永不关闭：违法/自伤/未成年×亲密/安全词/硬边界直接阻断，黄灯与换说法边界降为谨慎提示。
