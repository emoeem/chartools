# 专家库（预设人设 + 用户自建）审查与落地方案

日期：2026-10-27 ｜ 范围：`/home/emo/code/chartools`（`cn/` 为主，`global/` 对照）｜ 性质：**只读审查 + 方案，未改任何业务代码**

---

## 0. 实测基线（全部为本机真实输出，未编）

| 项 | 实测值 |
|---|---|
| 工程构成 | 两个独立 Gradle 工程：`cn/`（`com.jev.probe`，多 App 聊天副驾，255 个 `.kt`）与 `global/`（`com.jev.overseas`，仅 WhatsApp，4 模块 18 个测试类） |
| 技术栈 | Kotlin + 传统 View/XML，**不用 Compose**；minSdk 30 / target 35；无 ViewBinding |
| 版本 | `versionName=2.0` / `versionCode=10`（`cn/app/build.gradle.kts:29-33`） |
| 编译 | `./gradlew :app:compileDebugKotlin --offline` → **exit 0** |
| 单测 | `./gradlew :app:testDebugUnitTest --offline` → **suites=73 tests=620 failures=0 errors=0 skipped=2** |
| 产物 | `app-debug.apk` 34,438,488 字节（2026-10-27 02:20） |
| 工作区 | 36 个文件已改 + 9 项未跟踪（含 `core/StrategyOrder.kt`、`capture/ChatApps.kt`、`core/ocr/`），**全部未提交** |
| UI 资源 | `res/layout/` **只有 1 个** XML（`activity_doc_import.xml`）；`res/values/strings.xml` 仅 4 条 string → 界面全部由 Kotlin 代码构建、文案硬编码 |

---

## 1. 现状诊断

### 1.1 结论先行：人设已经是「数据」，不是硬编码

上一轮（`_reports/persona-library_report.md`）已经把硬编码三张模板改成了磁盘库。现在链路是：

```
kb/personas.json  ──PersonaStore.list()──►  PersonaProfile(name, body)
                                                  │
                         用户点「用」→ Prefs.style = body（唯一真源）
                                                  │
              ReplyClient.kt:221 / :316 ── PersonaCard.parse(Prefs.style 或 contact.persona)
                                                  │
                        ReplyPrompt.kt:184 styleBlock(card.promptText(), card.registerOpen)
```

**所以「专家库」不是从零造，而是在这条链上补三层：元数据（头像/简介/标签/分类/热度）、独立页面、预设扩容。核心提示词链路一个字都不用改。**

### 1.2 已有能力矩阵

| 能力 | 现状 | 证据 |
|---|---|---|
| 人设存储 | ✅ `filesDir/kb/personas.json`，单锁 + 临时文件 rename 原子写 | `core/kb/PersonaStore.kt:74`、`:289` |
| 结构化解析 | ✅ 键值卡（称呼/关系/语气/语域/主题/情境/硬边界/避谈/安全词/黄灯/示例），兼容 Character Card V2 | `core/kb/PersonaCard.kt:133`、`:168` |
| 一键套用 | ✅ 立即写 `Prefs.style`，不等「保存全部设置」 | `SettingsActivity.kt:1060` |
| 生效判定 | ✅ 靠正文比对反推（不存 activeId，避免双状态漂移） | `PersonaStore.kt:97` |
| 增删改复制 | ✅ 新建/改名/复制/删除/恢复内置模板 | `PersonaStore.kt:116-165`、`SettingsActivity.kt:1151-1237` |
| 导入导出 | ⚠️ 仅剪贴板 JSON，无文件/分享目标 | `PersonaStore.kt:173`、`:199` |
| 内置预设 | ⚠️ 4 张（网调主/网调奴/日常/销售跟单） | `core/kb/PersonaPresets.kt:29` |
| 联系人专用人设 | ✅ 覆盖全局，从库里一键套 | `KnowledgeActivity.kt:750`；`ReplyClient.kt:221` |
| 主题↔知识库收窄 | ✅ `主题` 键 → `TopicScope` 只捞同域笔记 | `core/kb/TopicScope.kt:31` |
| 分类 / 标签 / 头像 / 简介 | ❌ 全无 | `PersonaProfile` 只有 id/name/body/updatedAt/builtin（`PersonaStore.kt:19-32`） |
| 使用热度 | ❌ 无任何计数器 | 同上 |
| 搜索 / 排序 | ❌ 无 | `SettingsActivity.kt:956-1013` 只是 `forEach` 顺序渲染 |
| 独立页面 | ❌ 埋在设置页第 386–470 行起的折叠区里，人设相关代码约 330 行（934–1262） | `SettingsActivity.kt`（1523 行） |

