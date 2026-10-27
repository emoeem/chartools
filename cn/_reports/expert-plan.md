# 专家库实施计划（S1–S5）

日期：2026-10-27 ｜ 工程：`/home/emo/code/chartools`（`cn/` 为主）｜ 状态：**计划，未改任何业务代码**

---

## 0. 基线验证（本轮真实执行，非引用）

```bash
cd /home/emo/code/chartools/cn
rm -rf app/build/test-results/testDebugUnitTest app/build/reports/tests/testDebugUnitTest
./gradlew :app:testDebugUnitTest --offline --no-build-cache --rerun-tasks
```

| 项 | 值 |
|---|---|
| 结果 | `BUILD SUCCESSFUL in 46s`，`26 actionable tasks: 26 executed`（无 FROM-CACHE、无 UP-TO-DATE） |
| **suites** | **73** |
| **tests** | **620** |
| **failures** | **0** |
| **errors** | **0** |
| **skipped** | **2** |
| 结果文件时间 | 2026-10-27 18:23:24 |
| 与预期比对 | **完全一致（73/620/0/0/2）** |

> 第一次跑时 Gradle 报 `UP-TO-DATE`，第二次报 `FROM-CACHE` —— 两者都**不是**真执行。第三条命令加 `--no-build-cache --rerun-tasks` 并删掉结果目录，才拿到上表这组数字。前两次若直接采用，基线就是假的。

### 0.1 本轮复核出的、与已知上下文需要对齐的三处

| 项 | 已知上下文 | 本轮实测 | 处置 |
|---|---|---|---|
| 未提交改动 | 36 改 + 9 未跟踪 ≈ 49 项 | `git status --porcelain` = **49 项** = 34 `M` + 3 `D` + 12 `??` | 已按 3.2 处理，见 §1 |
| `.kt` 文件数 | 188 | `find . -name '*.kt' -not -path './build/*'` = **188** | 一致 |
| 序列化库 | 待确认 | 工程**不用** kotlinx.serialization / Gson / Moshi，用 `org.json`（`PersonaStore.kt:5-6`）；单测另挂 `org.json:json:20240303` 顶替 android.jar 里的空壳 | S1 的迁移必须按 `JSONObject.optXXX` 的语义写，不能假设「缺字段 = 用 data class 默认值」 |
| 预设测试 | 「新增 `PersonaPresetsTest`」 | **已存在**（`core/kb/PersonaPresetsTest.kt`，6 个用例，已断言每张预设能被 `PersonaCard.parse` 逐键识别） | S3 不新建同名文件，改为**扩写**它（补 tags/category/avatar 断言） |

---

## 1. 未提交改动处理（3.2 已执行）

基线数字**等于** 73/620/0/0/2，按决策规则第一支：整体提交为一个 baseline commit。

| 项 | 值 |
|---|---|
| 提交 | **`eb431a4`** `docs: expert library audit + bundle design (pre-S1 baseline)` |
| 纳入 | **47 个文件**（含 `cn/_reports/expert-library-audit_report.md`、`expert-bundle-design.md` 两份 S1 输入，未 stash） |
| 排除 | `.zcode/`（本地 agent 计划产物，非产品内容；未改 `.gitignore`，只是没 add） |
| 工作区现状 | `git status --porcelain` → 仅 `?? .zcode/`，回滚边界清晰 |
| 未推送 | 本地 commit，**没有 push** |

**两点如实说明**

1. 提交标题按指令原文写，但内容含 34 个源码改动（不止文档）。标题与内容的偏差我不藏：**要我把标题改成 `chore: pre-S1 baseline` 我就 amend**（`git commit --amend` 尚未执行）。
2. `cn/CLAUDE.md` 硬约束第 8 条写「禁止 `git commit` / `git push`，由人拍板」。本次你已明确下达提交制度（baseline + S1–S5 各一个），我按**当前直接指令**执行，且**全程不 push**。若你希望回到「只出 patch 不提交」，一句话即可切回。

