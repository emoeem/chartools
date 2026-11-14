# Root/Xposed 注入层设计（chartools-next）

- 状态：设计稿（待评审）
- 读者：工程部实现者；假设已读 `docs/architecture.md` §6.1（采集服务接缝协议）
- 参考实现（只读）：`_reference/chartools/cn/app/src/main/java/com/jev/probe`（下称 REF）
- 来源声明：`chartools-next/README.md:15-16`——Android 采集层自旧仓库 Kotlin 移植进插件，
  **「旧仓库的 Xposed 注入模块未随迁」**。本文是把它迁回来的方案。
- 证据说明：REF 工作区缺少 `root/` 生产包、`res/values/arrays.xml`、`assets/xposed_init`
  （promisor 半克隆、联网补拉超时未取回 `git cat-file --batch-check` 报 missing）。凡标
  `git HEAD:` 的内容是从该仓库本地 git 对象库读出的 HEAD 版本（`git cat-file blob`）；
  `xposed_init` 与 `arrays.xml` 的**文件内容未能读到**，正文按引用它们的代码与测试转述，
  不编造。

---

## 1. legacy 体系盘点

### 1.1 Root 在 legacy 里的真实角色

**Root 不在采集链路上。** legacy 的事实结构是三层，root 只是最外层的"环境底座"：

```
[环境层] root（KernelSU）+ Zygisk Next + Vector 2.2（LSPosed 现代分支）
              ↓ 提供注入框架的运行环境（zygisk 注入宿主进程）
[注入层] module/ 包：JevHookEntry / TelegramInjector / TelegramMessage
         跑在目标 App 进程里，反射读宿主已构造好的消息对象
              ↓ 跨进程桥（bridge/，广播为主）
[采集层] capture/ 包：ChatCaptureService（无障碍 L0）+ InjectionSource（L1）
         跑在本 App 进程里，汇合点在 ChatCaptureService.kt:525-526
```

- root/框架的作用只有一件事：把模块代码送进目标 App 的进程（Zygisk + LSPosed 机制）。
  注入代码本身**不需要 root**——这是 `BridgeAuth.kt:8-12` 明文的设计前提
  （"注入层自己的代码根本不需要 root"）。
- root 在 legacy 里的**第二用途**与注入无关：`root/` 包的自愈功能（修无障碍掉绑、
  悬浮窗 appops、省电白名单），详见 §5.2 的如实评估。
- 环境实测底账（`cn/docs/lsposed-enhancement-plan.md` §2）：OPPO PJE110 / Android 16
  (SDK 36)；KernelSU（`su -c id` → `context=u:r:ksu:s0`）；Vector v2.2 / API 102 /
  Zygisk Next 1.5.0；框架 CLI 可脚本化（`/data/adb/lspd/cli modules enable|scope add`）。
  目标 App：微信 8.0.78、TIM、Telegram 12.10.1、X、QQ、飞书。

### 1.2 三层的职责边界

**注入层（module/）——"在别人进程里的唯一一段代码"，全部纪律围绕"不许弄坏宿主"：**

| 纪律 | 落点（REF module/） |
|---|---|
| 双挂载点：`Application.attach` + `Instrumentation.callActivityOnResume`（后到的模块加载器靠第二点补挂） | `JevHookEntry.kt:72-99` |
| 入口门槛：`HookTargets.shouldLoad` = 包名在 SCOPED 且**主进程**（`pkg == process`，防注进 `:push` 子进程） | `HookTargets.kt:32-37`、`JevHookEntry.kt:55` |
| 主线程永不干活：初始化丢单线程池（MIN_PRIORITY 守护线程）；问开关是跨进程 IPC，主线程上等 = 宿主 ANR | `JevHookEntry.kt:48-50,106-107` |
| 先装生命周期观察、后问开关（gate 有序广播要等约 700ms，真机教训：等答复回来再挂 resume 钩子就永远收不到） | `TelegramInjector.kt:135-147` |
| 开关默认关、fail-closed：gate 读不到 = 关 = 一个钩子都不装 | `JevHookEntry.kt:141-166` |
| 只读：不 set、不开文件、不碰数据库、不要密钥；异常全咽、退回无障碍 | `TelegramInjector.kt:30-45` |
| 读消息四条路（命名适配器字段 → RecyclerView adapter → 命名列表字段 → 类型兜底），松散路径要求"最后一条必读得出来"防读错列 | `TelegramInjector.kt:497-576` |
| 每秒 tick、只扫最后 60 条、单条 2000 字硬上限；不在聊天页降为 3 秒探测（本机聊天列表与聊天页共用 Activity，停 tick 就再也发现不了） | `TelegramInjector.kt:52-59,112-133` |
| 消息对象三档兜底（`messageText` → `isOut`字段/`isOutOwner()` → `messageOwner.out`），**拿不准返回 null，绝不猜** | `TelegramMessage.kt:16-25` |
| 退出聊天页主动推空快照撤回（账本 120 秒 TTL 只是兜底，撤回才准） | `TelegramInjector.kt:409-436`、`InjectionSource.kt:40-47` |
| 日志只走 `XposedBridge.log`（TAG `JEVINJECT`）：不记正文、不写宿主 filesDir、异常只留类名+前 8 帧 `类名#方法名` | `ModuleLog.kt:6-11,42-53` |
| 版本号用 `BuildConfig.VERSION_NAME`（包可见性挡死了从目标进程 `getPackageInfo` 查自己——真机两次翻车记录） | `JevHookEntry.kt:169-183` |
| 桥协议与注入代码物理隔离：`bridge/` 不 import 任何 xposed 类（本 App 进程也要加载它；模块入口类一旦被本进程引用就是 NoClassDefFoundError） | `JevHookEntry.kt:28-33`、`BridgeTransport.kt:43-46` |

