# 专家库全量生效 —— 基线验证 + 执行计划

生成时间：2026-10-27 19:5x（Asia/Shanghai）
状态：**计划待确认，未改任何功能代码**

---

## 0. 基线数字

```
cd cn && ./gradlew :app:testDebugUnitTest --offline --rerun-tasks
BUILD SUCCESSFUL in 21s
26 actionable tasks: 26 executed
```

| suites | tests | failures | errors | skipped |
|---|---|---|---|---|
| **80** | **677** | **0** | **0** | **2** |

与预期 `80 / 677 / 0 / 0 / 2` **逐项一致**。`--rerun-tasks` 保证不是 `UP-TO-DATE` / `FROM-CACHE`
的影子数字；`testDebugUnitTest` 目录时间戳 `19:43:09` 为本轮实际产出。

汇总脚本（可复现）：

```bash
cd cn/app/build/test-results/testDebugUnitTest && python3 -c "
import glob,xml.etree.ElementTree as ET
s=t=f=e=sk=0
for p in glob.glob('*.xml'):
    r=ET.parse(p).getroot(); s+=1
    t+=int(r.get('tests',0)); f+=int(r.get('failures',0))
    e+=int(r.get('errors',0)); sk+=int(r.get('skipped',0))
print(f'suites={s} tests={t} failures={f} errors={e} skipped={sk}')"
```

---

## 1. 未提交改动：已按纪律拆两个提交

执行前 `git status --porcelain | wc -l` = **12**（6 `M` + 6 `??`），不是上一轮报告里写的 48/49
—— 上一轮的 49 项已在 `eb431a4` 收口，本轮的 12 项是"目录货架接入"那一轮的产物。

| 提交 | 内容 | 为什么这样切 |
|---|---|---|
| `63c26c1` | `tools/gen_experts.py` + `cn/app/src/main/assets/kb/experts.json` | 纯数据 + 生成脚本。单独回滚 = 目录消失，运行时逻辑仍在但读不到目录（降级成 14 张，不崩） |
| `016d8b1` | `ExpertPack.kt`、`ExpertPackTest.kt`、`ExpertCatalog.kt`、`PersonaStore.kt`、`ExpertActivity.kt`、`PurityTest.kt` + 三份文档 | 运行时逻辑。单独回滚 = 目录文件在但无人读它 |

**排除**：`.zcode/`（本地 agent 计划产物，不是产品内容，与 `eb431a4` 同一处理）。
**没有 stash 任何东西**，两份设计文档与生成物都在提交里。
工作区现在只剩 `?? .zcode/`。

---

## 2. S4 / S5 / E4 真实状态（grep 结果，不猜）

### 2.1 skillRefs / appPkgs —— **已实现，E3 不需要写代码**

```
grep -rn "skillRefs\|appPkgs" cn/app/src/main/java/com/jev/probe/core/kb/  → 25 命中
grep -rn "skillRefs\|appPkgs" cn/app/src/main/java/                        → 26 命中（多出 core/Prefs.kt）
```

关键落点：

| 位置 | 内容 |
|---|---|
| `core/kb/PersonaProfile.kt:74,76` | 两个字段已存在，默认 `emptyList()` |
| `core/kb/PersonaStore.kt:148,149,163,164,334,335,376,377` | 创建/序列化/反序列化全链路 |
| `core/kb/ExpertBinding.kt` | 纯函数 `allowedSkillNames` / `sanitizeAppPkgs`，三条规则写在注释里 |
| `core/kb/ContextBuilder.kt:143-146` | 已接线：开关开 + 专家写了 skillRefs → 只留点名的 |
| `core/Prefs.kt:177-179` | `expertBindingEnabled` 默认 **false**（`K_EXPERT_BINDING` 未写入时取 false） |

结论：**E3 的代码在上一轮已经落地**。本轮 E3 只剩"取证"——跑 `ExpertBindingTest` +
`ReplyPromptTest` 并报数字，不新增功能代码。

### 2.2 SettingsActivity / UiKit —— **已收口，E4 不需要做**

```
grep -c "" SettingsActivity.kt          → 1100        （目标 ≤1150 ✅）
grep -c "private fun dp(" SettingsActivity.kt → 0      （目标归零 ✅）
ls cn/.../probe/ui/                     → ExpertAdapter.kt  ExpertCard.kt  UiKit.kt ✅
```

### 2.3 纯 Kotlin 层 —— **"零 Android 依赖"已达成，`global/` 仍未真正 import**

```
grep -c "^import android\." core/kb/PersonaProfile.kt   → 0
grep -c "^import android\." core/kb/PersonaCard.kt      → 0
grep -c "^import android\." core/kb/ExpertCatalog.kt    → 0
```

