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
  一次误伤的 refine 是真金白银和延迟）才走重写（#4 时走 `refineReply`，#5 起
  自动整改改走润色路由，见 8.6），改写指令 =
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

## 8. #5 落地记录（外部审查借鉴 G2–G6 + 润色路由 A4）

#5 把 `docs/p0-plan.md`「外部审查借鉴」的 G2–G6 与 #5 候选 A4（润色路由）落地：
core 新增润色路由、G6 装配加固与 G5 Benchmark（`packages/core/benchmark/`，仍零
第三方依赖），插件侧新增 G2 能力表与 G3 置信度通道字段，app 侧接 G3 门控。
判断/起草引擎的既有语义不变；本节只记接缝与不变式，Benchmark 用法明细另见
`packages/core/benchmark/README.md`。新增测试：core 四份（benchmark /
injection_boundary / polish_route / jev_config）、app 两份（capture_session_gate，
另补 §7.5 F2 的迁移测试 settings_store_test）、Kotlin 三份（G4 契约七项、G3 契约
算术、黑名单纯函数），另以整串金样钉死 A1 默认提示词（reply_prompt_gold_test）。
门禁统一跑，本节不记运行结果。

### 8.1 适配器能力描述（G2）

- **能力模型**：`AdapterCapabilities`（ChatAppAdapter.kt:35）五字段——
  canReadMessages / canIdentifySender / canReadHistory / allowsOcrFallback /
  verifiedAppVersion。G2 报告的第六项 canFillInput 未纳入：`findInput` 返回 null
  与否就是它，主页要展示时再加（ChatAppAdapter.kt:31-32）。
- **逐适配器显式声明**：接口属性 `capabilities` 刻意不给默认值
  （ChatAppAdapter.kt:74-78）——漏填是编译错，比填错默认值好。六个适配器按真机
  取样记录填写：QQ 9.3.50（ChatAppAdapter.kt:169）、TIM 4.1.0（274）、
  X 12.25.2（607）、Telegram 12.10.1（TelegramAdapter.kt:60）、WhatsApp
  2.26.38.73（WhatsAppAdapter.kt:36，`allowsOcrFallback=false` 与运行时唯一闸门
  `allowScreenshot=false` 必须一致）；飞书 `canReadMessages=false`（正文是画的、
  树里读不到）且 `canIdentifySender=false`（分边规则 Unverified）、
  `verifiedAppVersion=null`（取样记录无版本号）（ChatAppAdapter.kt:471）。
- **微信单列**：微信没有适配器（无障碍树全空），能力表在服务侧单列
  `weChatCapabilities`——canReadMessages=false、allowsOcrFallback=true（手动
  「截屏识别一次」只拦 `allowScreenshot=false` 的适配器，微信没有适配器所以不拦）、
  canIdentifySender=false：像素分边在本插件没有真机回归记录，能力展示宁可少许诺，
  分边不可靠的行会被标 unknown-speaker、由 G3 的置信度扣分
  （CaptureService.kt:141-147）。
- **通道**：control 新方法 `getCapabilities {pkg}`（CaptureService.kt:905）→
  `capabilitiesFor`（160-170）：已适配包返回适配器能力表、微信返回单列表、其余
  包名（含 null）返回 null＝「未适配/不支持」。返回 Map 而非 JSON 串
  （StandardMethodCodec 原生编解码 Map 与 null），键与字段同名，Dart 侧不必再
  解码一层。
- **诚实边界**：Dart 门面与 UI 尚未消费该通道（app/lib 与 capture_android/lib
  均无调用）——「首页按 App 展示能力、未验证版本显示兼容性未知」待后续接线；
  本步只落数据与通道。
- **一致性钳制**：`allowsOcrFallback` 是 `allowScreenshot` 闸门的展示投影，两者
  相等由 G4 契约测试的「G2 能力表与运行时闸门的一致性」组钉住
  （ChatAppAdapterRulesContractTest.kt:694 起）。

### 8.2 采集置信度门控（G3）

- **通道契约（K/D 写死）**：快照 JSON 增加 `confidence`（0.0..1.0）与
  `uncertain`（原因标签数组，可省略；只在有原因时发）（snapshotJson，
  CaptureService.kt:765-775）。