### 1.3 结构性问题（这次审查真正要改的东西）

| # | 问题 | 证据 | 后果 |
|---|---|---|---|
| A | **设置页已被撑到 1523 行**，人设 UI 占约 330 行，和密钥/模型/白名单/透明度混在一个文件 | `SettingsActivity.kt:934-1262` | 再往里塞卡片网格 = 2000 行单文件，改一处要重编译整页心智 |
| B | **没有共享 UI 组件**：`dp()`/`text()`/`round()`/`chip()`/`pill()` 在 3 个 Activity 里各写一份私有实现 | `MainActivity.kt:473-496`、`SettingsActivity.kt:1015/1266-1322`、`KnowledgeActivity.kt:139-161` | 专家页会成为第 4 份复制，样式从此四处漂移 |
| C | **预设只在「文件不存在」时播种一次** | `PersonaStore.kt:257-287`（`loadLocked` → `seedLocked`） | 老用户永远拿不到新增预设，只能自己找到「恢复模板」按钮；这正是「预设专家库」最该解决的问题 |
| D | **RecyclerView 未显式声明**，靠 material 传递依赖，实测解析到 **1.1.0（2019 年）** | `app/build.gradle.kts:106-132` 无 recyclerview；`dependencies` 输出 `recyclerview:1.0.0 -> 1.1.0` | 卡片网格要用的组件版本由别人的 pom 决定，某次升级会静默变版本 |
| E | **文案全硬编码中文**，`strings.xml` 仅 4 条 | `res/values/strings.xml` | 新增一页专家文案继续堆进代码；后续出海（`global/`）无法复用 |
| F | **`global/` 完全没有人设概念** | `global/core/.../engine/Drafting.kt:44-51` 只有场景 `styleRules` | 两工程已分叉；专家库只在 `cn/` 落地，将来 `global/` 要重做一遍 |
| G | **无热度/无排序数据** | `PersonaProfile` 无 `usedCount` | 「最热」排序没有数据源，做出来是假的 |

---

## 2. 优化项（按优先级）

### P0 — 不做就会让专家库变成第四份复制品或假功能

| 项 | 动作 | 落点 | 验收 |
|---|---|---|---|
| **P0-1 拆出独立 `ExpertActivity`** | 人设浏览/搜索/排序/新建/编辑全部搬进新 Activity；设置页人设区只保留「当前生效 + 打开专家库」入口和原文框 | 新增 `app/src/main/java/com/jev/probe/ExpertActivity.kt`；`SettingsActivity.kt:386-470` 收缩；`AndroidManifest.xml:52-62` 加 `<activity>` | `SettingsActivity` 降到 ~1150 行以内；人设区不再有 `personaRow/personaMenu` |
| **P0-2 抽共享 UI 组件** | `dp/text/round/chip/pill/emptyCard` 收进一处 | 新增 `app/src/main/java/com/jev/probe/ui/UiKit.kt`（object，方法接收 `Context`）；三处私有实现改调用 | 三个 Activity 里 `private fun dp(` 计数归零；像素级外观不变（对比真机 dump） |
| **P0-3 预设台账 `seeded[]`** | 记录「哪些内置预设已经播过」，让新增预设能到老用户、同时保住「删光不复生」 | `PersonaStore.kt:257-287`（load 路径）、`:289`（写盘）、`:344-346`（VERSION 1→2） | 单测：老文件升级后新增一张预设 → 出现；用户删掉的那张 → 不复活 |
| **P0-4 显式声明 RecyclerView** | `implementation("androidx.recyclerview:recyclerview:1.1.0")`（离线缓存只有 1.0.0/1.1.0；要 1.3.x 需联网拉） | `app/build.gradle.kts:106-132` | `:app:dependencies` 里 recyclerview 版本由本项目钉住 |
| **P0-5 热度打点收敛单点** | `PersonaStore.touch(id)` 唯一入口；三处套用路径都调它 | `PersonaStore.kt`（新增方法）、`SettingsActivity.kt:1060`、`ExpertActivity` 套用、`KnowledgeActivity.kt:750` 选中 | 单测：套用两次 → `usedCount=2`、`lastUsedAt` 递增 |

### P1 — 明确影响体验或数据寿命

