# Jev 聊天助手（安卓）— 全平台非侵入对话副驾

挂在聊天 App 旁边（QQ、TIM、Telegram、微信、飞书、X、WhatsApp 已适配）的非侵入式助手：读到对方最新消息 → 先判断局势 → 悬浮窗给出分析和候选回复（判断排序）→ 人一键填入输入框。**发送永远由人手动点，程序不自动发。**

> **当前状态（2026-10-22）**：版本 2.0 开发中。完整功能见 [docs/feature-guide.md](docs/feature-guide.md)，逐版改动见 [CHANGELOG.md](CHANGELOG.md)。回复自然度 P0（先判后写 / 关系优先级 / n 感知策略契约 / 避谈键）已落地，报告在 `_reports/reply-naturalness-p0_report.md`。

## 硬约束（所有人必须遵守）

1. **默认不 hook、不注入**：无障碍服务 + 截屏/OCR 是默认路径，也是永远可用的兜底；框架未启用或未授权作用域时，功能与完全不开注入一致。注入层（LSPosed / Vector）为**可选增强**，按 App 显式开启、**默认关闭**。
   - **绝不修改或写入目标 App 的任何数据**：不写数据库、不发消息、不点发送按钮。
   - 读目标 App 数据**只允许复用宿主已打开的句柄**做只读查询（`ReplyDatabaseHistory` 姿势：只 observe 句柄，**绝不自行打开文件、获取密钥、写入或关闭宿主数据库**）。
   - 注入层**永不阻塞**：读不到 / 超时 / 类定位失败就立刻回落无障碍路径，并在 `Trace` 里标注降级原因，不静默。
   - 注入有**账号风险**，设置页必须原文呈现：微信协议 8.2.1.4–8.2.1.7 限制未授权插件接入与对运行数据的读取，8.5.1 的处置包含功能限制与账号封禁；**「只读、不发消息」不能推导出不会封号**。方案见 `docs/lsposed-enhancement-plan.md`。
2. **绝不自动发送消息**，绝不点任何 App 的发送按钮。填入输入框后停手。
3. **只读目标 App 正常开放给无障碍服务的内容**：服务类名用本项目自己的包名；`accessibility_service_config.xml` 不加 `isAccessibilityTool`（本 App 不是辅助功能工具）；目标 App 隐藏控件树或开了防截屏，就视为不支持。
4. **不碰钱**：不触碰转账、红包、收款码相关任何界面元素。
5. **路径全 ASCII**：Android 构建工具不接受中文路径。本机仓库在 `/home/emo/code/chartools/cn`；Windows 构建机沿用 `H:\ai_tool\jev-android`。两处路径都只含 ASCII。
6. **密钥不落盘、不进日志、不进 git**：OpenRouter key 从环境变量 `OPENROUTER_API_KEY` 读，或 App 加密设置项（Keystore AES-GCM）。任何文件里都不许出现 `sk-or-` / `sk-` 开头的真实密钥。
7. 编码一律 UTF-8。Windows 中文环境下 PowerShell 用 pwsh 7+，Python 读写文件必须显式 `encoding='utf-8'`。
8. 禁止 `git commit` / `git push`，由人拍板。

## 技术栈