**桥接层（bridge/，15 文件）——跨进程唯一通道，纯逻辑可 JVM 单测：**

- 契约常量一份（`BridgeContract.kt`）：authority、方法名（`gate`/`hello`/`snapshot`）、
  Bundle 键、`MAX_PAYLOAD_CHARS = 24 * 1024`（`BridgeContract.kt:45`）、
  `MAX_PAYLOAD_AGE_MS = 120_000`（`:48`）、拒收原因枚举（`:73-88`）。
- 单调版本（`BridgeOrder.kt:25-29`）：同一 `boot` 内比 `seq` 严格递增，跨 `boot` 比
  发送方墙上时间——防"进程重启后 seq 归零被永远拒收"，也防"旧进程迟到消息覆盖新状态"。
  `boot` 由模块侧每进程生成（`ModuleSession.kt:14-24`）。
- 内存账本（`BridgeLedger.kt:14-81`）：每 App 只留最近一条快照 + 心跳；**不落盘**
  （`:6-9`：聊天正文不因"开着注入"就写进存储）；超 TTL 当没有（`:69-73`）。
- 线上格式（`BridgePayload.kt`）：`v` 必须是数字、只认 `v == 1`（`:44-48`，版本号是
  护栏不是提示）；`messages` 缺失或某条缺 `side`/`text` → 整段判不可信（`:77-84`，
  "半条时间线比没有更坏"）。往返 render/parse 有单测钉住（legacy 测试目录
  `app/src/test/java/com/jev/probe/bridge/` 下 BridgePayloadTest 等 8 个文件）。
- 汇入主链路的形态：`InjectionSource.kt:28-51` 把账本最新快照 parse 成 `ChatSnapshot`
  （`provenance = Provenance.INJECT`），空快照（撤回）落地为 null——不能让一个空的
  顶掉无障碍那一份（`:40-47`）。legacy 汇合点在 `ChatCaptureService.kt:525-526`：
  ```kotlin
  val injected = injection.snapshot(pkg, prefs.injectionEnabled(pkg))
  val rawSnapshot = injected ?: adapter.extract(root, resources)
  ```

**采集层（capture/）——永远可用的底座：** 无障碍 L0 + 截屏 OCR 兜底（L0'）与注入层
无耦合，注入读不到就落回 L0，行为与"完全没装注入"一致（`lsposed-enhancement-plan.md`
§5 进展：关掉开关后 App 侧 `provenance=a11y`，实测回归）。

### 1.3 BridgeAuth 的安全模型

`BridgeAuth.kt:1-28`（纯逻辑，`BridgeAuthTest.kt` 钉住）两条规则：

1. **门是 UID 白名单，不是签名权限。** 注入代码跑在**目标 App 的进程**里，Binder 报的
   是目标 App 的 uid；签名级权限在这里只会把自己人挡在门外——目标 App 不可能持有
   我们的签名（`BridgeAuth.kt:5-8`）。所以 `allows()` 只放行两种 uid：
   本 App 自己（`callerUid == ownUid`）与 SCOPED 清单内的目标 App（按 uid 反查包名，
   不是 Intent 自报的包名——`BridgeSender.kt:17-19`、`BridgeDispatch.kt:42-44`）。
   `HookTargets.SCOPED` 由模块入口自己再判一次，不只信框架放宽过的 scope
   （`HookTargets.kt:6-9`）。

2. **故意不放行 uid 0**（`BridgeAuth.kt:8-12` 原文语义）：本机 KernelSU 可用，
   `su -c` 起来的东西就是 root；放行 0 等于给任何拿到 root 的脚本开一个"读聊天记录"
   的接口，而注入层自己的代码根本不需要 root。**root 不是这条桥的用户，是风险源。**

配套的三道门闩：

- **认不出人就不认**：`exported=true` 的广播接收器（`cn/app/src/main/AndroidManifest.xml:104-108`）
  没有签名权限可挡，门禁只能靠发送方 uid；Android 14 以下没有 `getSentFromUid()`、
  或 uid 为 `INVALID_UID` 时一律拒收（`R_NO_SENDER_UID`，`BridgeReceiver.kt:47-51`、
  `BridgeSender.kt:33`）。发送侧必须 `BroadcastOptions.setShareIdentityEnabled(true)`
  才给真值（`BridgeTransport.kt:142-162`，少这一步 = 整个注入层静默失效，真机实测）。
- **派发不抛异常**：`onReceive` 在本 App 主线程被系统调用，抛 SecurityException =
  自己崩；拒收统一回 `{accepted=false, reason}`（`BridgeDispatch.kt:22-29`）。
- **有界 + 不落盘**：payload 超 24k 字符整条拒（不截断——截断的 JSON 解析出来是半条
  时间线，`BridgeContract.kt:40-45`）；账本只在内存。

---

## 2. 新架构方案（Flutter 时代怎么放）

### 2.1 注入模块的工程形态：仍是独立原生工程，不进 Flutter

**结论：模块代码是一个独立的 Android 原生 Gradle 工程，只吃 Xposed legacy API；
构建产物以 AAR 并进主 APK，维持 legacy「一个 APK 两张面孔」。**