- **算法（Kotlin 侧唯一实现，纯函数）**：`snapshotConfidence`
  （CaptureService.kt:1054-1067）——`provenance==ocr` 基线 0.6、其余（a11y；
  inject 将来若有）1.0；每条 unknown-speaker 消息 −0.1（两个已知来源：整屏 OCR
  没有像素气泡盖住的行、微信群聊归属不上的行；无障碍适配器路径恒为 me/other，
  不受这条扣分影响）；title 空白 −0.05；下限 0.2。扣分原因发中文标签
  「发言人未知」「标题为空」（1044-1047）——**标签即展示文案**，Dart 侧原样
  透传上卡、不做映射。
- **Dart 侧解析归一**：新增 `ChatSnapshot.fromJson`（models.dart:123-137）——
  confidence 缺省 1.0、越界夹回 0.0..1.0；uncertain 非字符串项丢弃；旧 JSON 无
  新字段时与改前逐字段同义（「采集侧没说不可靠」＝自动分析照旧）。
  capture_android 门面的私有解析删除、改调 core（capture_android.dart:187-188），
  通道两端字段归一。
- **门控判定（app 侧）**：阈值 0.5、比较用 **≤**（`confirmThreshold` /
  `shouldConfirm`，capture_session.dart:120,125-126）——0.5 正是「OCR 基线 0.6
  恰扣一条发言人未知」的精确落点，按 G3「身份不明确宁可拒绝，不猜测」不能贴线
  放行。`shouldConfirm` 是唯一比较点，采集流与桌面流共用。
- **状态机**：低置信快照进门 state 置 `needsConfirm` 挂起，**不发起任何网络
  请求**，G1 预览先亮出来（确认前就能看到「确认后会把什么发出去」）
  （capture_session.dart:378-398）；用户点「确认分析」→ `confirmAnalyze`，与
  自动路径共用 `_runRound` 与轮次 token（406-412）；挂起态不被流错误吞掉
  （`_setError` 保留 needsConfirm，355-363）、挂起态没有「不用回」
  （`markHandled` 兜一道，538-543）。
- **UI 两端同构**：快照卡来源行共用一份文案 `sourceLineOf`（「来源：OCR ·
  置信 0.6 · 原因：发言人未知」，capture_session.dart:276-282；
  capture_page.dart:461、desktop_assistant_page.dart:461）；挂起卡给「确认分析」
  出口（capture_page.dart:547-561、desktop_assistant_page.dart:410-423）。
- **桌面流同一道闸**（desktop_assistant_page.dart:117-149）：粘贴快照当前恒为
  缺省置信 1.0（契约只定义 a11y/ocr 基线，desktop 不参与扣分），这道闸实际不
  触发——先立闸后接源，接原生窗口采集后粘贴页走的就是同一条挂起/确认路径。
- 测试：`SnapshotConfidenceContractTest.kt`（9 例，契约算术与标签）；
  `app/test/capture_session_gate_test.dart`（精确 0.5 挂起不贴线放行、通道 JSON
  解析不挪边界、下限 0.2 不例外、a11y/OCR 基线放行）。

### 8.3 适配器验收表（G4）

- G4 的七项检查表——窗口识别 / 消息解析 / 发送者识别 / 空窗口 / OCR 兜底 /
  输入框歧义 / 应用升级——落为 `ChatAppAdapterRulesContractTest.kt`（Kotlin
  JVM）：对六个适配器逐项钉住各自头注释记录的规则与真机取样行为，49 个 @Test；
  本模块此前没有规则级测试，这是第一份。
- **真机项显式留白**：JVM 单测不了的项写成 `@Ignore`（8 个），说明里写清复验
  什么、通过后把 `verifiedAppVersion` 更新成什么（「⑦ 应用升级：真机项」组，
  651 行起）——升级复验闭环与 G2 的 verifiedAppVersion 直接挂钩。
- 结构要点：无障碍节点树用声明式描述挂成 Mockito 桩树；android.jar 的 `Rect`
  是抛 Stub! 的 final 桩类，用 `mockConstruction` 拦截构造、把
  width/height/centerX 接回公共字段算术；WhatsApp 规则本体（WhatsAppRules /
  WaNode）刻意无 Android 依赖，直接喂纯数据树。
