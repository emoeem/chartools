# 第一档优化：适配器契约收拢、调试 runner 隔离、剩余反向边解除

日期：2026-10-27 ｜ 范围：`cn/` ｜ 结论：**三项全部落地；cn 620 测试全绿（+5 drift-guard）、debug/release 双变体构建通过、global 回归通过；新增 App 的同步点从 9–11 处降到 2 处**

## 1. 改了什么

### 1.1 适配器契约收拢（`ChatAppAdapter` + `ChatApps` 注册表）

- `ChatAppAdapter` 接口新增 `displayName` / `findInput(root)` / `allowScreenshot`（`capture/ChatAppAdapter.kt`）。六个适配器各自实现：QQ/TIM/飞书精确 view id，X/Telegram 走通用可编辑节点查找（`findEditableNode`，从 InputFiller 迁出），WhatsApp `allowScreenshot=false` 且无 `findInput`（只支持剪贴板填入——与原行为一致）。
- 新建 `capture/ChatApps.kt` 唯一注册表：`all` / `byPackage` / `packages` / `forPackage`。
- `ChatCaptureService`：注册表委托 `ChatApps.byPackage`；`NO_SCREENSHOT_PKGS` 常量删除，三处读取点改为 `adapter.allowScreenshot`；`ForegroundPolicy.needsIdlePark` 改传 `ChatApps.packages`；`InputFiller` 构造传入 `ChatApps::forPackage`。
- `InputFiller.kt` 的 `when(pkg)` 硬编码五分支删除——输入定位归适配器契约，文件里不再出现任何具体包名（grep 零命中）。
- `KnowledgeActivity.appLabel`、`MainActivity` 主页支持列表文案改为从注册表派生（主页文案微信保留在句尾，因其走像素路径）。

### 1.2 调试 runner 挪出 src/main

- `main/.../DebugAcceptance.kt`：钩子挂载点（`hooks: Hooks?`，release 恒 null = 空操作）。
- `src/debug/.../DebugHooks.kt`：真实现（tone_check 试写打真模型、root_fix 回放）+ `DebugHooksInit`（ContentProvider，系统在任何 Activity 之前注册钩子）；`src/debug/AndroidManifest.xml` 只进 debug 变体。
- **注意**：同 FQCN 源集覆盖在 Kotlin 里行不通（debug 变体一次编译 main+debug，重声明报错），所以用 ContentProvider 注册而非类替换。
- `SettingsActivity`：`runToneCheck` 整体迁出；`prefs`/`worker`/`main`/`draftPrefs`/`SCRATCH_REPLY` 放宽为 internal（debug 变体调用面）；删掉"不会编译进 release builds"的假注释。
- `MainActivity`：debug 意图块迁出，`runRootFix` 放宽为 internal。

### 1.3 剩余两条反向边

- `root → capture`：新建 `core/CapturePresence.kt`（服务存活信号）；`ChatCaptureService.live` 变成对它的委托读写；`RootFix` 三处改读 `CapturePresence.live`，不再 import capture。
- `overlay → jev`：`StrategyOrder` 从 `jev/` 移到 `core/`（其唯一调用方是 overlay 的渲染）；测试文件同步移包。overlay 对 jev 的 import 清零。

### 1.4 drift-guard 测试（`ChatAppsRegistryTest`，5 项）

注册表良构（无重复包名、displayName 非空）；输入契约钉住；WhatsApp 永不截屏钉住；`HookTargets.SCOPED` ↔ `arrays.xml xposed_scope` ↔ Manifest `<queries>` 三边逐字一致（测试经 `jev.moduleDir` systemProperty 读源文件，build.gradle.kts 注入——global/core 的 `jev.fixtures` 同款先例）；注入目标必有适配器。

## 2. 验收（真实输出）

```
$ bash gradlew :app:testDebugUnitTest :app:assembleDebug :app:assembleRelease --rerun-tasks
BUILD SUCCESSFUL in 55s  (95 tasks, 95 executed)
cn tests=620 failures=0 errors=0 skipped=2     # 615 → 620（+5 drift-guard）
app-debug.apk 34.4 MB / app-release-unsigned.apk 31.0 MB 均产出

$ cd global && bash gradlew test
BUILD SUCCESSFUL                                # global 未受影响

$ grep -rn 'import com.jev.probe.(jev|capture)' .../core/   → 零命中
$ grep -rn 'import com.jev.probe.capture' .../root/         → 零命中
$ grep -rn 'import com.jev.probe.jev' .../overlay/          → 零命中
$ grep -rn 'com\.tencent|com\.ss\.android|com\.twitter|org\.telegram|com\.whatsapp' capture/InputFiller.kt → 零命中
```

## 3. 自验缺口

- `findInput` / `allowScreenshot` 的行为等价性靠「逐字搬运 + 测试钉住」保证，真机填入/OCR 路径未复测（无设备）。
- `DebugHooksInit` 的 provider 注册在 debug 包构建通过、清单合并无冲突，但未上真机验证 provider 初始化时序。
- drift-guard 读的是**源文件**而非合并后的资源：若有人改构建脚本重命名 res 文件，测试会以 error 提示（`jev.moduleDir` 未设时显式 fail），属可接受口径。
- 主页/知识库文案改为派生后未人工过 UI（纯字符串拼接，风险低）。
