# jev-chat-jarvis v2.0 方案：可选注入层（yanwai 式）+ 长上下文质量工程（wenyi 式）

- 日期：2026-10-06
- 依据：用户指令 m02493「……我觉得这个项目应该和后面那个项目一样 yanwai，最好是有 lsposed 框架之后可以获得更多的功能的，因为我的手机就是 root 了的，但是我们也应该保留不使用 lsposed 的功能。」
- 参考项目：`/home/emo/code/yanwai`（微信 LSPosed 模块，注入层技术来源）、`/home/emo/code/wenyi`（长篇翻译工具，长上下文质量工程来源）
- 状态：**待用户拍板**（方案本身已可执行；第 6 节有必须由用户授权才能动的硬约束）

---

## 1. 结论摘要

1. **用户手机已具备全部前置条件**：KernelSU root 可用、Vector 2.2（LSPosed 现代分支）在跑、**WeKit 已启用并注入微信主进程**——「微信 + Vector 模块」这条路在本机已被第三方模块证明可用，不是待验证假设。
2. **框架可完全脚本化验收**：`Vector` 自带 CLI（`modules enable/disable/ls`、`scope add/ls/rm`），`--json` 输出。装包后我能用 adb+root 走完「启用模块 → 授权作用域 → 重启目标 App → 读框架日志」全链路，**不需要手点框架 UI**。
3. **动机是被实测逼出来的，不是想加就加**：微信 8.0.78 给无障碍的是**空树**（打开聊天页 `uiautomator dump` 只有 1 个节点 / 407 字节 / bounds `[0,0][0,0]`），所以 jev 现在读微信只能靠截图像素 + OCR。注入层能把这条最弱的路换成最强的那条。
4. **架构原则**：**一个 APK 两张面孔**。无障碍 + 截屏/OCR 永远是默认、永远可用、零注入；注入层是**按 App 显式开启、默认关闭**的可选增强。上游 `ChatSnapshot` 保持唯一契约，下游（判断/提示词/悬浮窗/填入）完全不感知来源，只在面板和 `Trace` 里标注这条快照是哪一级产出的。
5. **注入层只有配上 wenyi 的那套长上下文工程才划算**：光多读到 100 条历史，不会自动变准。所以第一部分（S1）完全不碰 hook、纯离线、今天就能做、今天就能量化。

---

## 2. 环境实测（决定可行性的事实）

| 项 | 实测值 | 证据 |
|---|---|---|
| 设备 | OPPO PJE110，Android **16**（SDK 36） | `adb devices -l` → `3afd9f4e device product:PJE110 model:PJE110` |
| Root | **KernelSU**，`su -c` 从 adb 可用 | `adb shell 'su -c id'` → `uid=0(root) … context=u:r.ksu:s0` |
| 注入框架 | **Vector v2.2 (3080-88f8e1fa-JingMatrix-Vector)**，Zygisk Next 1.5.0 | `/data/adb/modules/zygisk_vector/module.prop` |
| 框架 API | `Framework Version: 2.2 / Version Code: 3080 / API Version: 102 / Enabled Modules: 30` | `su -c "/data/adb/lspd/cli status"` |
| legacy 兼容 | `VectorLegacyBridge` → `Loading class com.xposed.XSupport` | `/data/adb/lspd/log/modules_*.log` |
| 目标 App | 微信 8.0.78（`com.tencent.mm`）、TIM 4.1.0、Telegram 12.10.1、X、QQ、飞书 | `pm list packages -3` |
| 先例 | `dev.ujhhgtg.wekit`（WeKit `git+b22aa570`）**enabled 且 scope = `com.tencent.mm/0`** | `cli --json scope ls dev.ujhhgtg.wekit` |
| jev 现状 | `com.jev.probe` 1.8 / versionCode 9 已装 | `dumpsys package com.jev.probe` |
| 设备缺件 | **无 `sqlite3`** → 读 DB 得走框架 CLI 或自带实现 | `which sqlite3` → not found |

**验收闭环因此可以完全脚本化**：

```bash
su -c "/data/adb/lspd/cli modules enable com.jev.probe"
su -c "/data/adb/lspd/cli scope add com.jev.probe com.tencent.mm/0"
adb shell am force-stop com.tencent.mm   # 再打开聊天页
su -c "tail -n 200 /data/adb/lspd/log/modules_*.log"
```

---

## 3. 两个参考项目各自能给什么

### 3.1 yanwai = 注入层技术（可直接搬）

yanwai 是微信专用 LSPosed 模块（`dev.jev.wechatmood`，174 个 .kt，Kotlin + DexKit）。**绝不自动发送**，只复制——与 jev 的同一条底线。