---

## 2. 改动清单（文件 → 改什么 → 为什么）

### S1 — 地基（写作用域：`core/kb/` + `src/test/`）

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `core/kb/PersonaStoreTest.kt`（扩充）或新建 `core/kb/PersonaBaselineTest.kt` | **先写 characterization test**：v1 4 张预设逐张断言 id/name/body；首读播种 4 张；二次读不重复播种；`PersonaCard.parse` 输出 | 迁移前先锁住当前行为。没有这层，v2 迁移改错只会表现为「用户人设没了」 |
| `core/kb/PersonaStore.kt:19-32` | `PersonaProfile` 加字段（见 §3.1），全部带默认值 | v1 文件天然兼容，不写 v2 也能读 |
| `core/kb/PersonaStore.kt:322-342` `decode()` | 按 `optString/optInt/optJSONArray` 读新字段；类型不符时回落默认值，不抛 | `org.json` 没有 data class 默认值语义，缺字段必须显式兜底 |
| `core/kb/PersonaStore.kt:289-303` `writeLocked()` | 写 `version:2` + 全部新字段 + `seeded[]` 根节点 | 台账必须与 items 同文件同事务落盘 |
| `core/kb/PersonaStore.kt:257-278` `loadLocked()` | 加 v1→v2 迁移分支：备份 → 补 `presetKey` → 写 `seeded` → 原子写；失败则**只读不写** | 迁移写坏 = 人设丢失，是本次最高危动作 |
| `core/kb/PersonaStore.kt` 新增 `touch(id)` / `markRemoved(presetKey)` | 唯一热度打点入口；删除预设时记 tombstone | 收敛单点，避免三处套用各写一遍导致热度失真 |
| `core/kb/ExpertCatalog.kt`（新增） | 纯 Kotlin：`categories()` / `filter()` / `sort(mode)` | 无 Android 依赖 → JVM 单测可钉住排序与筛选；S5 直接复用 |
| `src/test/java/com/jev/probe/core/kb/ExpertCatalogTest.kt`（新增） | ~10 例 | 排序/筛选是纯函数，必须可测 |
| `src/test/java/com/jev/probe/core/kb/PersonaMigrationTest.kt`（新增） | ~10 例 | 迁移、台账、坏文件、touch |

### S2 — 页面（写作用域：`ui/`、`ExpertActivity.kt`、`SettingsActivity.kt`、`AndroidManifest.xml`、`app/build.gradle.kts`）

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `ui/UiKit.kt`（新增） | **`Context` 扩展函数**：`dp/text/round/chip/pill/card/label`（从三处私有实现合并） | 见下方「关键技术点」：用扩展函数可做到**零调用点改动** |
| `ExpertActivity.kt`（新增） | 搜索 + 分类 tab + 排序 tab（综合/最热/最新）+ 2 列 `RecyclerView` + 详情弹层 + 新建/编辑 | 专家库本体 |
| `ui/ExpertAdapter.kt`（新增） | `ListAdapter` + `DiffUtil`，`GridLayoutManager(ctx, 2)` | 避免 `removeAllViews()` 全量重建 |
| `ui/ExpertText.kt`（新增） | 新页文案常量集中 | 不迁移历史文案（避免大 diff），但新代码不再硬编码散落 |
| `SettingsActivity.kt:387-470` | 人设 fold 区收缩为「当前生效 + 打开专家库」入口卡 | 1523 行 → 目标 ≤1150 |
| `SettingsActivity.kt:934-1262`（329 行） | 迁出到 `ExpertActivity`：`reloadPersonas/renderPersonaShelf/personaRow/personaShelfActions/applyPersona/editPersonaDialog/personaMenu/renamePersonaDialog/importPersonaDialog/exportPersonas/restoreBuiltinPersonas` | 同上；`applyPersona` 迁出时补 `touch(id)` |
| `AndroidManifest.xml:43-62` | 加 `<activity android:name=".ExpertActivity">` | 无声明 = 启动即崩 |
| `app/build.gradle.kts:106-132` | **显式** `implementation("androidx.recyclerview:recyclerview:1.3.2")` | 现状 `1.0.0 -> 1.1.0`（material 传递解析），网格组件版本由别人 pom 决定 |

