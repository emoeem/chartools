# 手动「生成」+ 项目体检 + 上游差异

日期：2026-10-22 · 工程：`cn/`（国内版 Android，包名 `com.jev.probe`）

用户报的问题：**在 QQ 等应用里「重新生成」很难触发**，想法是"在目前的逻辑上面加一个选项，手动让软件进行生成"。

---

## 1. 根因：不是按钮难找，是按钮后面的锁会永久卡住

### 1.1 `analyzing` 只在一条路上被清，而那条路会被跳过

`ChatCaptureService.runAnalysis()` 里，一轮的结束点是嵌套在 `main.post { … }` 里的局部函数
`finishRoundIfReady()`：

```kotlin
main.post {
    if (!isCurrent(token)) return@post      // ← 旧代码：这里直接走人
    …
    fun finishRoundIfReady() {
        …
        analyzing = false                    // ← 唯一清锁的地方
        analysisTasks.clear()
    }
}
```

`isCurrent(token)` 会在这些情况下返回 false：会话 target 变了、`prefs.enabled` 变成 false、
`session.accepts(token)` 不成立、`prefs.isAllowed(title)` 不成立。

QQ 是单 Activity + fragment 架构（`CLAUDE.md` 已有记载），滚动、输入法弹起、切回消息列表、
标题在 Skeleton 文案之间抖动，都会让 `targetFor()` 读到一个不同的 target。结果回来时
`isCurrent` 就是 false → **直接 return，`analyzing` 永久停在 `true`**。

之后每一次「换一组」「再给 2 条」「单条重生成」都在第一行被挡住：

```kotlin
if (analyzing || regenerating || destroyed || !prefs.enabled) return   // 静默
```

屏幕上什么都不变。用户能得出的唯一结论就是"按钮坏了 / 点不到"。

### 1.2 五处静默 `return`，一处都没告诉用户为什么

旧 `regenerateReplies()` 的前五行：

```kotlin
if (analyzing || regenerating || destroyed || !prefs.enabled) return
val snapshot = lastAnalyzed ?: currentSnapshot ?: return
val token = session.token() ?: return
if (!isCurrent(token)) return
if (!prefs.hasKey()) { overlay?.showError(…) ; return }   // 唯一有反馈的一条
```

`refineReply()` / `moreReplies()` 是同一套写法。`overlay.onManualAnalyze` 更直接：

```kotlin
overlay?.onManualAnalyze = { currentSnapshot?.let { pendingSnapshot = it; runAnalysis() } }
```

没快照 → 连一次函数调用都没有。

### 1.3 入口本身也不在"够得着"的地方

`换一组 / 重试` 按钮渲染在 `renderBody()` 的 footer 里（body 是可滚动的 `MaxHeightScroll`，
`maxHeight` 由 `applyBodyMaxHeight()` 按卡片当前 y 计算）。在 QQ 里卡片常被拖到输入框附近，
body 更矮、候选一多 footer 就在滚动区外；键盘弹起时悬浮窗不会 resize，footer 进一步落到
屏幕之外。**即使锁没卡，用户也得先展开卡、再滚到底。**

### 1.4 同一类锁还有一把：`ocrBusy`

`ocrBusy` 的复位写在每个截图/OCR 回调出口，但回调本身可能永远不来（服务被解绑、Bitmap 被回收、
系统吞掉截图请求）。一旦停在 `true`，`ocrCapture()` 和 `ocrCaptureWeChat()` 都在第一行
`return` —— 「截屏识别一次」和手动生成里的抓屏分支一起失效。

---

## 2. 上游差异

上游 = `jev-chat/jev-chat-jarvis`（`NOTICE` 声明），本地 = `emoeem/chartools`。本地是上游的派生：

