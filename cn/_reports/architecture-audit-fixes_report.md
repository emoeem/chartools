# 架构审计整改：文档对齐、死代码、两条反向依赖

日期：2026-10-27 ｜ 范围：全仓库（cn + global + 根文档）｜ 结论：**文档漂移全修、11 处死代码清除、core 的两条反向依赖解除；cn 615 测试全绿、global 251 测试全绿，两模块 lint/构建通过**

## 1. 背景与做法

先出架构审计报告（另见会话记录），再按「快速见效 → 结构性」顺序整改。每条改动都先 grep 复核调用方再动手，改完跑全量测试。

## 2. 改了什么

### 2.1 构建 / 门禁
- `cn/gradlew` 的 git 模式 644 → 755（`git update-index --chmod=+x`），文档里的 `./gradlew` 在新克隆上恢复可用。

### 2.2 文档对齐（.github/README 三语 + global + cn/docs）
| 漂移 | 修正 |
|---|---|
| 「不动你的聊天软件：不 hook、不注入」（README.md:51、FAQ :161 及 en/vi 对应行） | 改「默认不动…；可选注入层默认关闭、逐 App 显式开启」——与 `module/JevHookEntry` 的存在一致 |
| 知识库检索「标签/标题出现在最近 6 条消息」「打好标签才能被命中」 | 改「BM25 相关度（标题/标签/正文都参与），最多 5 条」，与 `ContextBuilder`(BM25, `MATCH_WINDOW=30`, `MIN_SCORE=0.15`) 一致 |
| 「一把密钥自动继承判断接口的配置」 | 改「只继承**密钥**（视觉→回复→判断链）；地址/模型不继承，回复留空默认 OpenRouter」，与 `Prefs.kt:504-507,547` 一致 |
| 会话台账「默认关」 | 改「默认开，随『记录聊天历史』生效」，与 `Prefs.ledgerEnabled=true` 一致 |
| 历史注入「默认 30」 | 改「设置默认 30，注入写作上下文按预算最多 20」，与 `ContextBuilder:224` 一致 |
| 「四个专用适配器」 | 改「六个（QQ、TIM、X、飞书、WhatsApp、Telegram）」，与 `ChatCaptureService:61` 一致 |
| 危险等级「1–9」 | 改「0–9」，与 `JevQuestions` 一致 |
| workflow 名「Build Debug APK」 | 改「Android CI」 |
| README.en「Bocha 预设排第一、新装默认 Bocha」 | 改「新装默认 OpenRouter、OpenRouter 排第一」，与 `SettingsActivity`/`Prefs` 一致 |
| feature-guide「视觉（OCR 兜底用）」「视觉只在 OCR 兜底/连通测试时用」 | 改「视觉仅设置页连通测试用；OCR 走本机 ML Kit」，与 `VisionClient`（A 阶段壳）一致 |
| global/README「apk/: the signed release APK」 | 改「本机构建的产物（git 忽略；仓库不带安装包）」 |
| ARCHITECTURE.md：draft two replies / 1 chat request / video, sticker / confirm-only 一律拦 / Fill 判定在 Fill.kt / S=0.7G+0.3E 无条件 / 读屏上限 | 逐条对齐代码（三条起草、最坏 4 次 chat 请求、媒体类型五种、confirm-only 按 goal 分、Fill 判定在 `AssistantSession.fillAt/writeBox`、无决策 goal 只算 E、readMore 模式 10 屏/48 条/14 秒、取消是协作式） |
| CLAUDE.md 检索行、acceptance.md D.1（1.5 秒→2 秒、候选 1–3） | 对齐 P0 后的现实 |
| 三语 README 快速开始 | 补「Gradle 用 ANDROID_HOME 或 local.properties 定位 SDK」的新手上手说明 |
| README「QQ、TIM…真机跑通」与表格「TIM 待验」打架 | 改「TIM 已采样定规（正文解析待验）」，按 feature-guide 的谨慎口径 |

### 2.3 死代码清除（全部先 grep 复核零调用）
- `Prefs.openRouterKey` / `Prefs.autoSummary` / `Prefs.ocrForUnknownApps` / `Prefs.cardPosition`+`saveCardPosition`（含 `OverlayController.kt:338` 的写调用——写了从不读的第四套卡片位置系统）
- `OverlayUiState.kt` 整个文件（密封状态机只写不读）+ `OverlayController` 里的字段与 4 处赋值
- `SkillStore.enabledRefs()` / `BridgeContract.RECEIVER_CLASS` / `ModuleLog.tail()` / `KbStore.note(id)`
- **保留** `OcrEngine`（见 2.4）、`A11ySettings.without()`（曾误删——它在同对象 `plan()` 内被无点号调用，测试抓回后已恢复）、`VisionClient`（文档声明的 A 阶段壳）、`ChatSnapshot.history`（L1 注入管线的在途功能）

### 2.4 解除 core 的两条反向依赖
1. **core.kb → jev**：`ContextBuilder` 不再 import `ReplyClient`。新增两个端口 `HistorySummarizer` / `LedgerRefresher`（`fun interface`，定义在 ContextBuilder.kt），`build()` 以可空参数注入；`ChatCaptureService` 传入 `ReplyClient` 实现，`KbSelfCheck` 走默认 null——顺带修掉「自检带空 key 向默认回复端点发 POST」的隐患。
2. **core.kb.extract → capture.ocr**：`OcrEngine` + `OcrLine` 从 `capture/ocr` 移到 `core/ocr`（core 定义所需端口，capture 实现）；`PdfText.extractScanned` 改收 `OcrEngine` 参数；`DocImport.import/importUrl/extract` 透传；`DocImportActivity` 负责构造 `MlKitOcr()`。`core/` 现在 `grep 'import com.jev.probe.(jev|capture)'` 零命中。

未动的低危项：`root → capture`（RootFix 读 `ChatCaptureService.live`）、`overlay → jev`（StrategyOrder 纯显示映射放错包）——影响小，留给下一轮；大件（ChatCaptureService 14 关注点拆分、适配器契约收拢、AssistantSession 拆分）见审计报告「结构性改动」节。

## 3. 验收（真实输出）

```
$ cd cn && bash gradlew :app:testDebugUnitTest :app:assembleDebug --rerun-tasks
BUILD SUCCESSFUL in 23s  (45 tasks, 45 executed)
tests=615 failures=0 errors=0 skipped=2

$ cd global && bash gradlew test :a11y:lintDebug :assistant:lintDebug :probe:lintDebug assembleDebug
BUILD SUCCESSFUL in 1m 6s  (216 tasks)
global tests=251 failures=0 errors=0 skipped=0

$ grep -rn 'import com.jev.probe.(jev|capture)' cn/.../core/   → 零命中
$ grep -rn 'import android.' global/core/src --include=*.kt     → 零命中
```

## 4. 自验缺口

- 未跑真机：先判后写、OCR、注入回落等运行时行为不在本轮验证范围。
- `OcrEngine` 的移动只验证了编译与单测（单测不覆盖 Android 图形路径）；扫描 PDF 导入的真机路径未复测。
- `KbSelfCheck` 改为不联网后，其「台账构建」分支实际测到的是「沿用旧台账」路径（原先带空 key 也必然失败，行为等价），但自检按钮的完整文案语义未人工过一遍。
- 死代码清除后未重审 `lintDebug` 全量 warning（lint 通过，但没做 warningsAsErrors 收紧——那是审计里的独立建议）。