```
chartools-next/
├── app/                                # Flutter 壳（Dart/引擎，不 import xposed）
│   └── android/
│       ├── app/                        # 主 APK：清单 + assets/xposed_init + arrays.xml
│       └── xposed/                     # ★ 新增独立 Gradle library 模块（纯 Kotlin）
│           └── src/main/java/dev/chartools/capture/xposed/
│               ├── JevHookEntry.kt     # 入口（自 REF JevHookEntry.kt 移植）
│               ├── ModuleSession.kt / ModuleLog.kt
│               ├── TelegramInjector.kt / TelegramMessage.kt
│               └── （bridge 纯逻辑改放 capture_android 插件，见 §2.4）
└── packages/capture_android/           # 采集插件：接收端（receiver/账本/汇合点）
```

选型理由（对照被否掉的替代方案）：

- **为什么不做成 Dart/Flutter 代码**：Xposed API 只在宿主（目标 App）进程里可用；
  legacy 教训——模块入口类被本 App 进程加载即 NoClassDefFoundError
  （`JevHookEntry.kt:28-33`）。它天生是原生代码，`core 零第三方依赖`的哲学也不允许
  Dart 侧出现 xposed 概念。
- **为什么保持「一个 APK 两张面孔」而不是独立模块 APK**：
  1. gate 要读本 App 的逐 App 开关（legacy `Prefs.injectionEnabled`），同 APK 同 uid
     才能免桥互查；`BridgeAuth.allows` 的"自己人"分支（`callerUid == ownUid`）零成本成立。
  2. `hello`/版本自报依赖 `BuildConfig.VERSION_NAME`（`JevHookEntry.kt:169-183`：
     包可见性挡死从目标进程反查自己）——同 APK 时模块与 App 版本天然同源。
  3. 用户安装面不变：装一个 APK，LSPosed 里勾一次作用域。
- **为什么不引 YukiHookAPI**：legacy 实测它声明 `minCompileSdk=37` 而
  `platforms;android-37` 在 Google 仓库不存在，`de.robv.android.xposed:api:82`
  是唯一能在 compileSdk 35 直接编译的；Vector 2.2（API 102）兼容 legacy API
  （`JevHookEntry.kt:23-27`、`cn/CLAUDE.md` 框架说明）。新工程照搬：
  `compileOnly("de.robv.android.xposed:api:82")`。
- 主 APK 侧声明（对照 legacy Manifest）：
  `xposedmodule` / `xposeddescription` / `xposedminversion=82` / `xposedscope=@array/xposed_scope`
  四个 meta-data + `assets/xposed_init` 一行入口类。**`xposed_init` 的内容在 REF 里
  读不到（blob missing），按 `JevHookEntry.kt:20-21` 的声明与 yanwai 先例
  （`lsposed-enhancement-plan.md` §3.1）推定为单行入口类名 `dev.chartools.capture.xposed.JevHookEntry`，
  实现时以构建产物核对。**
  - fix(移植)：`xposed/` 若为 library 模块，AGP 8 的 library BuildConfig 默认**没有**
    `VERSION_NAME`——legacy 是 app 模块直取。移植时用 `buildConfigField("String", "XPOSED_MODULE_VERSION", "\"…\"")`
    显式注入（或从 `app` 模块的 BuildConfig 传常量），否则 `ourVersion()` 拿不到版本号，
    `hello` 报文缺 `module_version`。

### 2.2 桥的选型：广播为主通道（ContentProvider / Binder 为辅）

legacy 用真机实测把这个问题钉死了，新设计沿用并给出对比：

| 通道 | 目标 App 进程 → 本 App 方向 | 结论 |
|---|---|---|
| **显式广播** | 可用。投递由系统完成，发送方不需要解析出接收方——目标 App 对本 App 的**包可见性**挡不住它。代价：发送方要 `setShareIdentityEnabled(true)`（API 34+），接收端 fail-closed 判 uid | **主通道** |
| ContentProvider（`call()`） | 死路：模块用目标 App 的 UID+Context，`acquireUnstableContentProviderClient` 返回 null（Android 16/Telegram targetSdk 36 实测） | 保留为**备通道**，只服务不受可见性限制的调用方（本 App 自己、root 调试对照） |
| Binder（AIDL Service 绑定） | 死路：`bindService` 返回 false（同一可见性原因） | 保留为备通道的备（OPPO/Android 16 上 Provider 也返回 null 的机型），legacy 已验证此坑（`BridgeConnectionService.kt:11-16`） |

legacy 证据：`BridgeContract.kt:22-31`（provider=null / bindService=false /
getPackageInfo 抛 NameNotFound 三条实测记录）、`BridgeTransport.kt:22-31`（"广播是
唯一走得通的方向"）。新设计的桥结构：

```
主通道  显式广播（ACTION = dev.chartools.chartools_app.bridge.CALL）
        .setPackage(新 OWNER_PACKAGE) + FLAG_INCLUDE_STOPPED_PACKAGES   ← 覆盖装后 stopped 包收不到点名广播（BridgeTransport.kt:133-138 真机教训）
        gate = 有序广播等答复（上限 4s，等不到 = 关）；hello/snapshot = 单向 fire-and-forget
备通道  BridgeProvider（call-only）+ BridgeConnectionService（AIDL IBridgeConnection，BIND_TIMEOUT 4s）
        ——回退发生在派发之前，同一次推送不会双投（BridgeTransport.kt:249-256）
```