`ExpertShelf` 在 `core/kb/ExpertPack.kt:162`（同样纯 Kotlin）。
但 `global/` 是**另一个独立 Gradle 工程**，没有任何机制让它 `import cn/` 的源集 ——
S5 只做到了"文件本身不依赖 Android"，没做到"global 能编译引用"。

**判定：E5 的验收项（`global/` 编译引用通过）尚未达成。** 但见 §6，本轮不做。

---

## 3. 本轮新发现的两个真问题（E1 要证明的正是它们）

### 3.1 回复缓存键里没有 `style` —— 点了「用」可能拿回上一位专家的稿

`jev/JevClient.kt:242` `cacheKey(snapshot, relationship, ctx, count, avoid, judgment, intensity)`
—— 七个分量，**没有 `style`**。

而同文件 252-254 行专门为台账加了分量，注释写得很清楚：

```kotlin
// 台账进的是回复提示词，不进 Jev 的 state，所以它只进回复缓存键：
// 台账一重建，上一轮的候选就必须作废。
val ledgerKey = ctx?.ledger?.render().orEmpty()
```

`style` 的处境和台账**一模一样**（都进回复提示词、都进 `ReplyClient.draft`：
`replyClient.draft(..., prefs.style, ...)`），却没有进键。

后果：换专家 → `prefs.style` 变了 → 但 `draftAndRank` 先 `cached(key)`，
key 没变 → **直接返回上一位专家写好的候选**。用户看到的症状是"点了用，回复没变"，
而 `reply_style` 已经是新专家 —— 与需求里"不只是 reply_style 的值变了"正面冲突。

现有 677 个测试里**没有任何一条覆盖 cacheKey**：

```
grep -rln "cacheKey\|draftAndRank" app/src/test/java/  → 0 命中
```

### 3.2 `ctx.contact.persona` 会整体覆盖专家正文

`jev/ReplyClient.kt:316`：

```kotlin
val rawStyle = ctx?.contact?.persona?.trim().takeUnless { it.isNullOrBlank() } ?: style
```

当前聊天若设过"对方人设"（`KbModels.kt:46` 的 `Contact.persona`），专家 `body`
**一个字节都不进提示词**。这是既有设计（更具体的优先于全局），但对
"331 位任意一位点「用」就生效"是硬冲突。

**处置（不改优先级）**：改它会悄悄覆盖用户给单个联系人手写的人设，属于
"为了新功能破坏旧承诺"。改为在 `ExpertActivity` 详情弹层里显式提示：
当前聊天设了对方人设，它会盖过专家正文。E1 两个分支都断言。

---

## 4. E1 —— 全量端到端生效验证（最高优先）

### 4.1 测试类与遍历方式

新文件：`cn/app/src/test/java/com/jev/probe/core/kb/ExpertApplyEndToEndTest.kt`

```kotlin
@RunWith(Parameterized::class)
class ExpertApplyEndToEndTest(private val key: String) {
    companion object {
        @JvmStatic @Parameters(name = "{0}")
        fun keys(): List<Array<Any>>   // 读真实 assets/kb/experts.json → 331 条 → 每个 key 一个 case
    }
}
```

- 读文件用**与 `ExpertPackTest` 相同的相对路径**（`File("src/main/assets/kb/experts.json")`，
  单测工作目录是 `app/`），比的是用户手机上那份，不是 fixture。
- `@Parameters(name = "{0}")` → 每个用例在报告里叫专家 key，失败时直接指出是哪一位。
- 纯 JVM + 临时目录（`TestContext` + `Files.createTempDirectory`），不引 Robolectric，
  不新增依赖（`testImplementation` 目前只有 junit / org.json / mockwebserver / kxml2）。

### 4.2 每个 case 的断言点（8 条）

| # | 断言 | 防的是什么 |
|---|---|---|
| 1 | `install(preset)` 返回非 null，`id` 非空，`body == preset.body.trim()` | 派生路径丢字段 |
| 2 | **重新 new 一个 `PersonaStore(dir)`** → `list()` 里有该 id 且 body 非空 | 只在内存里成了，没落盘 |
| 3 | `touch(id)` → 再重载 → `usedCount == 1` | 热度没写回（"最热"排序失效） |
| 4 | 重载后 `ledger().first`（seeded）含 `preset.key` | 台账漏记（真机抓过的老 bug 同款） |
| 5 | `PersonaCard.parse(profile.body).structured == true` | 静默退回自由文本（卡片能画、回复没变） |
| 6 | `card.promptText()` 非空，且含 `card.topic`（`主题：` 后的词） | body 没真正走到提示词 |
| 7 | `ReplyPrompt.styleBlock(style) != ReplyPrompt.styleBlock("")`，且以 `lead` 开头 | styleBlock 把这句丢了 |
| 8 | 负向：`promptText()` 不含 `简介：` / `标签：` / `分类：` 三个键 | 元数据漏进提示词（不变量 1） |