| 项 | 动作 | 落点 |
|---|---|---|
| P1-1 分类与标签分离于「主题」 | 新增 `category`/`tags` 字段；**不**复用 `PersonaCard.topic`（那是知识库收窄开关，复用会把浏览筛选和 KB 行为耦合） | `PersonaStore.kt:19-32`、`PersonaCard.kt`（不改） |
| P1-2 导出/导入走文件 + 分享 | 在保留剪贴板的前提下加 SAF 写 `.json` 与 `ACTION_SEND` | `PersonaStore.kt:173-246`、`ExpertActivity` |
| P1-3 预设扩容到 12–16 张 | 5 类：情感 / 销售 / 职场 / 客服 / 日常，每张带 `topic` + 双字边界 + 「我：」示例（`PersonaPresetsTest` 自动校验） | `PersonaPresets.kt:29` |
| P1-4 新页文案走常量 | `ExpertText` object 集中字符串（不强行迁移历史文案，避免大 diff） | 新增 `ui/ExpertText.kt` |
| P1-5 专家 × App／联系人映射 | `Contact.persona` 已有一层；`ChatApps.byPackage` 现成，可按包名默认专家 | `capture/ChatApps.kt:1-30`、`core/Prefs.kt` |
| P1-6 补测试 | 迁移 / seeded 台账 / 筛选 / 排序 / 热度 各一组 | `app/src/test/java/com/jev/probe/core/kb/` |

### P2 — 值得做但不阻塞

- P2-1 卡片渲染性能：现在所有列表都是 `removeAllViews()` 全量重建（`KnowledgeActivity.kt:101-103`）；几十张卡用 RecyclerView + `DiffUtil`，或 MVP 先限制每类 20 张 + 搜索兜底。
- P2-2 搜索分词：中文子串匹配够用；要模糊排序可复用现成 BM25（`core/retrieve/LexicalSearch.kt`）。
- P2-3 头像零资源方案：`res/drawable/` 只有 `ic_launcher_foreground.xml`，用 emoji + `id.hashCode()` 取色板，不引图片资产。
- P2-4 三份用户文档同步（CLAUDE.md 硬要求）：`CHANGELOG.md`、`docs/feature-guide.md`、`.github/README*.md`。
- P2-5 版本号与提交：当前 36 改 + 9 新文件未提交，专家库上线需一并拍板。

---

## 3. 专家系统最小可行方案

### 3.1 不变量（先钉死，否则「不改变核心行为」是空话）

1. **`body` 仍然是唯一进提示词的东西。** 头像/简介/标签/分类/热度只用于浏览与排序，**永不进入** `PersonaCard.promptText()`。
2. **`Prefs.style` 仍是「当前生效」的唯一真源。** 不新增 `activeExpertId`；生效仍是正文比对（`PersonaStore.kt:64-70` 的设计理由：两份状态必然漂移，且漂移无报错可查）。
3. **专家 = 人设卡 + 元数据**，不引入第二种承载提示词的实体（否则一个概念两处真源）。
4. 元数据缺失时行为等同今天：`body` 原样、`category=""`、`usedCount=0`。

### 3.2 数据模型

`PersonaProfile`（`core/kb/PersonaStore.kt:19-32`）追加 7 个带默认值的字段，**全部可缺省**，v1 文件读进来天然兼容：

| 字段 | 类型 | 语义 | 缺省 |
|---|---|---|---|
| `avatar` | `String` | emoji，空则取名字首字 | `""` |
| `intro` | `String` | 一句话简介，卡面最多 2 行 | `""` |
| `tags` | `List<String>` | 能力标签，卡面最多显 2 个 + `+N` | `emptyList()` |
| `category` | `String` | 分类 tab 的键；空 → 「未分类」 | `""` |
| `usedCount` | `Int` | 套用次数（热度） | `0` |
| `lastUsedAt` | `Long` | 最近套用时间（「最新」排序用） | `0L` |
| `presetKey` | `String` | 内置预设的稳定标识（台账/tombstone 用，**不能按名字**：用户会改名） | `""` |
| `rank` | `Int` | 「综合」排序的策展权重，内置卡给定值，自建默认 0 | `0` |

### 3.3 存储

`filesDir/kb/personas.json` 升 `version: 2`：

```json
{
  "version": 2,
  "seeded": ["emotion.owner", "sales.followup", "..."],
  "items": [{ "id", "name", "body", "updatedAt", "builtin",
              "avatar", "intro", "tags", "category",
              "usedCount", "lastUsedAt", "presetKey", "rank" }]
}
```

迁移规则（`PersonaStore.kt:257` `loadLocked` / `:322` `decode`）：