**行数算术（可复核）**：1523 − 329（人设库方法区 934–1262）− 84（fold 区 387–470）+ 22（入口卡）≈ **1132 ≤ 1150** ✅

**关键技术点（`dp(` 归零不靠改 123 处调用）**

`SettingsActivity` 里 `dp(` 有 **123** 个调用点（MainActivity 64、KnowledgeActivity 86）。逐个改成 `UiKit.dp(this, n)` 是 273 处机械 diff，纯风险无收益。正确做法：

```kotlin
// ui/UiKit.kt
fun Context.dp(v: Int): Int = (v * resources.displayMetrics.density).roundToInt()
```

`Activity` 本身就是 `Context`，因此文件内 `dp(12)` 会解析到导入的扩展函数；删掉 `private fun dp(` 即可让**声明归零、调用点一个不动**。编译通过即证明（Kotlin 解析失败会直接报 `Unresolved reference: dp`）。

### S3 — 预设扩容（写作用域：`core/kb/PersonaPresets.kt` + 既有测试）

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `core/kb/PersonaPresets.kt` | 4 → 14 张，5 类：情感 4 / 销售 3 / 职场 3 / 客服 2 / 日常 2 | 预设库太薄 = 用户看到的「专家」只有 4 个 |
| `core/kb/PersonaStore.kt`（预设侧） | 预设需携带 `presetKey/category/tags/description/avatar` | 元数据要跟预设走，否则新预设播下去全是「未分类」 |
| `core/kb/PersonaPresetsTest.kt`（**扩写既有文件**） | 补：`tags ≥ 2`、`category ∈ 预定义集合`、`avatar 非空且 ≤2 字符`、`description` 非空且**不出现在 `promptText()`** | 后者是不变量 1 的机器化守卫 |

### S4 — 绑定（写作用域：`core/kb/ContextBuilder.kt`、`core/Prefs.kt`、`PersonaStore.kt`）

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `core/Prefs.kt` | 新增 `expertBindingEnabled: Boolean = false`（灰度，默认关） | 关闭路径必须与今天逐字相同 |
| `core/kb/ContextBuilder.kt:142` | 开关开 → `skills` 先按 `expert.skillRefs` 过滤，再走原逻辑；开关关 → **原代码不动** | 只加一个 `if`，不改原有过滤链 |
| `core/kb/PersonaStore.kt` | `applyExpert(id)` 的绑定语义：`skillRefs` 逐个 `SkillStore.setEnabled(true)`；`appPkgs` 只允许取自 `ChatApps.packages` | 绑定失败（技能被删/包未装）降级成纯人设并如实提示，不静默半生效 |

### S5 — 复用层（写作用域：`core/kb/` 拆分 + `global/`）

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `core/kb/PersonaProfile.kt`（新文件，从 `PersonaStore.kt` 拆出） | `PersonaProfile` + `ExpertCatalog` 独立成文件，去掉 `import android.*` | 目标：`grep -c 'import android\.'` = 0 |
| `global/` | 仅加一个**只读引用验证**（编译期 import） | 验收「能被 import」，不在本轮让 `global/` 真的用专家库 |

### 明确不改（禁止触碰）

`ReplyPrompt.kt`、`PersonaCard.kt`、`ReplyClient.kt:221/316`、`SafetyGate.kt`、`TopicScope.kt` —— 提示词链路一行不动，这是 620 例能全绿的根因。

---

## 3. 迁移策略（v1 → v2）

### 3.1 字段（先定这一版，含一处需要你拍板的偏差）