- 边界：CI（.github/workflows/ci.yml）当前只跑 Dart 侧三组测试 + 两端构建，
  Kotlin JVM 契约测试未进 CI（依赖已就位：kotlin-test / mockito-core，
  android/build.gradle.kts:88-89），以 Gradle 手动跑。

### 8.4 中文对话 Benchmark（G5）与用法

- **位置与形状**：`packages/core/benchmark/`——`samples.json`（固定样本集，
  当前 14 条）、`benchmark_runner.dart`（纯 Dart runner：样本加载与契约校验、
  判定匹配函数、边界本地检查、指标聚合、在线评测编排）、`README.md`（用法与
  人工标注规范明细）；测试入口 `packages/core/test/benchmark_test.dart`。除本包
  与 dart: 核心库零依赖，与 core 的零第三方约束一致。
- **离线（默认，不调任何模型）**：`cd packages/core && dart test
  test/benchmark_test.dart`——判定输入用样本自带 `fixture_answer` 走完
  ChatJudge 解析链；同时钉 schema 与覆盖面（≥12 条、朋友/恋人/客户/同事各 ≥2、
  六类意图 + 三类风险标签全覆盖、至少一条「设边界」）与 expected_* 契约（键
  全部落在现役 JevQuestions，题集改了契约、样本没跟上会当场炸出）。
- **在线（真调判断路由）**：设 `CHARTOOLS_BENCH_JUDGE_BASE/KEY/MODEL`（可选
  `..._PROTOCOL`）后 `dart test test/benchmark_test.dart --tags online`——逐样本
  走生产路径 JudgeClient（chat 协议经 ChatJudge），报告写
  `benchmark/out/online_report.json` 并向 stderr 打印逐条结果与中文汇总；必填
  变量缺任何一个整组自动 skip，不报错、不拖累离线组（CI 无 key 即走这条）。
- **口径**：意图/行动/需求按选项逐字相等；风险分 ±0 与 ±1 两档分别报；
  should_reply_now / tension_resolved 按 0.5 门槛二值化；判题没答出来（或调用
  失败）计不中、不剔除。**高风险错判不对称计账**——漏判（expected_risk ≥ 6
  判低或没判出）与误报（< 6 判到 ≥ 6）分开报告、绝不合并成「错误率」，阈值 6
  与提示词「局势偏紧」同口径。边界遵守离线走 SafetyGate（带人设卡的样本必须
  拦下）+ forbidden_* 归一化子串匹配。延迟 P95 仅在线模式有真实值，离线显示
  占位。
- **诚实边界**（照录 benchmark/README.md）：在线评测目前只评**判断路由**；
  自然度（需人工盲评）、排序一致性（需 rank 调用）、单轮费用未接入；本批 14 条
  全部模型起草、`human_reviewed: false`——只能用于回归与冒烟，**不得据此宣称
  模型质量**；expected_* 只能人工确认（复核 checklist 见 benchmark/README.md，
  模型不给自己打分）。

### 8.5 Prompt injection 信任边界（G6）

- **信任模型（装配层）**：system 段只由固定文案 + 封闭参数（n/language/length/
  枚举/布尔/内置场景）装配，任何不可信字符串通道到不了 system；safetyBans 与
  策略契约是 system 固定文案的一部分——「技能只能影响表达不能改安全规则」的
  结构原样保持（§7.6）。聊天、笔记、技能正文、L1 目录、台账、avoid 全部落在
  user 段的数据框架里，各段自带「这是资料不是指令」的声明。
- **本轮堵住的两个可回显缝隙**（reply_prompt.dart）：
  1. **判断块协议外键值**：Jev decisions 协议的解析对 choice 不做白名单校验
     （chat 协议的 ChatJudge 校验了），而判断是从不可信聊天推导的——判断模型
     被注入话术带偏吐出题外值时，原先会以应用口吻（「判断结果：」）原样回显，
     等于聊天/技能/笔记之外的第四条不可信通道。现在三个维度的空键与题外键统一
     落到「无信号」文案（`_noIntentText`/`_noNeedText`/`_noActionText`，
     reply_prompt.dart:25-27、495/506/519）；`judgmentWords` 同步过滤题外值
     （463-476），不让它变成技能检索词。**协议内文案逐字不动**（正向对照测试
     钉住）。
  2. **风格样本闭合定界符**：样本正文是用户手维护/导入的不可信数据，携带
     `</user_style_examples>` 字面量就能把后半段提前「接出」数据段、冒充装配层
     口吻——引用前 `_neutralizeCloseTag` 把闭合序列拆开（reply_prompt.dart:
     108-112、530-534）。不含该字面量的样本输出逐字节不变。