| 项 | 上游 `bd3fe42`（2026-10-16） | 本地 `chartools` |
|---|---|---|
| 目录结构 | `cn/` + `global/` | 相同 |
| `cn` 版本 | `versionCode 8 / 1.7` | `versionCode 10 / 2.0` |
| `cn` 主源码 | 6,154 行 / 大量功能缺失 | **19,984 行** |
| `cn` 单测 | 356 行 | **8,569 行**（69 个套件 / 585 例） |
| 文件级差异 | — | 42 个源文件只在本地、31 个共有文件被改、20 个测试文件只在本地 |

本地相对上游多出来的能力（按目录）：

- `capture/`：`InjectionSource`（L1 注入层可选降级）、`ForegroundPolicy`、`InputFiller`、
  `RecentReplies`（跨轮反重复）、`OcrGrouping`、`WeChatBubbles` / `WeChatSpeakerAttribution` /
  `WeChatTitleState` / `WeChatVoiceText`（微信像素链路）、`TelegramAdapter`、`AnalysisCallRunner`
- `bridge/` + `app/src/main/aidl/`：跨进程只读桥（目标 App 内模块 → 本 App）
- `core/`：`Intensity`（推进档位）、`ApiKeyVault`（密钥加密）、`kb/` 下的 `Ledger` /
  `PersonaCard` / `PersonaPresets` / `TopicScope` / `DomainBrief` / `extract/`（文档导入）
- `module/TelegramInjector` + `root/RootFix`：LSPosed/Vector 注入与 root 自愈

**关键结论：本次修的静默 `return` 与 `analyzing` 卡死，上游 1.7 一模一样存在**
（上游 `ChatCaptureService.kt:455-461` 是逐字相同的五行），不是本地引入的回归——本地只是把
这个缺陷一起带了过来，并且因为本地候选/重生成入口更多（换一组、再给 2 条、单条重生成），
撞上的概率更高。

---

## 3. 改了什么

### 3.1 新增：手动生成的决策层（纯逻辑、可单测）

`app/src/main/java/com/jev/probe/capture/ManualGenerate.kt`（新增）

把"点了之后会怎样"收敛成显式三选一，服务层照做，**每次点击都必然落到一个可见结果**：

| Decision | 触发条件 | 服务层动作 |
|---|---|---|
| `Regenerate` | 有快照（`lastAnalyzed` 或 `currentSnapshot`） | 有判断 → 只换候选；没判断 → 跑整轮 |
| `CaptureFirst` | 没快照，但当前前台应用抓得到 | 节点树优先，其次截屏 OCR，读完自动生成 |
| `Explain(reason, transient)` | 开关关 / 没密钥 / 正在跑 / 什么都抓不到 | `transient` → toast；否则 `showError` 展开卡并留在第一屏 |

`FORCE_GRACE_MS = 8_000`：忙超 8 秒视为上一轮卡死，手动点击有权接管；8 秒内双击只提示
「正在生成中…」，不砍正常轮次。

### 3.2 修：锁泄漏

`app/src/main/java/com/jev/probe/capture/ChatCaptureService.kt`

| 位置 | 改动 |
|---|---|
| `:147` | 新增 `endRound()`：一次性清 `analyzing`/`regenerating`、清任务表、disarm watchdog、通知 overlay 收等待态 |
| `:159` `:166` | 新增 `roundWatchdog` / `armRoundWatchdog()`：`2×requestTimeout + 10s` 只看时钟的兜底，到点强制解锁并 toast |
| `:294` | 新增 `ocrWatchdog`：30 秒兜底复位 `ocrBusy` |
| `:636 :685 :743 :906 :943 :974 :1032` | 七处 `if (!isCurrent(token)) return@post` 全部改成 `{ endRound(); return@post }` |
| `:947 :959` | 正常结束路径改用 `endRound()` |

### 3.3 修：静默 `return` 全部改成可见反馈

| 函数 | 现在的行为 |
|---|---|
| `refineReply()`（单条改短/换语气/重生成） | 正在跑 → toast；没快照 → `showError`；token 失效/会话变了 → toast |
| `moreReplies()`（再给 2 条） | 同上 |
| `regenerateReplies(snapshot, source)`（`cn/…/ChatCaptureService.kt:710`） | 同上，并加 `Trace.log("redraft source=…")` |
| `overlay.onManualAnalyze` | 改成走 `manualGenerate()`，没快照不再"什么都不做" |