新工程里这 15 个文件的落点与取舍：

| REF 文件 | 去向 | 说明 |
|---|---|---|
| BridgeContract / BridgeAuth / BridgeSender / BridgeOrder / BridgeLedger / BridgePayload / SnapshotDiff / InjectTimeline / HookTargets | `packages/capture_android/android/src/main/kotlin/dev/chartools/capture/bridge/`（纯 JVM 逻辑，零 android/xposed import） | 8 个 JVM 单测自 legacy `bridge/` 测试目录对位移植；HookTargets 的 arrays.xml 同步钳制测试照旧 |
| BridgeDispatch / BridgeStore / BridgeReceiver / BridgeProvider / BridgeConnectionService + `IBridgeConnection.aidl` | 同目录（android 依赖层） | Receiver 在 `packages/capture_android` 的 library 清单注册，**类名必须全限定**（该清单已注明：相对名会被按宿主包名解析而落空，见其 CaptureService 声明注释） |
| InjectionSource | 汇合点逻辑并入 §2.3 的接缝 | 不再单独成类也可，但保留同名语义便于对拍 legacy |

### 2.3 快照汇合点：同一个 ChatSnapshot 合同，双后端

**合同已经在新仓库就位，一处都不用改：**

- Dart：`packages/core/lib/src/models/models.dart:84` `ChatSnapshot`（含 `history`、
  `confidence`、`uncertain`）；`models.dart:11-33` `Provenance` 已有
  `a11y / ocr / inject / desktop` 四层号与 `labelOf`（`inject => '注入'`）。
- Kotlin（插件）：`Model.kt:18-27` 同名 `Provenance` 含 `INJECT = "inject"`；
  `Model.kt:36-42` `Msg` 的 `id/at/sender` 注释即"只有注入层填得出来"；
  `signature()` 两侧口径钉死（末 6 条 `side:text`，`Model.kt:89-90` ↔
  `models.dart:153-156`，金样契约测试两侧对拍）。
- 新 `CaptureService` 已声明注入层"不随迁"（`CaptureService.kt:30-34`），但给未来
  留了基线：`CaptureService.kt:1410` "provenance==ocr 基线 0.6，其余（a11y；
  **inject 将来若有**）基线 1.0"。

**双后端拓扑（新）：**

```
                ┌────────────────────────────────────────────────┐
[后端 A：L0 无障碍/OCR]                                          │
  事件(WINDOW_STATE/CONTENT) → 300ms 防抖 → ChatAppAdapter.extract│
  （现状 CaptureService 主链路，一字不动）                          │
                ├──→ 汇合点（CaptureService 内）──→ snapshotJson ──→ EventChannel
                ┤              inject 优先，?: 回落                  │   （capture_android/snapshots）
[后端 B：L1 注入]                                                ↓
  目标 App 进程 JevHookEntry → TelegramInjector(1s tick)          │
    → BridgePayload.render（provenance=inject）                   │
    → 广播 → BridgeReceiver → BridgeLedger(内存, TTL 120s) ────────┘
```

- **汇合点语义照搬 legacy 一行**：接缝里 `inject ?: a11y`（legacy
  `ChatCaptureService.kt:525-526`）。落点放在 `CaptureService` 的事件处理处：每轮
  防抖取快照前先问 `BridgeLedger.latest(pkg)`，有未过期的 `inject` 快照就用它，
  否则走 `ChatAppAdapter.extract`。
- **撤回语义照搬 legacy**：模块退出聊天页推空快照 → 汇合点把它当"无数据"（null），
  绝不让空快照顶掉 L0（legacy `InjectionSource.kt:40-47` 的教训原样保留）。
- **置信度**：`inject` 快照 `confidence=1.0`、`uncertain=[]`（发送者解析失败时
  `sender=null` 属少数派，不整条降级；legacy `TelegramInjector.kt:661-688` 一次失败
  永久停用发送者解析，只留"对方"）。G3 门控（`CaptureService.kt:1410` 基线注释、
  app 侧 ≤0.5 不自动分析）天然不动。
- **对拍（可验收）**：`SnapshotDiff` 移植后按 legacy 的 `compareSources` 开关
  （legacy `Prefs.kt:459-462`）在同页双层各读一遍，Trace 只落计数不落正文
  （`SnapshotDiff.kt:41-50`）。legacy 的未完成项如实记录：Telegram 上 L0 常读到 0 条，
  `overlap=0` 是"没得比"；真正对拍验收需要两层都读得到的宿主（legacy 方案 §5 进展 4）。
- **下游链路零回归（本设计的红线）**：快照经同一 `snapshotJson` 进 Dart 后，
  `CaptureSession`（app/lib/application/capture_session.dart:145,772 `_onSnapshot`）、
  `capture_page` 的 `scenarioId`/`knowledgeBase` 透传（app/lib/ui/capture_page.dart:73-122,
  242,252）、专家套用链（`StyleSource` packages/core/lib/src/persona_kb/style_source.dart:27、
  `ExpertApply` …/expert_apply.dart:143、`ContactStore` app/lib/application/contact_store.dart:175）
  全部**不感知来源**——它们的输入是 `ChatSnapshot`，不是通道。快照卡上只多一个
  `Provenance.labelOf` = "注入" 的标注（capture_session.dart:685）。