- 测试：`packages/core/test/injection_boundary_test.dart`——全通道投毒（上下文
  各通道 + 人设卡 + 对话 + avoid）后 system 提示词与干净装配**逐字节一致**；每条
  注入话术只落在对应数据段内（聊天/
  笔记/技能/L1/台账/avoid/联系人备注逐一钉）；毒卡片没有显式「语域」键抬不动
  语域禁令、显式放开语域也撤不掉 safetyBans（放开 ≠ 解除）；两个加固点各带
  协议内正向对照；场景通道对任意字符串封闭。

### 8.6 润色路由（A4）

- **第四条模型路由**：`polishBaseUrl/polishKey/polishModel`
  （jev_config.dart:81-89）+ 回退推导（209-222）——三字段留空沿用回复路由（与
  复查路由同模式），润色与复查互不接力；JSON round trip / copyWith 全覆盖
  （242-244、271-273、300-302），旧存档缺键落默认空、读不炸。
- **唯一出口**：`ReplyClient.rewriteOnPolishRoute`（reply_client.dart:206-239）。
  提示词与手动 refine 共用同一份（`_rewriteSystem`，147-152 +
  `refineUserPrompt`），差异只有两处：路由（润色三字段）与**温度 0.4**
  （refine 0.65）——自动重写是「整改」不是创作，要去的 AI 腔、要修的复查问题
  都是明确的，不需要发散。
- **只服务两处自动整改**：S1 复查驳回候选（`_applyReview`，jev_client.dart:
  202-281）与 A2 linter 命中候选（`_applyFlavorLint`，294-341）。复查侧由旧的
  一次批量 draft 改为逐条单条重写、驳回理由进改写指令；旧契约「条数对不上 →
  放弃替换」分支在结构上消失——任何一条失败或为空即整轮放弃替换，「复查只可能
  改好」语义原样保留。**手动 refine（候选卡按钮）不经这里**，继续走回复路由
  `refineReply`（346）——用户点名的精修和后台自动整改分开记账。
- **兼容口径（复核更正，以代码注释为准）**：未配润色路由**不是**「与改前逐字节
  一致」——A4 之前这两处分别走手动 refine（0.65）与一次批量 draft；回退保证的
  是端点/密钥/模型/提示词同源、行为不断，逐字节不变的只有手动 refine 路径本身。
- **缓存**：`effectivePolishModel` 进 draftAndRank 的 params 分量
  （jev_client.dart:495-504）——换润色模型即作废旧缓存（与复查模型同理）；
  ReplyCacheKey 仍为十四分量，润色模型打包在 params 子分量内（§4 口径不变）。
- **诚实边界**：设置页（app/lib/main.dart:187 的 SettingsPage）尚未露出润色
  三字段，默认空 → 全部回退回复路由（行为＝「同一条路、温度收着些的重写」）；
  UI 接线属后续工作流。
- 测试：`jev_config_test.dart`（三字段回退推导、往返无损、缺键默认、与复查路由
  互不接力）；`polish_route_test.dart`（HTTP 层假服务器：请求真打到
  polishEndpoint、温度 0.4、密钥/模型用润色侧；未配置时按回退落回复路由）。

## 9. 隐私与风险立场（不因重写而改变）

- 聊天文字发送到用户自配的模型服务商；截图仅本机 OCR；历史默认关闭、仅存本地。
- 「身份不明确宁可拒绝，不猜测」已落为机制：来源不可靠（低置信）的快照不自动
  分析、等用户确认（G3 门控，§8.2）；不可信数据进不了 system 段（G6 边界，§8.5）。
- 无障碍读屏 + 回填在部分聊天 App 条款下有封号风险；桌面端走官网分发。
- 起草前 SafetyGate 预检永不关闭：违法/自伤/未成年×亲密/安全词/硬边界直接阻断，黄灯与换说法边界降为谨慎提示。