- Kotlin，传统 View + XML，**不用 Compose**
- minSdk 30，compileSdk / targetSdk 35
- JDK 17+；本机 Android SDK 在 `/home/emo/android-sdk`（Gradle 用 `cn/local.properties` 的 `sdk.dir`）；Windows 构建机 JDK/SDK 在 `H:\android\jdk` / `H:\android\sdk`，Gradle 缓存 `H:\android\gradle-home`
- 目标机（2026-10-06 实测）：OPPO PJE110 / Android 16 (SDK 36) / 1200×2670；KernelSU root 可用（`su -c id` → `context=u:r.ksu:s0`），注入框架 = **Vector 2.2**（LSPosed 现代分支，API 102，兼容旧 `de.robv.android.xposed` API），框架 CLI 在 `/data/adb/lspd/cli`（`modules enable|disable|ls` / `scope add|ls|rm`，支持 `--json`），设备**没有 `sqlite3`**。历史目标机：小米 14（houji / 23127PN0CC），HyperOS 3.0 / Android 16。
- 模型客户端分三路：`jev/JudgeClient`（判断）、`jev/ReplyClient`（回复）、`jev/VisionClient`（视觉，OCR 用），共用 `jev/HttpJson`；配置在 `core/Prefs`（`judge*` / `reply*` / `vision*` 字段），旧密钥一次性迁移，标记位 `prefs_migrated_v13`。
- ML Kit `com.google.mlkit:text-recognition-chinese:16.0.1`（bundled，不是 play-services 版），`ndk.abiFilters` 只留 `arm64-v8a`。

## 关键背景（2026-09-21 实测结论，别重复踩）

- 兜底路线：无障碍服务的 `takeScreenshot()` + 本地 OCR（ML Kit），同样零 token。
- 飞书 Android（2026-09-21 实测）：消息正文自绘，无障碍树里**没有文字**（与 `uiautomator dump` 一致），只有 `bubble_content_container` 气泡位置、`group_name` 标题、`kb_rich_text_content` 输入框；正文要走 takeScreenshot + OCR。飞书默认左对齐布局，我/对方不能按左右判。
- 手机 QQ 9.3.50（2026-09-21 实测，小米 14 / 1200×2670）：节点**不混淆**，普通 `uiautomator dump` 即可读。消息正文 `com.tencent.mobileqq:id/mjn`（TextView，text 即正文），群昵称 `id/mjq`，标题 `id/371`，输入框 `id/input`，发送按钮 `id/send_btn`（**绝不 performAction**）。时间戳与系统提示条无 id，只采 `id/mjn` 就自然排除。
- QQ 全程是 `SplashActivity`（fragment 架构），**不能按 activity 判断是否在聊天窗**，只能看树里有没有 `id/mjn` / `id/input`。头像贴各自外侧（别人 left≈width×0.13，自己 right≈width−width×0.13），判「我/对方」要比左右两边离头像列的距离，不能用中心点（长消息中心会过半屏）。
- X / Twitter 12.25.2（2026-09-21 实测，小米 14 / 1200×2670 / 中文界面）：私信页是 **Compose UI，消息节点没有 resource-id**，`android.view.View`、全宽 `[0,y][1200,y+h]`、text 为空，**全部信息在 content-desc**，格式 `发件人：正文。8:11 上午。Read。`（全角冒号分隔、`。` 粘字段、末尾可能有时间和 `Read`）。附件行 `All-In：附加的帖子。。` 内部嵌套引用帖子的 TextView，只采 View 自身的 desc、不采子节点。
- WhatsApp（规则来自 #73 @smgonthebeat，按 2.26.38.73 录屏）：`capture/WhatsAppAdapter.kt`，纯规则在 `WhatsAppRules`（不依赖 Android 类，`app/src/test/resources/whatsapp/` 的录屏数据驱动单测）。只认 resource-id 和位置：对话页 = `conversation_contact_name` + `entry`；出现群聊 id 就返回 null（群聊不读）；读不到文字也返回 null，**永远不给空快照**，所以不会触发截屏；`NO_SCREENSHOT_PKGS` 同时关掉手动「截屏识别一次」。
- X **所有页面都是 `com.x.android.main.MainActivity`，不能按 activity 判窗**：对话页有 EditText（唯一那个，[204,2424][1152,2568]），私信列表页没有 → 靠「树里有没有可编辑节点」判断。列表页的行长得也像（全宽 View + desc），但格式是 `All-In, @all_in_2026, 正文…`，用含 `, @` 再排除一次。发送按钮输入后才出现，**绝不点**。
- 采集层按 App 分发：`capture/ChatAppAdapter.kt` 一个 App 一个适配器，`ChatCaptureService` 按前台包名查表；下游通用。
- Jev = TypeSafe 的判断模型，只回答选择题/打分/是非，不生成文字。走 OpenRouter：
  `POST https://openrouter.ai/api/alpha/decisions`，model `typesafe/jev-1.13`，
  body `{model, state, questions}`，答案在 `answers`。实测 7 题一次约 900 ms、约 1000 输入 token、0.00004 美元。