- **已知取舍**：无障碍服务关闭时 `CaptureService` 不存在，注入快照无人接。决定：
  **不**为此开第二条 Dart 直通路径（避免第二个发射源与 pending-latest 去重打架），
  M1/M2 明确"采集页开着（无障碍启用）"是注入层的使用前提——这与现有引导流一致，
  且把暴露面缩到最小。若日后要支持，方案是 BridgeReceiver 直发 EventChannel
  （复用 `CaptureService.flutterMessenger` 静态挂接），单独立项评审。

### 2.4 新包名 `dev.chartools.chartools_app` 对桥白名单的影响

applicationId/namespace 已是 `dev.chartools.chartools_app`（`app/android/app/build.gradle.kts:11,26`）。
逐项过一遍：

| 项 | legacy 值 | 新值 / 影响 |
|---|---|---|
| `BridgeContract.AUTHORITY` | `com.jev.probe.bridge` | 改 `dev.chartools.chartools_app.bridge`；Provider 备通道同步改 |
| `OWNER_PACKAGE` / `ACTION` | `com.jev.probe` / `com.jev.probe.bridge.CALL` | 同步改名（`BridgeTransport.intentFor` 点名投递的目标）；清单 `<queries>` 声明的是**目标 App**（`org.telegram.messenger`，legacy Manifest:32-34），不受自己改名影响，照抄 |
| `BridgeAuth.allows` 的 `ownUid` | `Process.myUid()` 运行期取 | 无需改——白名单逻辑与包名解耦（`BridgeAuth.kt:14-15`：规则与 Android 无关，callerPackages 由 PackageManager 解析传入） |
| `HookTargets.SCOPED` | `["org.telegram.messenger"]` | **不变**——白名单锁的是"谁在说话"（目标 App 的 uid），不是本 App 包名；自己的改名不影响它。`arrays.xml` 的 `xposed_scope` 与之保持一致（内容在 REF 读不到，以 `HookTargets.kt:6-9` 的钳制测试为准重写） |
| LSPosed 侧 | 模块包名 = `com.jev.probe` | 模块包名变为新包名 → **必须重新授权作用域**（Vector/LSPosed 的 scope 是按模块包记录的）；框架里旧条目作废 |
| 旧版共存 | — | 旧 APK（含旧模块）若还在设备上：旧模块在新框架 scope 里已无效；若用户手动给旧模块也勾了 Telegram，会出现**双模块同 hook 目标**（两份 `JEVINJECT` 日志、两路广播互不串台——点名投递 setPackage 各回各家）。验收清单加一条：装新版前卸载 `com.jev.probe` |
| root 自愈常量（若迁，§5.2） | `A11ySettings.COMPONENT = "com.jev.probe/…ChatCaptureService"` | 必须改写为新组件 `dev.chartools.chartools_app/dev.chartools.capture.CaptureService`（A11ySettings 测试里的"真机原文"夹具同步重录）；`pm grant`/`appops` 命令里的包名同理 |

---

## 3. 环境与分发要求

### 3.1 用户设备需要什么（root 方案矩阵）

**关键事实：注入层不要求 root；root 只是给"注入框架能跑起来"的环境底座之一，
以及可选的自愈工具（§5.2）。**

| 层 | 要求 | 证据 |
|---|---|---|
| 注入框架 | **LSPosed 系**（含现代分支 Vector ≥2.2，Zygisk Next；API 102 兼容 legacy `api:82`）。**YukiHookAPI 路线排除**（compileSdk 37 装不上） | `JevHookEntry.kt:23-27`；legacy 真机 Vector v2.2 实测（方案 §2） |
| root 方案 | KernelSU / Magisk / APatch 均可——legacy `RootProbe.flavorOf` 按 SELinux 域识别（`ksu`/`magisk`/`apatch|apd`），认不出的域但 uid=0 也算"root"（`git HEAD:cn/app/src/main/java/com/jev/probe/root/RootProbe.kt`，真机原文测试 `RootProbeTest.kt:13-49`） | root 版本不影响注入层；只影响可选自愈的 `su` 入口形状（`RootShell.kt`：只认 `su -c`，不猜路径） |
| Android 版本 | **≥ 14（API 34）**：广播身份（`setShareIdentityEnabled` / `getSentFromUid`）低版本没有，fail-closed 直接让注入层整层不可用（能力栈落回 L0，不崩） | `BridgeTransport.kt:155-162,171-175`、`BridgeReceiver.kt:47-51` |
| 无障碍 | 采集页启用（现有引导流）；这也是注入快照的接收前提（§2.3 取舍） | 现状 |
| 真机基线 | OPPO PJE110 / Android 16（legacy 实测过的组合）；OPPO"Provider 返回 null"机型必须带备通道 | 方案 §2、`BridgeConnectionService.kt:11-16` |
| SUSFS 机型 | App uid 可能拿不到 `su`（legacy 机 `exit=127`）——不阻塞注入；只影响自愈降级路径 | `cn/CHANGELOG.md:288-292` |

分发要求：主 APK（两张面孔）从官网/侧载分发；**上架应用商店的 Xposed 声明需单独评估**
（现有 README 风险声明同理）。模块侧无独立产物，无单独签名/分发问题。

### 3.2 目标 App 覆盖面（HookTargets.SCOPED 现状）

- **注入（L1）：只有 Telegram**（`org.telegram.messenger`）。legacy 的
  `TelegramInjector` 只认 `org.telegram.ui.ChatActivity` + 反射读
  `MessageObject`/适配器（`TelegramInjector.kt:50,693-696`）。legacy 方案 S3 原定
  微信试点，实际改在 Telegram 落地（方案 §5 进展 3），微信注入**从未实现**。