### 3.4 新增：手动生成入口（用户诉求）

| 入口 | 文件 | 说明 |
|---|---|---|
| 卡片 header 常驻「↻」 | `OverlayController.kt:328-336` | 放在 header 而不是 body footer——header 永远第一行，拖到哪都在 |
| 长按菜单「重新生成候选（手动）」 | `OverlayController.kt:437` | 胶囊/卡 header 长按即可 |
| 常驻通知「重新生成」 | `KeepAliveService.kt:36-48`、`:62` | `ACTION_GENERATE` → `ChatCaptureService.onStartCommand`（`:1511`）→ `manualGenerate()`；卡片被键盘顶住时最后一道保险 |

服务侧实现：`manualGenerate()` `:770`、`canCaptureNow()` `:807`、`captureThenGenerate()` `:818`。

### 3.5 新增：`stopRoundWaiting()`

`OverlayController.kt:680`。服务侧一轮收尾时把 `judgeWaiting/repliesWaiting/moreWaiting` 收干净；
只在确实还在等待时才重建 body，正常落地（`showReplies`）不会被多画一次。

### 3.6 文档

`CHANGELOG.md` 顶部新增「未发布 — 手动「生成」」一节。

---

## 4. 验收（真实输出）

### 4.1 单元测试

```
$ bash gradlew :app:testDebugUnitTest
BUILD SUCCESSFUL in 1m 44s
26 actionable tasks: 26 executed
```

汇总 `app/build/test-results/testDebugUnitTest/*.xml`：

```
suites=69 tests=585 failures=0 errors=0 skipped=2
```

新增 `app/src/test/java/com/jev/probe/capture/ManualGenerateTest.kt`（9 例），锁住：

- 总开关关 / 没密钥 / 没快照且抓不到 → 都是 `Explain`，且**不是** transient（可行动）；
- 忙但未超时 → `Explain(transient=true)`；
- 忙且超时（含 8000ms 边界）→ `Regenerate`，`shouldForceTakeOver` 为 true；7999ms 为 false；空闲为 false；
- 有快照 → `Regenerate`；没快照但可抓 → `CaptureFirst`；
- 有快照时永远优先 `Regenerate`（截图比读树贵）。

### 4.2 构建 + 产物

```
$ bash gradlew :app:assembleDebug :app:testDebugUnitTest
BUILD SUCCESSFUL in 20s
45 actionable tasks: 24 executed, 21 up-to-date

-rw-r--r-- 1 emo emo 34372900 10月22日 09:39 app/build/outputs/apk/debug/app-debug.apk
```

### 4.3 新代码确实进了包（不是"构建成功但类没进去"）

```
$ apkanalyzer dex packages app/build/outputs/apk/debug/app-debug.apk | grep ManualGenerate
M d 1 1 697  com.jev.probe.capture.ChatCaptureService void manualGenerate()
C d 11 11 725 com.jev.probe.capture.ManualGenerate$Decision$Explain
M d 1 1  58  com.jev.probe.capture.ManualGenerate$Decision$Explain <init>(java.lang.String,boolean)
```

### 4.4 编译告警

改动引入的两条 warning 已处理：

- `ChatCaptureService.kt:821 Condition 'root != null' is always 'true'` → 重排判空顺序后消失。

剩余 warning 均为改动前既有（`MainActivity` 多余 cast、`WeChatBubbles` 冗余初始化、
`BubbleSnap` 未用参数等），本次未动。

---

## 5. 自验缺口（没验到的，明说）

1. **没有真机验证**。`adb devices` 当前无设备（`List of devices attached` 为空），所以三件事
   没做：`adb install -r`、真机点「↻」、QQ 里实际触发。悬浮窗本身在系统截图/录屏/uiautomator
   里不可见（ColorOS 系统层排除，`CHANGELOG` 已记载），`↻` 的观感只能人眼确认。