按你给的 7 个字段：

| 字段 | 类型 | 默认 | 进提示词？ |
|---|---|---|---|
| `avatar` | `String?` | `null` | ❌ |
| `description` | `String?` | `null` | ❌ |
| `tags` | `List<String>` | `emptyList()` | ❌ |
| `category` | `String?` | `null` | ❌ |
| `usedCount` | `Int` | `0` | ❌ |
| `skillRefs` | `List<String>` | `emptyList()` | ❌（S4 改变的是**装配**，不是文本） |
| `appPkgs` | `List<String>` | `emptyList()` | ❌ |

> ⚠️ **规格缺口（需你拍板，我默认按「加」执行）**：`seeded[]` 台账要满足「新增预设能到老用户 + 删掉的不复活」，必须能**认出某条 profile 是哪个预设**。只靠名字不行 —— 用户改了名，台账里记的旧名字就再也匹配不上，下次播种会**复活一份重名副本**。所以需要第 8 个字段 `presetKey: String = ""`（内置预设的稳定标识，用户改名不变）。
>
> 不加的代价：改名后的预设会被重复播种；加的成本：一个字段 + 一条默认值。
>
> 同理，「最新」排序我用**已有**的 `updatedAt`，不新增 `lastUsedAt`；「综合」排序用 `builtin/usedCount/updatedAt` 加权，不新增 `rank`。这两个字段能省就省。

### 3.2 文件格式

```json
{ "version": 2,
  "seeded": ["emotion.dom", "sales.followup"],
  "removed": ["work.standup"],
  "items": [{ "id","name","body","updatedAt","builtin",
              "avatar","description","tags","category",
              "usedCount","presetKey","skillRefs","appPkgs" }] }
```

### 3.3 迁移步骤（`loadLocked` 内，按序）

1. 读文件，`decode()` 成功 → 拿到 items + `version`（缺省视为 1）。
2. `version <= 1`：
   a. **备份**：`personas.v1-<时间戳>.json`（沿用现有 `personas.corrupt-*` 的命名风格，绝不复用 `.tmp`）；
   b. 若有 items：按 `name` 与 `PersonaPresets` 对齐推 `presetKey`，**并把推出的 key 写进 `seeded`** —— 老用户**已经删掉**的那几张从此不会被当成「新预设」复活；
   c. 新字段全部置默认；
   d. `writeAtomic()` 写 v2；**写失败 → 保留原 v1 文件、内存用迁移结果、`lastProblem` 记一句**，只读不写，下次启动重试。
3. `version == 2`：`PersonaPresets.ALL` 中 `presetKey ∉ seeded` 且 `presetKey ∉ removed` → 追加（`builtin=true`）并记入 `seeded`，写盘。
4. `decode()` 失败：**现有逻辑不动**（备份为 `personas.corrupt-<ts>.json`，返回空库，`lastProblem` 明说）。硬验收项：**坏 JSON 不清空数据**——原文件必须还在。

### 3.4 「删掉的不复活」的三条路径

| 用户动作 | 落盘 | 下次启动 |
|---|---|---|
| 删内置预设 | 从 items 移除 + `removed += presetKey` | `key ∈ removed` → 不播种 |
| 改名内置预设 | items 里 name 变，`presetKey` 不变 | `key ∈ seeded` → 不重复播 |
| 清空知识库（删整个 `kb/`） | 文件没了 | 出厂重播种（现有语义，不改） |

`restoreBuiltins()` 对 `removed` 里的 key **显式放行**（用户主动点「恢复内置模板」就是反悔）。

---

## 4. 阶段拆分 · 独立验收 · 独立回滚