- **无障碍（L0）**：QQ/TIM/飞书/X/WhatsApp/Telegram 六个适配器 + 微信 OCR 兜底
  （新仓库 `ChatApps.kt` 注册表；`ChatAppAdapter.kt:164,269,464,601`、
  `TelegramAdapter.kt:54`、`WhatsAppAdapter.kt:27`（`com.whatsapp`）、
  `WeChatOcrAdapter.kt:38`（`com.tencent.mm`））。
- **微信为什么是注入的强动机、却仍然不做**：微信 8.0.78 给无障碍的是空树
  （`uiautomator dump` 1 节点/407 字节，legacy 方案 §1 结论摘要第 3 条），OCR 是唯一活路；但它的注入同时
  是**账号风险最高**的一条（`HookTargets.kt:13-15` 原话），且 yanwai 先例走的是
  WCDB 句柄路线（方案 §3.1），投入与风险都另成一档。决定：微信注入**不进本期**，
  保留在"将来若做"清单，先在 Telegram 上把整条链立稳。

### 3.3 合规与风险声明（不可谈判，全部沿用 legacy 硬约束）

1. **只读自己参与的会话**：模块只读**当前打开的聊天页**的最后 60 条、
   用户自己已登录的会话；不开文件、不读数据库、不取密钥（`TelegramInjector.kt:30-37`）。
   legacy 的 L2（复用宿主 WCDB 句柄读历史）**从未实现**，也不在本期。
2. **不破坏目标 App**：只 get、绝不 set、不调用改状态的方法；异常全咽；不在宿主
   主线程干重活；装钩子失败 = 退回 L0 而非报错（`TelegramInjector.kt:30-45`、
   `JevHookEntry.kt:162-164`）。
3. **用户明示开启、默认关**：逐 App 开关（`Prefs.injectionEnabled`，legacy
   `Prefs.kt:443-453`）；gate 读不到 = 关；开关关闭时钩子连装都不装、不读、不推
   （`JevHookEntry.kt:153-157`）。
4. **账号风险原文呈现**：设置页必须原文给出（legacy `cn/CLAUDE.md:13`）：微信协议
   8.2.1.4–8.2.1.7 限制未授权插件接入与对运行数据的读取，8.5.1 处置含功能限制与
   账号封禁；**"只读、不发消息"不能推导出不会封号**。Telegram 未在 legacy 留下条款
   原文——设置页按同一精神写"同类风险适用于任何被注入的 App"（方案 §4.4），不编造
   Telegram 条款号。
5. **三条老底线不动**：绝不自动发送；绝不写入/修改目标 App 的任何数据；
   不碰转账/红包（方案 §4.4）。
6. **日志卫生**：注入层只走框架日志，不记正文/标题；桥账本不落盘；诊断行只含类名、
   条数、长度、哈希（`ModuleLog.kt:6-11`、`BridgeLedger.kt:6-9`、`InjectTimeline.kt:61-70`）。

---

## 4. 里程碑与成本

分期原则：每一期独立可验收、可回滚；开关关着 = 行为与今天完全一致（legacy S2 的
验收标准照抄）。下述"门禁"指仓库统一跑的 `flutter analyze` / 各包测试（本设计阶段
未执行任何构建/测试，全部为静态依据）。

### M0 桥契约与接收端（无钩子，纯本 App 侧）

- 内容：`bridge/` 纯逻辑 9 文件 + android 侧 5 文件 + AIDL 迁入
  `capture_android`（§2.2 表）；常量改 `dev.chartools.chartools_app.*`；
  Receiver/Provider/Service 进插件 library 清单（全限定类名）；设置页逐 App 开关 +
  "已连接"状态（对照 legacy 设置页）；`HookTargets` + `xposed_scope` 数组 + 钳制测试。
- 验收：① legacy `bridge/` 8 个 JVM 测试（BridgeAuth/BridgeLedger/BridgeOrder/
  BridgePayload/BridgeSender/HookTargets/InjectTimeline/SnapshotDiff）对位移植后在
  `packages/capture_android/android` 本地跑通（依赖 kotlin-test/mockito 已就位但
  Kotlin JVM 契约测试当前未进 CI——`docs/architecture.md:404`；是否纳入门禁随本
  期一并提请，本文不擅自改变门禁范围）；② 广播身份 fail-closed 分支单测覆盖
  （uid=null / INVALID_UID / 非 SCOPED 三个拒收原因）；③ 开关默认关，
  `flutter test`（app 套件）与 `dart test`（core）零改动全绿；④ 此时**没有**任何
  Xposed 声明，行为与今天一致（可回归对照）。
- 估算：3–5 人日（纯移植 + 改名，风险最低）。

### M1 注入模块骨架 + Telegram L1（真机闭环）

- 内容：`app/android/xposed` Gradle 模块；JevHookEntry/ModuleSession/ModuleLog/
  TelegramInjector/TelegramMessage 移植（含 `xposed_init` + 四 meta-data +
  `xposedscope`）；TelegramInjector 的 `enable()` 在 M1 只装**生命周期观察 + 推送
  快照**（L1 主路径），不碰回填。