2. **行为证据只有离线层**：新判定的 9 个单测 + 编译 + 打包 + 类进包。服务层 `manualGenerate()`
   的实际执行路径没有 instrumented test（工程里没有 `androidTest` 之外的运行环境），
   也没有实况 Trace。
3. **8 秒接管阈值是拍的**。依据是 `requestTimeoutSeconds` 默认 30（范围 30–60）与
   `UI_LIMIT_S = 40`：正常一轮多数情况 10 秒内出结果，8 秒足够区分"还在跑"和"卡住了"。
   真机实测如果发现误杀正常轮次，把 `ManualGenerate.FORCE_GRACE_MS` 调到 15 秒即可。
4. **QQ 适配的硬编码 id 风险仍在**（见下节第 3 条），本次没改——那属于采集层的独立工作量。

---

## 6. 顺手做的项目体检（发现，未全部修）

按"会不会让用户觉得按钮坏了"排序：

| # | 发现 | 位置 | 状态 |
|---|---|---|---|
| 1 | `analyzing`/`regenerating`/`ocrBusy` 三把锁都可能在异常出口永久卡死，卡死后所有手动入口静默失效 | `ChatCaptureService` | **已修**（endRound + 两个 watchdog） |
| 2 | 5 处静默 `return`（没快照 / 没 token / token 失效 / 忙 / 开关关） | `ChatCaptureService` | **已修** |
| 3 | QQ 适配器强依赖 4 个硬编码 resource-id（`mjn` / `371` / `mjq` / `input`），没有版本自检。QQ 改 id 后：有 `input` 无 `mjn` → 走 OCR 降级（`ocrFallback` 默认开，尚可）；**`input` 也改了 → `extract` 返回 null → 卡片根本不出现**，且 `LEAVE_CONFIRM_MS=1200ms` 后直接 `overlay.hide()` | `ChatAppAdapter.kt:144-147`、`:127` | 未修（需要真机 dump 新版 QQ 对拍） |
| 4 | 悬浮卡 body 的 `maxHeight` 用 `screenH - y - dp(140)` 估算，不知道 IME 高度；键盘弹起时 footer 会落到屏幕外 | `OverlayController.applyBodyMaxHeight()` | 已用"header 常驻 ↻"绕过，未改计算 |
| 5 | `pill()` 的触摸目标 ≈ 30dp 高（`textSize 13 + padding 6/6`），低于 48dp 无障碍建议值，小屏/单手时容易点空 | `OverlayController.kt:922` | 未修 |
| 6 | `ChatCaptureService` 1,620 行、`SettingsActivity` 1,229 行、`OverlayController` 1,000 行，单文件职责过多 | 三个文件 | 未动（结构性重构，需单独立项） |
| 7 | 只有 JVM 单测，没有 instrumented/UI 测试；悬浮窗与无障碍链路的行为验证全靠真机人工 | `app/src` | 未动 |
| 8 | `Notification.Action` 挂在 `IMPORTANCE_MIN` 渠道上，部分 ROM 会把动作折进"更多"，通知栏入口的实际可见性需真机确认 | `KeepAliveService.kt:29` | 未动（已保留"唤出助手"作为对照） |

---

## 7. 下一步建议

1. 接手机后跑：`adb install -r app/build/outputs/apk/debug/app-debug.apk`，在 QQ 里分别验证
   三个入口（header ↻ / 长按菜单 / 通知），并用 `adb logcat -s JEVASSIST` 看
   `manual generate …`、`redraft source=…`、`round watchdog fired` 三类 Trace。
2. 若 QQ 里仍然"没读到"，先确认是 id 漂移：`uiautomator dump` 看 `id/mjn` 与 `id/input`
   是否还在，再决定是否给 QQAdapter 加通用降级。
3. 版本号与 git 未动（`versionCode 10 / 2.0`，仍只有 `10c4571` 一个提交，本次改动在工作区），
   等拍板。