1. 读到 `version <= 1`：items 原样保留、元数据置空；用 `name` 与 `PersonaPresets.ALL` 对齐推出 `presetKey`，**并把它们写进 `seeded`** —— 老用户已删掉的那几张，从此不会因为新增预设而复活。
2. 迁移前先把原文件备份成 `personas.v1-<时间戳>.json`，再原子写（沿用 `:305` `writeAtomic`）；写失败就保留 v1 文件原样、内存用迁移结果，只读不写。
3. 之后每次 load：`ALL` 里 `presetKey ∉ seeded` 的 → 追加（`builtin=true`）并记入 `seeded`。**这是「新增预设能到老用户」与「删了不复活」同时成立的唯一做法。**

### 3.4 UI 结构（`ExpertActivity`，代码构建，沿用 `KnowledgeActivity` 骨架）

```
┌ 专家库 ─────────────────────────────────────┐
│ [🔍 搜索名字 / 简介 / 标签]                  │
│ 排序： (综合) 最热  最新                     │   ← pill 组，KnowledgeActivity.kt:139 同款
│ 分类： (全部) 情感 销售 职场 客服 日常 我的   │   ← 横向 ScrollView + pill
├─────────────────────────────────────────────┤
│ ┌───────────────┐ ┌───────────────┐         │
│ │ 😈  网调·我是主 │ │ 💼  销售·跟单  │         │   2 列网格
│ │ 我定规矩你执行  │ │ 先给结论再理由 │         │   intro 2 行省略
│ │ 网调  亲密      │ │ 销售  跟单     │         │   tags ≤2 + "+N"
│ │ 用 12 次 · 生效中│ │ 用 3 次        │         │   热度行
│ └───────────────┘ └───────────────┘         │
│ …                                           │
│ [ ＋ 新建专家 ]                              │
└─────────────────────────────────────────────┘
点卡片 → 底部弹层：正文预览 + [套用][改][复制][导出][删除]
```

- **头像**：圆形 TextView，emoji（或名字首字），背景色用 `id.hashCode()` 从固定 8 色板取 —— 零图片资产。
- **卡面信息密度严格对齐 WorkBuddy**：头像 + 名称 + 一句话简介 + 能力标签 + 使用热度，不额外加字段。
- **新建/编辑**：复用现有对话框逻辑（`SettingsActivity.kt:1072` `editPersonaDialog`，含键骨架、实时「认出了什么」回显、收进语气示例），搬到 `ExpertActivity` 并补 `intro/tags/category/avatar` 四个输入。
- **空态**：库空 → 「从预设开始 / 新建一份」，不要给一排点不动的卡。
- **筛选/排序纯函数**：新增 `core/kb/ExpertCatalog.kt`

```kotlin
object ExpertCatalog {
    fun categories(items): List<String>                  // 全部 + 去重分类 + 我的（builtin=false）
    fun filter(items, category: String?, query: String): List<PersonaProfile>  // name/intro/tags/body 子串，忽略大小写
    fun sort(items, mode: Mode): List<PersonaProfile>    // COMPREHENSIVE: rank↓, used↓, updated↓
                                                         // HOT: used↓, lastUsed↓
                                                         // NEW: updated↓ (自建) / presetKey 空优先
}
```
放进 core 层的理由：无 Android 依赖，JVM 单测能把「分类为空归到未分类」「搜索命中标签」「综合排序内置优先」全部钉住（`PersonaStatus` 就是这么放的）。

### 3.5 与现有 prompt / 对话流程的接入点（**只加元数据，不改提示词**）

| 接入点 | 文件:行 | 改什么 |
|---|---|---|
| 套用（设置页） | `SettingsActivity.kt:1060` `applyPersona` | 套用后调 `PersonaStore.touch(id)` |
| 套用（专家页） | 新增 `ExpertActivity` | `prefs.style = p.body` + `touch(id)`，与设置页同语义 |
| 套用（联系人） | `KnowledgeActivity.kt:750` `personaPresets` | chip 显示 `name` + `intro`；选中后 `touch(id)` |
| 提示词注入 | `ReplyPrompt.kt:184` `styleBlock` / `:281` `draftUserPrompt` | **不动**；`card.promptText()` 输入仍是同一段文本 |
| 人设解析 | `PersonaCard.kt:87/168` | **不动**（元数据不进 parse，避免「认不出键」判定被新字段干扰） |
| 卡解析入口 | `ReplyClient.kt:221`、`:316` | **不动**（仍是 `contact.persona` 优先，其次 `Prefs.style`） |
| 安全闸门 | `SafetyGate.kt:103/115/151` | **不动**（仍读 card 的边界/安全词/黄灯） |
| 知识库收窄 | `TopicScope.kt:31` | **不动**（仍读 `card.topic`，与 UI 分类无关） |
| 入口 | `MainActivity.kt:118` 附近「其他」区、`SettingsActivity.kt:406` 附近 | 各加一行/一个按钮进 `ExpertActivity` |
| 清空语义 | `KbStore.clearAll()` | 不变：删 `kb/` → 下次读重新播种（`PersonaStore.kt:250-256` 注释已写明） |