- 验收（真机，全脚本化，对照方案 §2 的 CLI 闭环）：
  ① Vector/LSPosed `modules enable` + `scope add` 新包名 → 重启 Telegram →
  框架日志出现 `JEVINJECT entry pkg=org.telegram.messenger`；
  ② App 侧 Trace 出现 `bridge hello accepted=true`、设置页"已连接"；
  ③ 关闭开关重启 Telegram：日志 `idle … 未安装任何读取钩子`，App 侧
  `provenance=a11y`——**不用注入照旧可用**（legacy 硬约束实测项）；
  ④ 聊天页推送 `tg push src=adapter… msgs≤60`，账本 TTL 内 `inject pkg=… msgs=…`；
  ⑤ 退出聊天页 12 秒内出现 `inject … skip=empty`（撤回链路）。
- 估算：5–8 人日（真机联调是大头；`hookHierarchy` 挂零个的坑、双挂载点、
  stopped 包 flag 这些 legacy 教训直接继承，不再踩）。

### M2 汇合点与全链路（注入流并入 CaptureSession）

- 内容：`CaptureService` 汇合点 `inject ?: a11y`；撤回落地 null；`provenance=inject`
  贯通到 Dart（快照卡"注入"标注）；`SnapshotDiff` + `compareSources` 诊断开关；
  `confidence=1.0` 基线写入（对照 `CaptureService.kt:1410`）。
- 验收：① 真机快照卡显示"来源：注入"，候选流正常起草/回填；
  ② **红线回归**：capture_page 的 `scenarioId`/`knowledgeBase` 透传链
  （capture_page.dart:73-122）与专家套用链（StyleSource/ExpertApply/ContactStore）
  的既有 app 测试全绿；注入快照与无障碍快照在两套测试里的行为逐字段一致
  （除 `provenance` 与 `id/at/sender` 的有无）；③ G3 门控对 inject 快照不触发
  （1.0 基线）；④ SnapshotDiff 在 Telegram 真机产出 `cmp … overlap=` 行
  （"能比、能比出差异"即可，legacy 的"逐条对拍"语义缺口如实带过来，不假装补齐）。
- 估算：4–6 人日。

### M3（可选）root 自愈工具页

- 内容与取舍见 §5.2：若拍板迁移，范围为 RootFix/RootProbe/RootShell/A11ySettings
  四件 + 新组件名常量 + `rootAuto` 开关（默认关）+ 广播触发 Receiver。
- 验收：① 无 root 设备上每一步都如实报"跳过/手动"，不假装成功；② WRITE_SECURE_SETTINGS
  一次性 grant 后覆盖安装 APK，无障碍自动重绑（`CapturePresence.live` 翻真为最终判据）；
  ③ 别人的服务（如 ColorOS 取词）在设置格里原样保留（A11ySettings 测试夹具重录后全绿）。
- 估算：3–5 人日。**不做不影响注入层任何功能。**

合计：注入主线（M0–M2）约 12–19 人日；含 M3 约 15–24 人日。

### 与无障碍流（L0）的功能差异表

| 能力 | L0 无障碍/OCR | L1 注入 | 差异来源 |
|---|---|---|---|
| 正文保真 | 气泡文字节点可读（Telegram OK）；微信走 OCR，**有识别误差**、图片/贴纸读不到 | `messageText` 宿主算好的保真正文，**零 OCR 误差** | `TelegramMessage.kt:16-24` |
| 分边（我方/对方） | 气泡布局启发式；OCR 兜底时**大量 side 未知**（SIDE_UNKNOWN） | `isOut` 三档兜底，精确分边 | `TelegramMessage.kt:62-74` |
| 发送人名字 | 无障碍树基本拿不到（`sender=null`） | `MessagesController.getUser` 解析，**精确发言人**（群聊可用；一次失败永久停用该路径） | `TelegramInjector.kt:661-688` |
| 消息 id / 时间戳 | **没有**（节点树不提供） | 有（TLRPC id + date）→ 可做单调去重、跨层对拍 | `Model.kt:32-34` |
| **已发送消息回读** | 弱：自己刚发的气泡是否进树依宿主实现，且只认屏上 | 可靠：消息列表里的 out 消息与收到的同等可读，屏下窗口（60 条）也在 | `READ_WINDOW`、`isOut` |
| 读取深度 | 屏幕视口内（约几条～十几条） | 适配器窗口最后 **60 条** | `TelegramInjector.kt:65` |
| `history`（屏下历史） | 空 | L1 给到窗口内；L2 数据库历史 legacy 未实现，两边都是"有就给没有就没有" | `Model.kt:66-68` |
| 覆盖 App | 7 个（含微信 OCR） | 仅 Telegram | §3.2 |
| 前置条件 | 无（任何手机） | root 环境框架 + API 34+ + 用户逐 App 开启 | §3.1、§3.3 |

即注入流独有的四件事：**无 OCR 误差的保真正文、精确发言人、消息身份（id/时间）、
已发送消息可靠回读 + 更深的窗口**。

---

## 5. 风险与不做清单

### 5.1 风险清单