- Jev 主训练语言是英文：**题目的 instructions 和 criteria 用英文写，state 里的聊天内容保留中文原文。**
- 知识库 / 上下文数据在 `filesDir/kb` 下的 JSON 文件（`notes.json` / `contacts.json` / `logs/<contactId>.json`）；`KbStore` 单锁 + 原子写（先写 `.tmp` 再 rename）。`ContextBuilder` 做 alwaysOn 笔记全带 + BM25 相关度检索（`LexicalSearch`，标题/标签/正文都参与，minScore=0.15，最多 5 条，匹配窗口 30 条消息），不做语义（向量）检索，**不自动建档、历史默认关闭（`contextEnabled=false`）**。
- Kotlin 字符串模板 `$x` 后面紧跟中文标点（如 `」`、`）`）会被解析成标识符的一部分，导致 `Unresolved reference` 编译错误；**一律写成 `${x}`**。D 阶段在 `KbStore.kt` / `KbSelfCheck.kt` 踩过。
- OCR 层在 `capture/ocr`：`ScreenCapture` 限频 ≥1s + 失败退避（1s→2s→4s→8s→16s→30s 封顶），错误码 1/2/3/4/6 各给一句人话；`MlKitOcr` 用 bundled 中文模型。适配器契约：`extract` 返回 `null` = 不在聊天窗，返回空消息列表 = 在聊天窗但树里没正文——只有后者才触发 OCR 兜底。
- 无障碍 XML 加了 `android:canTakeScreenshot="true"`，**改完必须把无障碍关掉再重新开启才生效**，否则 `takeScreenshot` 直接回 errorCode 2。`ScreenCapture` 已按可换宿主的方式封装。

## 目录与文件锁

| 目录 | 归属 | 说明 |
|---|---|---|
| `app/`、`gradle/`、gradle 文件 | Android 构建方 | 国内版安卓工程，在本目录（`cn/`）跑 `./gradlew` |
| `tools/jev/` | Jev 判断方 | Python 题目集与校准脚手架，PC 上跑 |
| `docs/feature-guide.md` | 主控 | **当前版本的完整功能介绍**，用户文档以它为准 |
| `docs/product-scope.md` | 主控 | 产品范围与不可突破的边界 |
| `docs/acceptance.md` | 主控 | 验收标准（构建 / 单测 / 真机） |
| `docs/v1.3-*.md`、`docs/lsposed-enhancement-plan.md` | 主控 | 历史方案与设计记录，**不代表当前实现状态**；现状看 feature-guide 与 CHANGELOG |
| `_reports/` | 所有人 | 每个任务的交付报告写这里 |

跨边界的问题**只报告，不改**，由主控收口。

## 文档维护

用户可见的三份主文档，改动功能时必须同步：

1. `CHANGELOG.md` — 每版新增 / 改进 / 修复 / 已知限制，人话版；
2. `docs/feature-guide.md` — 完整功能介绍（采集、判断、起草、人设、知识库、技能、接口、安全）；
3. `.github/README.md`（及 `.en` / `.vi`）— 版本徽章、相对上游的改动清单、平台支持表。

贡献者与维护者分工只写在 `.github/CONTRIBUTORS.md`：本分支（`@emoeem`）与上游贡献者分节，上游署名按 NOTICE 保留，不得删除。

## 报告格式

任务完成后写 `_reports/<任务名>_report.md`：根因或做法（带证据）→ 改了什么（逐条列文件）→ 验收命令的**真实输出**（贴原文，不许编）→ **自验缺口**（没验到的明说）。