### 3.6 工作量

| 块 | 估算 |
|---|---|
| `PersonaProfile` 字段 + v2 迁移 + `seeded` 台账 + `touch` | ~150 行 |
| `ExpertCatalog`（filter/sort/categories） | ~70 行 |
| `ExpertActivity`（搜索/排序/分类/网格/详情弹层/新建编辑） | ~500–600 行 |
| `ui/UiKit.kt` 抽取（P0-2） | ~90 行 + 三处调用替换 |
| 预设扩容 8–12 张 | ~120 行数据 |
| 入口 + Manifest | ~15 行 |
| 测试（迁移/台账/筛选/排序/热度） | ~220 行，+20~25 例 |
| **合计** | **约 1100 行新增，620 → ~645 例测试** |

验收口径（沿用仓库惯例）：`./gradlew :app:testDebugUnitTest :app:assembleDebug` 0 失败 + 真机 `uiautomator dump` 取证 + `_reports/` 出报告；三份用户文档同步。

---

## 4. 风险点

| # | 风险 | 为什么会发生 | 处置 |
|---|---|---|---|
| R1 | **迁移写坏 = 用户人设「消失」** | `loadLocked` 解析失败会备份后返回空库（`PersonaStore.kt:263-278`），用户看到的是库空了 | 迁移前备份 v1、原子写、写失败保持原文件；单测覆盖「坏文件不清空」 |
| R2 | 「删光不复生」与「新增预设」直接冲突 | 现在的播种判据是「文件在不在」 | 用 `seeded[]` 按 `presetKey` 记账，**不能按名字**（改名后重名会重复播种） |
| R3 | 出现第二个「当前生效」真源 | 专家页若存 `activeExpertId`，用户手改正文后 id 立刻过期 | 严禁存 id：沿用 `activeOf(style)` 正文比对（`PersonaStore.kt:97`） |
| R4 | 元数据污染提示词，回复行为悄悄变 | `intro` 看着像「人设描述」，很容易顺手拼进 `promptText()` | 硬约束：元数据只进 UI；用现有 `ReplyPromptTest`/`PersonaCardTest` 作回归锁 |
| R5 | 热度漏记导致「最热」失真 | 套用入口有 3 处（设置页 / 专家页 / 联系人对齐话框），漏一处数据就偏 | 收敛到 `PersonaStore.touch(id)` 单点，三处都只调它 |
| R6 | 分类 tab 与「主题」被用户混为一谈 | 两者中文字面接近，且都叫「分类/领域」 | UI 上写明「分类只影响浏览；知识库收窄由人设卡里的『主题』决定」，并在详情弹层显示该卡的 `topic` |
| R7 | 卡片一多，`removeAllViews` 全量重建卡顿 | 全仓库现有列表都是这个模式（`KnowledgeActivity.kt:101`） | MVP 用 RecyclerView；或先限制每类 20 张 + 搜索 |
| R8 | 依赖版本由别人决定 | recyclerview 实测被解析成 1.1.0（material 的 pom） | 显式声明版本；离线缓存里只有 1.0.0/1.1.0，要 1.3.x 必须联网拉一次 |
| R9 | 两工程进一步分叉 | `global/` 无 Persona 层（`Drafting.kt:44-51`） | 本轮只做 `cn/`；若 `global/` 也要，先把 `PersonaCard`+`PersonaStore` 抽成不依赖 Android 的纯 Kotlin 层（`PersonaStore` 现在直接吃 `Context`/`org.json`） |
| R10 | 工作区已有 36 改 + 9 新文件未提交 | 上一轮人设库与自然度 P0 都未落仓 | 专家库开工前先拍板提交或 stash，否则回滚边界分不清 |

---

## 5. 一句话结论

**这个项目不需要「新增人设能力」，需要的是「把已经存在的人设库产品化」**：给它元数据（头像/简介/标签/分类/热度）、给它独立页面（搜索 + 分类 tab + 综合/最热/最新）、给内置预设扩容并用 `seeded` 台账让老用户也能收到。

提示词链路（`PersonaCard.promptText` → `ReplyPrompt.styleBlock` → 起草）**一行都不用改**，这正是这件事能在 1100 行内做完、且不破坏现有 620 个测试的原因。