**第 8 条为什么用"键"而不是"值"**：`preset.description` 有可能天然是 body 的子串
（例如 description 就叫"AI 数据修复"而 body 主题也是它），用值断言会假失败。
执行 E1 前先跑一次统计：若"description 是 body 子串"的条数为 0，就升级成值断言（更严）；
若有，保持键断言并在报告里写明条数。**这是执行期的实测决定，不在这里拍脑袋。**

### 4.3 数量与失败处置

- 新增 tests：**+331**（一个参数化类，报告里 suites +1、tests +331）
- 任何一条失败 → **回 `tools/gen_experts.py` 修映射**，禁止改测试放宽断言。
- 若 331 例让 `testDebugUnitTest` 超过 60s，则折叠成按分类 5 组 × 每组断言全部成员
  （报告里如实写实际数字，不假装是 331）。

---

## 5. E2 —— 套用链路的原子性与失败兜底

### 5.1 现状（`ExpertActivity.kt:338`）

```kotlin
private fun applyExpert(p: PersonaProfile) {
    prefs.style = p.body                       // ① 先写 style（主线程）
    ... worker {
        runCatching { store.install(preset) }  // ② 落库
        live?.let { runCatching { store.touch(it.id) } }  // ③ 热度
    }
}
```

问题：**style 先写、落库后写**。落库失败（磁盘满、权限异常）时，
`reply_style` 已经是新专家的 body，但"我的库"里没有这位 —— 半截状态，
而且 `runCatching` 把失败吞成 null，用户看不到任何提示。

### 5.2 方案：抽出纯 Kotlin 的 `ExpertApply`

新文件 `core/kb/ExpertApply.kt`（不依赖 Android，符合 S5 的纯 Kotlin 纪律）：

```kotlin
interface StyleSink { var style: String }

object ExpertApply {
    data class Result(val ok: Boolean, val profile: PersonaProfile?, val warning: String?)
    fun apply(store: PersonaStore, preset: PersonaPreset, sink: StyleSink): Result
}
```

顺序与失败策略（**每一步都要能解释**）：

| 步 | 失败时 | 理由 |
|---|---|---|
| ① `install` | **中止**，`sink.style` 一个字节不动，返回 `ok=false` | 库写不进去就不该改生效状态 |
| ② `touch` | 继续，`warning` 记一句 | 热度是计数器，不该让"点用"失败；丢了只是"最热"少一票 |
| ③ `sink.style = body` | 抛出 → `ok=false` | style 是单字符串写入，不存在"半截" |

`ExpertActivity` 改为调它，`Prefs` 用 3 行适配器接入（不动 `Prefs` 自身 API）：

```kotlin
val sink = object : StyleSink {
    override var style: String
        get() = prefs.style
        set(v) { prefs.style = v }
}
```

### 5.3 同时修 §3.1 的缓存键

`JevClient.cacheKey` 增加 `style` 分量。**style 不变时 key 不变**，所以：

- 灰度/日常路径：输出与今天逐字相同（只是 key 字符串更长，命中行为一样）
- 换专家后：key 变 → 旧候选作废 → 下一次起草真的用新 body

### 5.4 新增测试

- `ExpertApplyTest`（~10 条）：`install` 失败中止且 style 未变（用"`filesDir` 指向一个文件而不是目录"
  制造写盘失败，已验证这条路能让 `writeLocked` 返回 false）；`touch` 失败不阻塞；
  成功后三步都到位；坏 `personas.json` 不清空（引用已有锁，不重复造）。
- `ReplyCacheKeyTest`（~3 条）：style 变 → key 变；style 同 → key 同；style 与 ledger 互不干扰。

预计 E2 新增 **+13**。

---

## 6. E3 / E4 / E5 处置

| 阶段 | 结论 | 本轮动作 |
|---|---|---|
| **E3** | 代码已存在（§2.1） | **不写代码**。跑 `ExpertBindingTest` + `ReplyPromptTest` 报数字取证；若 `ExpertBindingTest` 缺"开关关 = 逐字相同"的直接断言，只补这一条断言（不改生产代码） |
| **E4** | 已达标（§2.2） | **不写代码**。1100 行 / `dp(` 归零 / UiKit 存在，作为既成事实报数 |
| **E5** | 零 Android 依赖达成，`global/` 编译引用**未达成** | **本轮不做**，列为遗留。理由：要达成得抽共享 Kotlin 模块（`expert-core`），cn 与 global 两个独立工程都要改 `build.gradle.kts` —— 这会让本轮 677 基线重新洗牌，而它与"331 位生效"这个目标零关系。单列一轮更安全。**不建议为凑验收项硬做。** |

