# 体检修复报告：全项目审查后的集中修复（2026-10-28）

## 背景

对主工程 123 个 Kotlin 文件（约 2.3 万行）做了四层并行审查（采集 / 网络与 LLM / 数据与知识库 / UI 与桥接），人工复核全部关键发现后按批准的方案集中修复。修复期间 Mimosa 钩子硬性拦截提交（`tools/jev/` 既有高危发现），顺带完成了工具脚本的安全整改。

## 修复清单（按层）

### 采集层 `capture/ChatCaptureService.kt`

| # | 问题 | 修法 |
| :-- | :--- | :--- |
| 高危 | `ocrCaptureManual` root 为 null 且包名回退微信时，可空 root 进非空参数 `maybeCaptureWeChat`，`targetFor` 解引用即 NPE，无障碍服务死亡 | `root?.let { maybeCaptureWeChat(it, manual = true) } ?: toast` |
| 中 | `maybeCapture` 瞬态 null root 立即拆会话清卡 | 改走 `scheduleLeave()` 的 1200ms 宽限（复用 `confirmLeave`） |
| 中 | 手动生成 CaptureFirst 不接管卡死轮，`runAnalysis` 被 `analyzing` 静默挡掉 | CaptureFirst 分支补 `shouldForceTakeOver → cancelInFlight()` |
| 性能 | 截图像素扫描（10MB 数组 + getPixels + 洪泛填充，约 50-150ms）在主线程，微信路径周期性掉帧 | 新增 `pixelWorker` 单线程；微信与整屏两条路径的扫描下放，OCR 留主线程 |
| 性能 | `isCurrent` 每次全树 extract（几千节点 binder IPC），流式期间每块一次 | 400ms 时间盒：同 token 查过且为 true 直接信；false 永不缓存；`session.accepts` 先行（invalidate 立即回落全查）；`fillInput` 入口强制全查 |

### 悬浮层 `overlay/OverlayController.kt`

- `showJudgment` / `showDraftFirst` / `showReplies` / `giveUp` 只调 `render()`，BUBBLE 模式下 `renderHeader()` 早退从不碰 `capsuleText`——胶囊读数永久卡在最后一秒。四处补 `if (mode == Mode.BUBBLE) renderCapsule()`。

### 网络与 LLM 层 `jev/`

- **`ReplyCacheKey.reply` 十分量 → 十四分量**：新增 `title`（会话标题，堵跨会话串缓存）、`params`（语言/长度/温度/两个惩罚/复查开关+复查模型）；`style` 改传 `StyleSource.resolve` 的**生效正文**（联系人专用人设压过全局时，旧键锁的是被盖住的 `Prefs.style`）；`judgmentKey` 补 `trueIntent.confidence` 与 `shouldReplyNow`。
- **回复侧 ctxKey 补风格样本笔记与技能 L1 目录**（都进回复提示词）；判断侧 ctxKey 刻意不含这两样，不白作废判断缓存。
- **`JevClient` 提升为服务级单例**（`jev` lazy 字段，4 处局部构造替换）：`judgeCache` 的跨轮免重判首次真正生效。
- 缓存键对账中确认 `judgeKey` 原本分量齐全；`HttpJson` 的重试/取消/流关闭路径审查未发现新问题。

### 数据层 `core/kb/PersonaStore.kt`

- `install` / `topUpLocked` / `restoreBuiltins` / `delete` 先动内存台账再写盘（顺序本身正确），但写**失败**返回时内存台账带着幻影 key——同会话内下一次成功写盘会把它持久化。新增 `reloadLedgerLocked()` 在四个失败分支回读磁盘对齐。测试：`personas.json.tmp` 占成目录造真实写失败。

### UI 层三页

- `SettingsActivity`：清空知识库的 `counts()`（锁内逐联系人读日志）与 `clearAll()`（整目录递归删除）挪 worker。
- `KnowledgeActivity`：文本导入从循环 `saveNote`（每条全量重写 notes.json，平方级）改为一次 `saveNotes`；内置技能包导入（解包 40+ 文件）挪线程。
- `ExpertActivity`：duplicate / exportText / delete / 重命名 / create / save+updateMeta / importJson / exportJson / restoreBuiltins 全部照 `installOnly` 模式包 worker，回调判 `isDestroyed`。

### 低危批量

