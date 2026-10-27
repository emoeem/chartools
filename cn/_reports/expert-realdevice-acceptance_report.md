# 专家库 S1–S5：真机验收报告（2026-10-27）

设备 `3afd9f4e`（OPPO PJE110 / Android 16）重连后补做的真机验收。上一轮 S1–S5 只做到编译级证据，本报告把它补到"真机跑过、截图在、数字在"。

**结论一句话**：页面全部按设计工作，但真机验收抓到一个 668 个单测都看不见的真 bug —— 补预设时台账没落盘。已修、已加锁、已在真机上 A/B 复验。

---

## 1. 第一个发现：上一轮装的是**旧包**，不是代码坏了

打开专家库第一屏是「共 4 个专家」。S3 明明扩到 14 张。

根因不在代码，在验收用的 APK：

| 证据 | 值 |
|---|---|
| `app-debug.apk` 构建时间 | `10-27 18:38:17` |
| S2 提交时间 | `10-27 18:38:42` |
| S3（预设扩容）提交时间 | `10-27 18:39:31` |
| 该 APK 的 dex 里搜 preset key | `roleplay.dom → 1`，`love.newstage → 0`，`work.push → 0`，`daily.family → 0` |

也就是说这个包是 **S2 验证那一轮** 编出来的，晚于它的三个提交（S3/S4/S5）根本没进包。
重新 `./gradlew :app:assembleDebug` 后 dex 里 14 个 key 全在，装机后首屏即「共 14 个专家」。

> 教训：`assembleDebug` 通过 ≠ 装机包是当前 HEAD。阶段验收必须核对 APK 构建时间晚于本阶段最后一个提交。

---

## 2. 第二个发现：真 bug —— 补预设时 `seeded[]` 没落盘

### 现象（真机文件，不是推测）

修完旧包问题、首屏已经显示 14 张之后，直接读设备上的人设库：

```json
{ "version": 2, "items": [ … 14 条 … ], "seeded": ["roleplay.dom","roleplay.sub","daily.friend","sales.followup"], "removed": [] }
```

`items` 有 14 条，`seeded` 只记了 4 条 —— 那 10 张新预设"送了但没记账"。

### 根因（`PersonaStore.kt` `topUpLocked`）

```kotlin
val items = current.toMutableList()
missing.forEach { items += it.toProfile() }
if (!writeLocked(items)) { … return current }
missing.forEach { seeded += it.key }   // ← 写盘之后才记台账
return items
```

`writeLocked` 序列化的正是**调用那一刻**的 `seeded`。先写盘、后记账 ⇒ 文件里永远少这几笔。

### 为什么 668 个测试没抓到

`aNewPresetReachesAnOldLibraryExactlyOnce` 只断言「补进来的张数」和「再读不回重」。第二次启动不回重是因为 `present`（按 `presetKey` 匹配）已经把这几张挡住了 —— **台账错不错都过得去**。缺的断言是：落盘的 `seeded` 是否等于事实。

### 影响（如实说，不夸大）

不是立刻可见的故障：`present` 兜住了重复播种，`removed` 兜住了删除复活。真正坏的是**不变量本身**——`seeded[]` 这条"播过就是播过"的台账与事实不符，任何将来依赖它的逻辑（重建、去重、迁移判断）都会拿到错的前提。所以按缺陷修，不按"反正是对的"放过。

### 修复

```diff
         val items = current.toMutableList()
         missing.forEach { items += it.toProfile() }
+        // 台账必须在写盘**之前**补上：`writeLocked` 序列化的是此刻的 `seeded`。
+        missing.forEach { seeded += it.key }
         if (!writeLocked(items)) {
```

新增单测 `toppingUpWritesTheNewKeysIntoTheLedgerNotJustTheItems`：造一个 `seeded=[roleplay.dom]` 的旧库，读一次，断言**落盘**的 `seeded` == 全部 14 个预设 key。

### 反向验证（证明这条测试真的会咬）

把修复回退成"先写盘后记账"，只跑该测试类：

```
FAILED: toppingUpWritesTheNewKeysIntoTheLedgerNotJustTheItems
java.lang.AssertionError: 补进来的每张预设都必须落进 seeded[]，否则台账和 items 对不上
expected:<[roleplay.dom, roleplay.sub, daily.friend, sales.followup, love.newstage, …]> but was:<[roleplay.dom, …]>
```

还原修复后该测试通过。

### 真机 A/B（同一条链路，修复前 vs 修复后）

| 步骤 | 修复前 | 修复后 |
|---|---|---|
| 把设备库裁成"老库"（4 条 items、`seeded` 4 条） | `items=4 seeded=4` | `items=4 seeded=4` |
| 启动专家库 | **`items=14 seeded=4`** | **`items=14 seeded=14`** |

---

## 3. 真机验收清单（全部为 `uiautomator dump` 实际文本 / 截图）