---

## 7. 风险清单（≥3，每条带回归锁）

| # | 风险 | 症状 | 回归锁 |
|---|---|---|---|
| R1 | `cacheKey` 加 `style` 分量导致缓存命中率下降 | 同一聊天重复起草多一次网络调用（每个专家组合各一份缓存） | 新增 `ReplyCacheKeyTest`「style 同 → key 逐字相同」；`ReplyPromptTest` 41 例 |
| R2 | `ExpertApply` 改的是"用"的主路径 | 点用没反应、或库变了 style 没变 | `ExpertApplyTest`（含写盘失败分支）+ E1 的 331 例（每例都走 install/touch 真路径） |
| R3 | 为了让专家"更明显"去改 `styleBlock` 措辞 | 所有用户的回复措辞集体漂移 | `ReplyPromptTest`（逐字断言 `lead` 文案）+ `PurityTest` |
| R4 | `contact.persona` 覆盖导致"点了没用" | 用户投诉但无法解释 | E1 分支断言 + 详情弹层提示（§3.2） |
| R5 | 331 参数化把单测时间拉长 | CI 超时 | 纯 JVM + 临时目录；实测耗时 > 60s 则按分类折叠成 5 组 |
| R6 | `PurityTest` 那条 `activeExpertId` 禁令被绕开 | 出现第二份"当前生效"状态 | 已有 `PurityTest`（`016d8b1` 里刚加过一条），E1/E2 全程只写 `Prefs.style` |

---

## 8. 搜索需求（先搜再写，搜完在阶段报告记一句）

| 主题 | 为什么必须搜 | 用在哪 |
|---|---|---|
| JUnit4 `Parameterized` 在 Gradle 报表里的计数口径 | 要知道 331 个 case 是算 331 个 test 还是 1 个 suite × 331 | E1 报数字的口径 |
| `SharedPreferences.apply()` 的跨线程可见性 | §3.1 的"切换后立即生效"结论依赖它 | E2 断言"下一次起草读到新值" |
| `Contact.persona` 与 `Prefs.style` 的优先级是否有既有文档约定 | 决定 §3.2 是"提示"还是"改优先级" | E1 分支断言 |
| 生成器里 `主题：` 词与 `description` 的重合度 | §4.2 第 8 条用值断言还是键断言 | E1 |

（RecyclerView / GridLayoutManager / 序列化默认值：本轮不涉及 E4，且项目用 `org.json`
非 kotlinx，字段默认值问题上一轮已确认，不再重复搜。）

---

## 9. 真机取证（E1 的补充，不替代单测）

设备：OPPO PJE110 / Android 16（上一轮同一台）。

抽样 3 位不同分类的专家，每位：

1. 点「用」→ 记录"我的库"数量、`usedCount`、`prefs xml` 里 `reply_style` 的实际值（`adb shell run-as` 直读）
2. 发起一次起草 → 抓请求体里的 `promptText`，确认含该专家 body 特征句
3. 换下一位 → 确认上一位的特征句**不再出现**（无残留）

搜索框真机输入若仍因 ColorOS IME 失效，照实写进 `residual_risk`，**不伪造取证**。

---

## 10. 提交与回滚

| 阶段 | 提交信息 | 回滚方式 |
|---|---|---|
| E1 | `test(kb): 331 位专家全量生效验证（参数化端到端）` | `git revert <sha>` —— 只删测试文件，生产代码零改动 |
| E2 | `fix(kb): 套用链路原子化 + 回复缓存键补 style` | `git revert <sha>` —— 回到"style 先写、缓存不含 style"的旧行为 |
| E3/E4 | 不产生提交（仅取证） | — |
| 收尾 | `docs(reports): expert-apply-report.md` | `git revert <sha>` |

预期终值：`677 + 331 (E1) + 13 (E2) = 1021 tests`，failures 0。

---

## 11. 待确认的三件事

| # | 事项 | 我的默认 | 备选 |
|---|---|---|---|
| 1 | §3.2 `contact.persona` 覆盖专家正文 | **不改优先级**，只在详情弹层提示 | 改成"专家优先"（会覆盖用户给单个联系人写的人设） |
| 2 | E2 里 `touch` 失败是否阻塞"用" | **不阻塞**，只记 warning | 阻塞并要求重试（热度是全功能刚需吗？不是） |
| 3 | E5 抽共享模块 | **本轮不做**，列遗留 | 本轮做，接受 677 基线重算 |