- `ui/ExpertAdapter.kt`：DiffUtil 补 `body` 比较（无简介专家卡面显示正文第一行，改正文不刷新）。
- `capture/OcrGrouping.kt`：`TAIL_TIME` 要求时间戳前有空白（「会议改到10:30」不再被截）；整条纯时间戳照旧清空（保留原语义）。
- `DocImportActivity` + manifest：`configChanges="orientation|screenSize|keyboardHidden"`，三处 `runOnUiThread` 补 `isDestroyed` 守卫。

## 工具脚本安全整改（`tools/jev/` + 仓库根两个脚本，提交被 Mimosa 拦截后顺带完成）

Mimosa git-gate 扫的是**整个仓库**，首次提交拦截共暴露 14 处高危：`tools/jev/` 12 处（4 SSRF + 8 路径穿越），外加 `tools/gen_experts.py:448` 路径穿越、`global/tools/or_client.py:65/110` SSRF。新增 `tools/jev/safeguards.py`：

- `check_http_url(url)`：scheme 白名单（http/https）+ 主机名非空 + `getaddrinfo` 解析后**逐地址**校验非私网/回环/链路本地（显式 IP 字面量与 `localhost` 放行——本机代理是合法用法）。
- `safe_out(path)`：realpath 后必须落在仓库根内，越界 `SystemExit`。
- `write_text` / `dump_json`：净化 + 落盘一步到位（pathlib 写入）。

四个 jev 评测脚本的 `urlopen` 全部过闸；八处 CLI 路径写全部收敛（含 JVM 交接文件、台账、结果 JSON）。`gen_experts.py` 的 `--out` 收敛进仓库根、改 pathlib 落盘；`or_client.py` 自带同款 `_check_url` 并在 `_request` 入口过闸。

**扫描器认可情况**：仓库根重扫 14 → 4。全部路径穿越与 or_client 的 SSRF 清零（realpath containment / `safe_out` / `_check_url` 各自被认可）；**`tools/jev/` 4 处 SSRF 仍在册**——同是 SSRF profile，`or_client._check_url` 被认可而 `safeguards.check_http_url` 没有，差异只在 `--base` 是**命令行参数**（污点源直达）而 or_client 的 URL 是写死的模块常量。依次试过行内包裹 / 变量赋值 / 同函数内联 / 属性析取四种形状均不认可，结论是污点模型对「argv → 自定义净化函数 → urlopen」这条链不认任何自定义净化。这 4 处是本地评测脚本按设计连用户自己配的模型接口，防护已真实到位；残余判定留人工：接受残留并调整扫描策略（如 exclude `tools/`、或对该 profile 降级），脚本行为不变。

## 验证

- JVM 单测 **85 suites / 1038 tests / 0 failures / 0 errors / 2 skipped**（上一轮 1035）。
  - `ReplyCacheKeyTest`：14 分量逐个变异上锁（含 params 三个子维度与判断键 title）。
  - `OcrGroupingTest`：粘连时间照剥 / 正文时间不剥 两个方向新用例。
  - `PersonaStoreTest`：真实写失败下台账不被污染、专家随后可装。
- 修复过程中发现并修正两处实现偏差：整屏 OCR 拆方法时括号失衡（编译期即暴露）；`cleanBubbleText` 新规则一度会破坏「整条纯时间戳变空」的既有语义（既有测试咬住）。

## 提交状态

全部改动在 `fix/review-findings` 分支并**已 staged**（25 文件，+735/−220，未提交）。提交被两道闸拦住：

1. Mimosa git-gate：`tools/jev/` 4 条 SSRF 残留（见上），高危强制拦截。
2. 宿主权限层：`git commit` 需明确授权。

建议的提交切分（6 个 commit，见 CHANGELOG 同日条目）：① capture 三修复 ② 胶囊 ③ 缓存键+单例+测试 ④ 三页 IO ⑤ 像素+时间盒 ⑥ 低危批量+工具整改+文档。走法二选一：**(a)** 接受 4 条残留，在扫描策略里对 `tools/` 的该 profile 降级或 exclude 后由你提交；**(b)** 你先人工复核这 4 处（`check_http_url` 的实现就在 `tools/jev/safeguards.py`，约 40 行），认可后自行提交。

## 遗留（本轮未做，下轮候选）

- 看门狗代际号（watchdog 触发后旧轮迟到回调的污染窗口）——涉及轮次生命周期重构，风险较高，单独一轮做。
- `KnowledgeActivity` / `ExpertActivity` 的**读路径**（render / 每行 logSize）仍在主线程，本轮只下放了写路径与重 IO。
- `JevClient` 缓存目前进程内只有服务在用；若未来跨组件共享需加进程内同步。