| 技术 | 位置 | 为什么值得搬 |
|---|---|---|
| 直接入口，不依赖 initZygote | `app/src/main/assets/xposed_init` 内容 = `dev.jev.wechatmood.xposed.HookEntry`（纳入 Git） | 入口可控、可 diff |
| 双挂载点 | `xposed/HookEntry.kt`：hook `Application::attach` **和** `XposedBridge.hookAllMethods(Instrumentation::class.java, "callActivityOnResume")` | 注释原话：覆盖「在 Application.attach 之后才挂载的模块加载器」。只挂一个会漏 |
| 进程级门槛 | `if (param.packageName != "com.tencent.mm" \|\| param.processName != "com.tencent.mm") return` | 必须同时判进程名，否则会注进 `:push` 等子进程 |
| **复用宿主已打开的 DB 句柄** | `hook/ReplyDatabaseHistory.kt`（166 行）：hook `com.tencent.wcdb.compat.SQLiteDatabase` / `com.tencent.wcdb.database.SQLiteDatabase` 的 `rawQuery` + `rawQueryWithFactory`，只在 `beforeHookedMethod` **observe** 活句柄（`WeakHashMap` 判重 + `ArrayList<WeakReference>` 最多 4 个），靠 `getPath()` 尾部 `/EnMicroMsg.db` 认主库；查询用宿主自己的 `rawQuery(String, String[])`，`ThreadLocal<Boolean> moduleQuery` 防重入 | 注释原文：「Reuses WeChat's open WCDB handle. **Never opens files, obtains keys, writes, or closes its database.**」——拿到真实历史（`SELECT * FROM message WHERE talker = ?`），却不碰密钥、不解析文件、不写、不关。这是「读得多」与「不越界」唯一能同时成立的姿势 |
| 两级类定位 | `hook/AdapterLocator.kt`：①结构探测（遍历稳定锚点 `ChattingUIFragment`/`ChattingUI` 的 `declaredClasses`，找 `isAssignableFrom` 到 `BaseAdapter`/`RecyclerView$Adapter` 的类，毫秒级）；②DexKit 特征搜索 `getView`、`paramCount = 3`、`returnType = "android.view.View"` | 注释原话：「只按参数个数匹配」（类型不确定时传 null 会让 paramTypes 重载歧义），且 `getView(int,View,ViewGroup)` 是框架约定、混淆改不掉。**先探测后 DexKit**，bridge 用完立刻关闭 |
| 跨进程桥 | `core/SettingsProvider` + `core/SettingsConnectionService` + 签名级权限 `…permission.SYNC_SETTINGS`；Provider UID 白名单 | 模块在目标进程里，设置/结果要过进程边界 |
| OPPO/Android 16 教训 | `docs/BACKGROUND.md`：2.6.8 因连续 `Unknown authority dev.jev.wechatmood.settings` 加**备用连接**——Provider 取不到时显式绑定 `SettingsConnectionService`，最多等 4 秒；设置带**单调递增版本号**，迟到广播不能覆盖新配置或恢复已清空的 Key；已发出的操作不换通道重放 | **这台手机就是 OPPO + Android 16**，这个坑必然复现，第一天就要带上 |

### 3.2 wenyi = 长上下文质量工程（与聊天域无关，但机制可搬）

wenyi 是长篇图书翻译工具（Python/uv/Tauri/Postgres）。机制：

| wenyi 机制 | 搬到 jev 是什么 |
|---|---|
| **全书预扫** → 每章摘要 + 书级 synopsis，**注入每一个批次** | **会话台账**：对 N 条历史做一次预扫 → 人物/称呼/关系/在办的事/禁区/语气基线，注入每一条回复提示词。对抗「只看见屏幕上这 8 条」的上下文饥饿 |
| **实时术语表** + 冲突检测，反馈进后续批次 | **称呼与术语一致性表** + 冲突检测：一轮里不能中途换称呼 |
| **多阶段**：翻译 → 润色 → **证据驱动的全书 Review** | 现有 judge → draft → rank 之后加**证据复查**阶段，能带理由否掉候选 |
| **断点续跑**：批次检查点 + 章节状态 | 会话状态做内容寻址缓存，历史没变就不重扫；失败可续 |
| **按操作路由模型**（per-operation） | judge / draft / **review** 三路可各自配连接（现有 `judge*`/`reply*` 已是两路，加第三路） |

> 实测缺口正好对上：`_reports/roleplay-quality_report.md` 与 `_reports/reply-aiming_report.md` 的结论是「首选候选仍会选错」——缺的就是那个「带证据复查」的阶段。

---

## 4. 目标架构