| # | 项 | 证据 | 结果 |
|---|---|---|---|
| 1 | 2 列网格 | 同排两张卡 x 区间 `[102,492]` / `[588,978]` | ✅ |
| 2 | 预设 14 张 | 「共 14 个专家 · 当前显示 14 个」 | ✅ |
| 3 | 分类 chip | 全部 / 情感 / 销售 / 职场 / 客服 / 日常（横向滚动，「日常」被右缘切一半=设计如此） | ✅ |
| 4 | 分类筛选 | 点「客服」→「当前显示 2 个」，两张都是客服 | ✅ |
| 5 | 排序「最热」 | 「用过 1 次」的 `客服·售后` 排到第一 | ✅ |
| 6 | 详情弹层 | 专家详情：头像 emoji、名字、简介、`分类：客服 · 未使用`、标签、`识别到的键：主题「客服」· 称呼「您」· 示例 3 句`、正文、编辑/更多/用这个专家 | ✅ |
| 7 | 点「用这个专家」 | `shared_prefs/jev_assistant.xml` 的 `style` 变成该专家 body；该条 `usedCount=1` | ✅ |
| 8 | 热度回显 | 卡片角标从「未使用 · 客服」→「用过 1 次 · 客服」 | ✅ |
| 9 | 设置页入口 | 「人设与语气」区：「当前生效：「客服·售后」」+「打开专家库」按钮 | ✅ |
| 10 | 页面跳转 | 点「打开专家库」→ `topResumedActivity=com.jev.probe/.ExpertActivity` | ✅ |
| 11 | 新建专家 | 表单：名字/一句话简介/头像/标签/分类/人设原文 + 取消/保存；保存后 14→15 | ✅ |
| 12 | 删除自建 | 更多→删除→二次确认「删掉「未命名专家」？已经套用到设置里的文本不受影响。」→ 15→14，`removed` 不新增（自建无 presetKey） | ✅ |
| 13 | 删除预设留墓碑 | 删「恋爱·冷战破冰」→ `removed=["love.coldwar"]`，`items=13`，`seeded` 仍 14 | ✅ |
| 14 | 重启不复活 | `am force-stop` 后重启：`items=13`、`resurrected: False` | ✅ |
| 15 | 恢复内置模板 | ⋯→恢复内置模板 → `items=14 seeded=14 removed=[]` | ✅ |

截图：
- `_reports/shots/expert-grid-20261027.png`（网格 + 分类 chip + 排序 tab + 14 张）
- `_reports/shots/expert-detail-20261027.png`（详情弹层）

硬指标复核（本轮重新数的，不是引用上一轮）：

```
wc -l SettingsActivity.kt      → 1100
grep -c "private fun dp(" …    → 0
```

---

## 4. 测试数字（真实输出）

```
$ ./gradlew :app:testDebugUnitTest --offline     # 修复前基线（本轮开始时）
suites=73 tests=620 failures=0 errors=0 skipped=2

$ ./gradlew :app:testDebugUnitTest --offline     # S1–S5 全部合入后
suites=79 tests=668 failures=0 errors=0 skipped=2

$ ./gradlew :app:testDebugUnitTest --offline     # 修完台账 bug + 新增 1 条锁
suites=79 tests=669 failures=0 errors=0 skipped=2
```

---

## 5. 本轮改动

| 文件 | 改动 |
|---|---|
| `app/src/main/java/com/jev/probe/core/kb/PersonaStore.kt` | `topUpLocked`：把 `seeded += key` 挪到 `writeLocked` 之前，并写明为什么 |
| `app/src/test/java/com/jev/probe/core/kb/PersonaMigrationTest.kt` | 新增 `toppingUpWritesTheNewKeysIntoTheLedgerNotJustTheItems` |
| `_reports/shots/*.png` | 两张真机截图 |

提交：`874de22 fix(kb): 补预设时先记台账再写盘（真机抓到 seeded 未落盘）`

---

## 6. 自验缺口（没验到的，明说）

1. **搜索框没做真机验证**：`adb shell input text` 不支持中文，无法把中文关键词打进搜索框；搜索逻辑只有单测（`ExpertCatalog` 过滤）覆盖，真机只验证了渲染。
2. **起草链路没有真出稿**：点「用这个专家」后只验到 `Prefs.style` 已改、`usedCount` 已加。`ReplyPrompt` 是否按新人设出字没验——本机没有可用的模型 key，实况链路跑不起来。提示词层面的约束仍由 `ReplyPromptTest`（41 例逐字）守着。
3. **`global/` 工程仍未真正 import**：S5 只做到"纯 Kotlin + 零 `import android.` + 守卫测试"，跨工程引用需要抽共享模块，本轮没动。
4. **只截了两张图**：新建/删除/恢复三条路径有 `uiautomator` 文本证据，没有截图。
5. **旧包问题只在本机复现一次**：清理过 `app/build` 后重新构建即正常；是否有别的构建缓存路径会产出旧包，没做系统排查。