| 风险 | 缓解（继承 legacy 的即注出处） |
|---|---|
| 注入代码弄崩宿主 | 四铁律：永不抛 / 永不主线程绑 / 永不落盘 / 永不久等（`BridgeTransport.kt:34-43`）；异常咽掉退 L0 |
| 注入层**静默失效**比崩溃更难查 | 广播身份 fail-closed 会让整层无声失效（真机踩过）→ M1 验收第 ③ 步就是验证"关"能被看出来；`miss`/`inputProbe` 诊断行（无正文）随移植保留 |
| Android 版本碎片化 | API <34 直接整层不可用（fail-closed 落 L0），不半吊子工作 |
| 目标 App 改版（类名/字段漂移） | 只认名字不 import，最坏"读不到 → 落 L0"，不会加载期崩（`TelegramInjector.kt:44-45`） |
| 双模块/新旧共存 | 验收清单强制先卸 `com.jev.probe`（§2.4）；点名广播天然互不串台 |
| 商店政策 | 不上架含模块声明的 APK 到商店；官网分发（README 风险声明同源） |
| 门禁 flaky | app 套件 flutter test 失败先复跑再判断（did not complete / Connection closed 类为宿主 flaky，flutter#191069） |

### 5.2 RootFix（root 授权修复）：legacy 确实有，如实评估

**存在性**：legacy 有完整 `root/` 生产包，5 个文件（`git ls-tree HEAD`：
`A11ySettings.kt` 6.0K / `RootFix.kt` 11.3K / `RootFixReceiver.kt` 1.9K /
`RootProbe.kt` 1.9K / `RootShell.kt` 2.7K）+ 清单注册的 `.root.RootFixReceiver`
（BOOT_COMPLETED / MY_PACKAGE_REPLACED / QUICKBOOT / LOCKED_BOOT，`exported=false`，
`prefs.rootAuto` 门控默认关）+ 测试（RootProbeTest / A11ySettingsTest）。注意：
**这 5 个文件不在 REF 工作区**（半克隆 blob 部分缺失 + 本地检出残缺），内容是从
本地 git 对象库读的 HEAD 版本；`RootFixReceiver` 与 manifest 由我读到的原文为准，
其余按 blob 原文。

**它是什么**：与注入无关的**无障碍自愈**。真机事实：覆盖安装/开机后
`enabled_accessibility_services` 一格还在，但服务没在跑（`Bound services:{}`）；
修法是"让那一格变一次"（先写"没有我"再写"有我"，强制重绑）。能力阶梯：
WRITE_SECURE_SETTINGS 一次性 `pm grant`（之后不用 su）→ `su -c "settings put …"`
→ 都没有就明说"只能手动开"（`RootFix.kt` 原文）。涉及的四条命令全部只动**自己**的
状态：无障碍设置格（合并写、绝不清别人的服务——A11ySettings 整个是围绕这个的纯函数）、
悬浮窗 appops、deviceidle 白名单、`pm grant` 自己。

**评估结论：可迁但降级为可选工具（M3），不进注入主线。** 理由：
1. 它解决的是"每天多点两次"的痛点，对**开发期**价值最大（一天装十几次 APK），
   对终端用户价值一般（无障碍开关在引导里已经接好了）；
2. Flutter 化后有两处必须重写——组件常量（新包名/新服务类名，A11ySettings 的
   `COMPONENT` 与测试夹具的"真机原文"）与触发点（legacy 靠 `Prefs.rootAuto`，
   新仓库无对应 prefs，要进 `SettingsStore` + 插件侧桥接）；
3. SUSFS 机型上 `su` 不可达，阶梯第 2 级经常走不到，功能上限天然打折
   （`cn/CHANGELOG.md:288-292`）；
4. 它是全项目**唯一会写系统设置**的地方，安全审查成本不小——独立成期、默认关、
   逐条回显命令真实输出（legacy `FixStep` 设计照搬），评审面最小。

### 5.3 明确不迁清单

| legacy 细节 | 决定 | 依据 |
|---|---|---|
| S5 微信内入口/气泡渲染 | **不迁** | legacy 方案自己定的："最后做，仅当用户明确要求"（方案 §5 表格 S5 行）；全项目风险最高项 |
| L2 历史源（复用宿主 WCDB 句柄读数据库历史） | **不迁** | legacy 只有方案（S4），从未实现（方案 §5 进展只到 S3）；涉数据库句柄观察，安全面另议。`ChatSnapshot.history` 字段保留，将来接 |
| 微信注入 | **不做** | SCOPED 只留 Telegram（§3.2）；风险与收益差距最大的一条 |
| NewMessageGate / 白名单 Prefs / legacy jev 编排 | **不迁** | 新 `CaptureService.kt:30-34` 已声明不随迁；编排归 Dart `CaptureSession` |
| legacy `flows/jev-trace.log` Trace 体系 | **不迁**（新 Trace.kt 已在插件内） | 接缝协议照旧 |
| YukiHookAPI / 现代 Module API | **不迁** | compileSdk 37 坑（`JevHookEntry.kt:23-27`） |
| `su -v` / 版本号判 root 框架 | **不迁**（判据用 SELinux 域） | RootProbe.kt 注释：各家版本号格式不同，不作判据 |
| xposed_init / arrays.xml 的"逐字移植" | **不可行，改为按契约重写** | 两个 blob 本地缺失、联网取回超时，内容未读到；按 meta-data/xposed_scope/入口类名契约重建，用 HookTargets 钳制测试对齐 |

### 5.4 与既有文档的一致性

- `README.md:15-16` 的"未随迁"声明在本方案落地后需更新为"已随迁（本文档）"；
- `docs/architecture.md` §6.1 的"注入层不随迁"句（引用 `CaptureService.kt:30-34`）
  同理，M2 合入时补一行落地记录；
- 本方案不触碰 `docs/migration-design.md` 的任何结论（其 §89 的 root/adb 通道属
  历史数据迁移，与本文无关）。