### 4.1 一个 APK，两张面孔

```
com.jev.probe（同一个 APK）
├─ 面孔 A：独立 App —— 无障碍 + 截屏/OCR。零注入、零 root，永远可用（默认路径）
└─ 面孔 B：Xposed 模块 —— 同一份 APK 声明自己是模块
     assets/xposed_init → com.jev.probe.module.JevHookEntry
     Manifest meta-data：xposedmodule / xposeddescription / xposedminversion / xposedscope
     只在「框架已启用 + 已授权作用域 + 该 App 在设置里开着注入」时生效
```

依赖按 yanwai 的取舍：`compileOnly("de.robv.android.xposed:api:82")`（运行期由框架注入）+ DexKit 若需要则 `implementation`（要在目标进程里运行时读 dex）。**注意 yanwai 记录的版本坑**：YukiHookAPI 1.3.2 的 AAR 声明 `minCompileSdk=37`，且拉 core-ktx 1.17.0 / appcompat 1.7.1 要求 compileSdk 36/37 + AGP 8.9.1+，而 `platforms;android-37` 在 Google 仓库不存在 → **不引 YukiHookAPI，直接用 legacy API**（Vector 已证明兼容 `com.xposed.XSupport`）。jev 现为 AGP 8.7.3 + Kotlin 1.9.24，保持不变。

### 4.2 能力阶梯（逐级降级，永不阻塞）

```
ChatSnapshot ←── CaptureSource（按优先级取最高可用一级）
   L2 历史源  宿主已打开句柄 → 屏幕外的真实历史（N 条）
   L1 注入源  消息对象直读   → 全保真正文 + 发送者 + 时间 + 消息 id
   L0 无障碍  现有适配器 + 微信像素/OCR  ← 兜底，永远在
```

规则：
- **注入层不许阻塞**：jev 从模块发布的有界快照读，硬超时（复用现有 `withHardTimeout`）；未命中/超时/异常 → 立刻回落 L0，并把原因写进 `Trace`。
- **默认关闭、按 App 显式开启**；`SettingsActivity` 里每个 App 一行开关，关掉即回到今天的行为。
- `ChatSnapshot` 扩展（向后兼容，默认值不影响现有构造点）：`provenance`（哪一级产出）、`history`（屏幕外消息）、`messageIds` / `timestamps` / `senderName`。面板与日志显示 `provenance`，降级可见而非静默。

### 4.3 跨进程桥（带上 yanwai 的 OPPO 教训）

- 模块侧（目标 App 进程内）把当前快照写进**有界环形缓冲**（不是任意 SQL 面）。
- 导出 `ContentProvider`（UID 白名单：只接受本应用与目标 App 的 UID）+ **签名级权限**。
- 推送用签名级广播，带**单调递增版本号**，迟到消息不能覆盖新状态。
- **Provider 取不到时显式绑定备用 `Service`，最多等 4 秒**——yanwai 2.6.8 为 OPPO/Android 16 加的，本机同款机型/同版本，不带上必然重踩。

### 4.4 安全与知情同意（不可谈判）

- 逐 App opt-in，**默认关闭**；L0 永远可用。
- 设置页原文呈现风险，取自 yanwai `docs/INLINE_RENDERING_RISK.md`：
  - 微信协议 **8.2.1.4–8.2.1.7** 限制未经授权的插件接入、对运行数据和客户端的读取或干预；**8.5.1** 处理包括功能限制、账号封禁；
  - 原文结论：「**不能由『只读、不发消息』推导出不会封号**」；「若优先保护日常主账号，不建议继续以 LSPosed 注入方式推进」。
  同一类风险适用于任何被注入的 App，不止微信。
- `Trace` 记录每条快照的来源与降级原因（注入被禁/超时/类定位失败），不静默。
- 三条老底线**一条不动**：绝不自动发送、绝不写入或修改目标 App 的数据、不碰转账/红包。

---

## 5. 分片计划（每片独立可交付、独立可验收）