| 阶段 | 内容 | 验收（命令 + 数字） | 回滚 |
|---|---|---|---|
| **S1** | characterization test + 7(+1) 字段 + v2 迁移 + `seeded/removed` 台账 + `touch` + `ExpertCatalog` | `./gradlew :app:testDebugUnitTest --offline --no-build-cache` → 报 suites/tests/failures/errors/skipped；预期 **620 + ~20 = ~640，0 失败**；另跑 `:app:compileDebugKotlin` | `git revert <S1 sha>`（单文件面，无 UI 依赖） |
| **S2** | `UiKit` + `ExpertActivity` + Adapter + 设置页收缩 + Manifest + recyclerview 版本 | 同上全量测试 + `:app:assembleDebug` exit 0；`grep -c 'private fun dp(' SettingsActivity.kt` = **0**；`wc -l` ≤ 1150；真机 `adb install -r` + `uiautomator dump` 取证网格与弹层 | `git revert <S2 sha>`；`assembleDebug` 回归旧 APK |
| **S3** | 预设 4 → 14 | 全量测试 + `PersonaPresetsTest` 全绿（含新断言） | `git revert <S3 sha>`（纯数据文件） |
| **S4** | `skillRefs`/`appPkgs` 绑定 + 灰度默认关 | **开关关**：620 全绿且 `ReplyPromptTest` 逐字不变；**开关开**：新增绑定测试 | `git revert <S4 sha>`；开关默认关本身即软回滚 |
| **S5** | 拆 `PersonaProfile.kt` / `ExpertCatalog.kt` 去 Android；`global/` 引用验证 | `grep -c 'import android\.'` = 0；`cd ../global && ./gradlew :core:compileDebugKotlin --offline` exit 0 | `git revert <S5 sha>`（纯搬迁，编译即验） |

**S1 ∥ S2 并行**：S1 只碰 `core/kb/*.kt` + `src/test/core/kb/`；S2 只碰 `ui/`、`ExpertActivity.kt`、`SettingsActivity.kt`、`AndroidManifest.xml`、`app/build.gradle.kts`。**无文件重叠**（`PersonaStore.kt` 仅 S1；`SettingsActivity.kt` 仅 S2）。合并顺序：先 S1 后 S2（S2 读新字段）。

每阶段提交前跑一次全量测试，提交信息带**真实数字**。全程**不 push**。

---

## 5. 风险清单 + 回归锁

| # | 风险 | 破坏表现 | 回归锁（具体测试） | 兜底 |
|---|---|---|---|---|
| **R1** | v2 迁移写坏/写空 | 用户打开设置页，人设库空了 | `PersonaStoreTest.aCorruptFileIsBackedUpAndTheLibraryStaysUsable`（现有 13 例全保留）+ 新增 `PersonaMigrationTest` 的「v1 文件迁移后条数不变」 | 迁移前 `.bak` + 原子写；写失败只读不写 |
| **R2** | 「删了不复活」被破坏 | 用户删掉的预设每次启动都长回来 | `PersonaStoreTest.deletingEveryProfileDoesNotResurrectThem` + 新增「删单张预设 → 重启不复活」 | `removed[]` tombstone + `presetKey` |
| **R3** | 出现第二份「当前生效」状态 | 界面说 A 生效、实际发出去 B（无报错） | `PersonaStoreTest.activeOfMatchesTheLiveTextAndGivesUpOnFreeText`（正文比对反推） | 写死：不新增 `activeExpertId`；代码评审 grep `activeExpertId` 必须 0 |
| **R4** | 元数据污染提示词 | 回复风格悄悄变，620 里没人报错 | `PersonaCardTest.freeTextIsReturnedVerbatim`、`PersonaCardTest.aKeyValueCardCarriesEveryField`；新增「`description/tags/avatar` 不出现在 `promptText()`」 | 元数据只经 `ExpertCatalog`/UI 消费；`writeLocked` 里元数据与人设正文分离 |
| **R5** | S4 技能绑定改变既有输出 | 同一人设回复内容变了 | `ReplyPromptTest.anEmptyContextSaysNothing`、`aMatchedSkillBodyIsQuotedIntoTheUserPrompt`、`theCatalogueRidesOnEveryRoundEvenWithNoBody` | 灰度开关默认 `false`，关闭路径零改动 |
| **R6** | 预设扩容触发既有断言 | S3 一加卡就红 | `PersonaPresetsTest.everyPresetParsesIntoEveryKeyItClaims`（要求 `extra` 为空、称呼/关系/语气/主题/示例齐全） | 新卡一律按现有键骨架写，不发明键名 |
| **R7** | 热度打点漏点 | 「最热」排序失真（无报错） | 新增 `touch` 单测 + S2 里 `applyPersona` 必调 `touch` | 收敛到 `PersonaStore.touch(id)` 单点，评审 grep 只允许一处写 `usedCount++` |