| 片 | 内容 | 需要 root/hook | 可量化验收 |
|---|---|---|---|
| **S1** | wenyi 那半：会话台账（预扫→人物/称呼/关系/在办/禁区/语气）、称呼一致性表 + 冲突检测、**证据复查**阶段、每操作模型路由（第三路 review） | 否 | `eval_roleplay.py` / `eval_aiming.py` 前后对比；`roles` 夹具单测 |
| **S2** | 模块骨架：`assets/xposed_init` + Manifest meta-data + `HttpScope` 式不阻塞契约 + 跨进程桥（含备用 Service/版本号）+ `Trace` 来源标注 + 设置页逐 App 开关 + 风险原文 | 是 | 装包 → `modules enable` → `scope add` → 重启微信 → 框架日志出现模块入口行；**此时仍走 L0 采集**，行为与今天一致（可回归对照） |
| **S3** | L1 注入源：微信消息对象直读（保真正文 + 发送者 + 时间 + id + 屏幕外消息） | 是 | 同一聊天页 L0 vs L1 快照对拍，逐条比对 |
| **S4** | L2 历史源：复用宿主已打开句柄读 N 条真实历史（不落盘、不取密钥、不写、不关） | 是 | 对拍屏幕外历史；确认无写操作、无密钥读取 |
| **S5** | 微信内入口/气泡渲染（yanwai 里风险最高的一项） | 是 | **最后做，仅当用户明确要求** |

S1 与 S2 可并行（不同目录）；S3/S4 依赖 S2；S5 依赖 S3。

### 进展（2026-10-06，真机 OnePlus PJE110 / Android 16）

- **S1 完成** → `_reports/s1-ledger-review_report.md`
- **S2 完成** → `_reports/s2-injection-layer_report.md`
- **S3 试点用的是 Telegram，不是微信。** `HookTargets.SCOPED` 目前只有 `org.telegram.messenger`，`TelegramInjector` 也只读 Telegram 的对象；方案 S3 原指的宿主（微信）尚未开始。
  真机跑通 → `_reports/s3-telegram-l1_report.md`：
  `tg push src=adapter:ChatActivity.chatAdapter scanned=60 msgs=60 chars=2880`，App 侧 `provenance=inject snapshot=msgs=40 me=0 other=40 titleLen=4`、`accepted=true`。
  关掉注入开关后：模块侧 `idle … 注入开关关闭，未安装任何读取钩子`，App 侧 `provenance=a11y`，行为与 S3 之前一致 —— **不用 LSPosed 照旧可用**这条硬约束已实测。
- **退出聊天页会主动撤回快照**（本轮补的真 bug）：原来退出后模块什么都不推，账本里上一条一直留着，从会话 A 切到 B 时可能拿 A 的内容当当前会话；账面 120 秒 TTL 只把最坏情况压到两分钟。现在退出即推空快照撤回，App 侧 `skip=empty` 落回 L0。真机：`tg retract 退出聊天页，已撤回上一条快照` + 12 秒内 14 次 `inject … skip=empty`。
- **S3 未完成的验收**：原定「同一聊天页 L0 vs L1 **逐条**对拍」只做到「能比、能比出差异」。`SnapshotDiff` 现在有位置对齐 + 分边/正文差异 + **位置无关的重叠数**（`overlap=`），但逐条对齐的语义（错位时怎么算）还没定义；更要紧的是 **Telegram 上 L0 读到的就是 0 条**，真机 `overlap=0` 是「没得比」而不是「比出来一样」，这条规则目前只有单测覆盖。要真正验收对拍，需要一个**两层都读得到**的宿主（微信已装，但 `HookTargets.SCOPED` 里还没有它）。

---

## 6. 必须由用户授权的硬约束修订

`CLAUDE.md` 第 1 条**现文**：

> 1. **不 hook、不 Xposed、不改目标 App、不读其数据库**。只用系统无障碍服务与截屏。

与 m02493 新指令**直接冲突**。建议改为：

> 1. **默认不 hook、不注入**：无障碍 + 截屏是默认且永远可用的路径。注入层（LSPosed/Vector）为**可选增强**，按 App 显式开启、默认关闭。**绝不修改或写入目标 App 的任何数据**；读目标 App 数据只允许复用宿主**已打开**的句柄做只读查询，**绝不自行打开文件、获取密钥、写入或关闭宿主数据库**。

其余硬约束全部保持：绝不自动发送、`accessibility_service_config.xml` 不加 `isAccessibilityTool`、不碰转账/红包、路径全 ASCII、密钥不落盘/不进日志/不进 git（任何文件不许出现 `sk-or-`）、UTF-8、**禁止 git commit/push**、Kotlin + 传统 View 禁 Compose、`$x` 后紧跟中文标点一律写 `${x}`。

另注：`CLAUDE.md` 写的目标机是「小米 14 / HyperOS 3.0」，**与实际设备（OPPO PJE110 / Android 16）不符**，一并修订。

---

## 7. 待拍板

1. 是否授权上述 `CLAUDE.md` 第 1 条修订（这是整个方案的前提）。
2. 试点 App：技术上微信最优（L0 最弱、先例最足、yanwai 技术直接对应）；但要看用户实际在哪个 App 上做文爱/网调测试。
3. 是否按 S1→S2→S3→S4 顺序推进，S5 暂缓。