---

## 6. 搜索需求（先搜再动手，搜完在阶段报告里记结论）

| 何时 | 搜什么 | 为什么非搜不可 | 已知替代手段 |
|---|---|---|---|
| S2 前 | WorkBuddy 专家字段/分类命名/头像规格、`expert-manager 专家包 结构` | 卡面信息密度要对齐（你给的那张截图只有：头像/名称/一行简介/3 个标签/热度） | 截图本身是硬证据；若外部搜不到（内部产品），**以截图逐元素为准**并在报告里写明「外部无公开规范」 |
| S2 中 | `RecyclerView 1.3.2` + `ListAdapter/DiffUtil` 最佳实践；`GridLayoutManager` 2 列等宽下 `itemView` 宽度与 `ItemDecoration` 间距 | 全仓库零 RecyclerView 使用经验，间距/复用坑会直接表现为「网格右列被裁」 | 本地无先例，必须查 |
| S2 中 | `androidx.recyclerview:recyclerview:1.3.2` 的 `compileSdk`/`minSdk` 要求 | 本地离线缓存**只有 1.0.0/1.1.0**；升 1.3.2 需联网拉一次（已验证 `dl.google.com` 可达，`HTTP/2 200`） | 拉不到就锁 `1.1.0`（离线可用），并在报告里说明「钉住旧版是因为离线环境」 |
| S1 中 | `org.json` `optString/optInt/optJSONArray` 在字段缺失/类型不符时的返回 | 工程不用 Gson/kotlinx，**data class 默认值在这里不生效**；写成 `optString("tags")` 会把数组变字符串 | 单测直接断言，不靠记忆 |
| S1 中 | Kotlin 扩展函数与成员函数同名时的解析优先级（`Context.dp` vs `private fun dp(`） | 「dp( 归零不动调用点」这招能否成立全看这条规则 | 编译即验证（`Unresolved reference` 会立刻暴露） |
| 全程 | 仅在遇到真实版本冲突/Gradle 解析异常时再查 | 不预搜无关题 | — |

---

## 7. 需要你拍板的三件事（其余我按默认执行）

| # | 事项 | 我的默认 | 备选 |
|---|---|---|---|
| 1 | 第 8 个字段 `presetKey` 是否加 | **加**（否则「删掉的不复活」在改名后失效） | 不加 → 承认改名会复活一份重名副本 |
| 2 | baseline commit 标题是否 amend 成 `chore: pre-S1 baseline` | 不改（按你给的原文） | 改，`--amend` 一条命令 |
| 3 | recyclerview 版本 | **1.3.2**（需一次联网 resolve，之后恢复 `--offline`） | 锁 1.1.0（完全离线，组件停留在 2019 年） |

---

## 8. 交付物清单

1. `cn/_reports/expert-plan.md`（本文件）
2. S1–S5 各一个本地提交（**不 push**），提交信息带真实测试数字
3. 每阶段测试数字：`suites / tests / failures / errors / skipped`
4. `cn/_reports/expert-final-report.md`（改了什么 / 验收结果 / 遗留 / 下一轮建议），并按 `cn/CLAUDE.md` 同步 `CHANGELOG.md`、`docs/feature-guide.md`、`.github/README*.md`
