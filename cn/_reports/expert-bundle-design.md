# 专家库方案：三视图映射 + 专家 = 人设 × 技能 × 连接器

日期：2026-10-27 ｜ 范围：`cn/`（`com.jev.probe`）｜ 性质：方案，未改业务代码
配套：[expert-library-audit_report.md](expert-library-audit_report.md)（现状审查与 P0/P1/P2 清单）

---

## 1. 一句话结论

WorkBuddy 的专家页不是「一个界面」，是**三个视图共用一套实体**：

| WorkBuddy 视图 | 本项目已有的东西 | 缺什么 |
|---|---|---|
| **专家** | `PersonaStore`（`kb/personas.json`）+ `PersonaCard`（结构化解析）+ `TopicScope`（主题收窄知识库） | 元数据（头像/简介/标签/分类/热度）、独立页面、预设扩容 |
| **技能** | `SkillStore`（`filesDir/skills/<name>/SKILL.md`）+ `SkillMatcher` + `ContextBuilder:142` 注入 | 技能与人设的**绑定关系**（现在是全局 enabled + 自动匹配） |
| **连接器** | `capture/ChatApps.kt` 注册表（QQ/TIM/微信/X/飞书/WhatsApp/Telegram）+ `ChatAppAdapter` 契约 | 专家与 App 的**绑定关系**（现在只有联系人级 `Contact.persona`） |

所以本轮真正的工作量不在「造专家」，在**把三个已有原语串成一个实体**，并把它的浏览层从设置页里搬出来。

---

## 2. 分层：哪些字段能进提示词，哪些不能

这是整个方案唯一不能错的地方。专家实体分成两层，**边界由字段决定，不由代码风格决定**：

### L1 浏览层（只进 UI，永不进提示词）

| 字段 | 用途 | 缺省 |
|---|---|---|
| `avatar` | emoji；空则取名字首字 | `""` |
| `intro` | 一句话简介，卡面 2 行 | `""` |
| `tags: List<String>` | 能力标签，卡面显 2 + `+N` | `[]` |
| `category` | 分类 tab 的键 | `""` |
| `usedCount` / `lastUsedAt` | 热度与「最新」排序 | `0` / `0L` |
| `rank` | 「综合」排序的策展权重 | `0` |
| `presetKey` | 内置预设稳定标识（台账/tombstone 用，**不能按名字**，用户会改名） | `""` |

### L2 行为层（会改变输出，必须显式、可回滚、可测）

| 字段 | 落点 | 现状 |
|---|---|---|
| `body` | `Prefs.style` → `PersonaCard.parse` → `ReplyPrompt.styleBlock` | ✅ 已有，**唯一真源** |
| `topic`（在 body 里，不是元数据） | `TopicScope.narrow` 收窄知识库 | ✅ 已有，靠解析 body 得到 |
| `skillRefs: List<String>` | 套用时把对应 skill 的 `enabled` 打开 | ❌ 新增（S4） |
| `appPkgs: List<String>` | 该专家默认服务的 App（覆盖全局默认） | ❌ 新增（S4） |

**禁止事项（三条不变量）**

1. `body` 仍然是**唯一**进入提示词的文本；L1 字段一个都不许拼进 `PersonaCard.promptText()`。
2. `Prefs.style` 仍是「当前生效」的唯一真源；**不新增 `activeExpertId`**（两份状态必然漂移，且漂移无报错）。
3. 不引入第二种承载提示词的实体；专家 = 人设 + 元数据 + 绑定，不是第二套模板系统。

---

## 3. 套用的语义（这是「专家」和「人设」的唯一差别）

```text
点「用」这个专家
  ├─ prefs.style = body          ← 已有路径，一个字不改（SettingsActivity.kt:1060）
  ├─ PersonaStore.touch(id)      ← 热度单点打点
  ├─ enabledSkills = expert.skillRefs      ← S4，仅在此刻写 SkillStore 的 enabled
  └─ appScope = expert.appPkgs            ← S4，仅当该 App 有适配器时生效
```

人设 = 只有第一条。专家 = 第一条 + 后三条。**同一个文件、同一套解析、同一套安全闸门**，只是套用时多做两件事。

S4 的风险与闸门：

- 技能绑定会改变提示词内容 → 必须先有 A/B 证据（离线 `eval` 或灰度开关），默认 **关**。
- `appPkgs` 只能从 `ChatApps.packages` 里选，不能自由填写；否则等于绕过适配器契约。
- 绑定失败（技能被删/包未安装）必须**降级成纯人设**并如实告知，不能静默半生效。

---

## 4. 实施顺序（每步都能独立验收、独立回滚）

| 阶段 | 内容 | 动 UI？ | 动提示词？ | 验收 |
|---|---|---|---|---|
| **S1 地基** | `PersonaProfile` +7 字段、`personas.json` v2 迁移（先备份再原子写）、`seeded[]` 台账、`PersonaStore.touch(id)`、`ExpertCatalog`（分类/筛选/排序纯函数） | 否 | 否 | 现有 620 例全绿 + 新增 ~20 例；坏文件不清空；老用户收到新预设、删掉的不复活 |
| **S2 页面** | `ui/UiKit.kt` 抽公共控件 → `ExpertActivity`（搜索 / 分类 tab / 综合·最热·最新 / 2 列网格 / 详情弹层 / 新建编辑）→ 设置页人设区收缩为「当前生效 + 打开专家库」 | 是 | 否 | SettingsActivity ≤1150 行；三处 `private fun dp(` 归零；真机 `uiautomator dump` 取证 |
| **S3 预设** | 12–16 张，5 类（情感 / 销售 / 职场 / 客服 / 日常），每张带 `topic` + 双字硬边界 + `我：` 示例 | 否 | 否 | `PersonaPresetsTest` 自动校验「每张都能解析成结构化卡」 |
| **S4 绑定** | `skillRefs` / `appPkgs` 套用语义 + 默认关的灰度开关 | 少量 | **是** | 关闭时输出与今天逐字相同（回归锁）；开启时 A/B 有分数 |
| **S5 复用** | 把 `PersonaCard` + `PersonaStore` 抽成不依赖 Android 的纯 Kotlin 层，给 `global/` 用 | 否 | 否 | `global/` 能 import 且 `grep 'import android.'` 零命中 |

S1 → S2 可以并行（两块写作用域不重叠：`core/kb/` vs `ExpertActivity.kt` + `ui/`），但 S2 依赖 S1 的字段，合并时以 S1 为准。

---

## 5. 与 WorkBuddy 卡面的字段对照

| 卡面元素 | 数据来源 | 备注 |
|---|---|---|
| 圆形头像 | `avatar` emoji，背景色取 `id.hashCode()` 固定 8 色板 | 零图片资产，`res/drawable/` 现在只有 launcher |
| 名称 | `name` | 与 `PersonaProfile.name` 已有 |
| 两行简介 | `intro` | 空则回退 `body` 首行 |
| 标签 | `tags`，最多 2 + `+N` | 与 `PersonaCard.topic` 无关，别混 |
| 使用数 `♡ 1195.8w` | `usedCount`，≥1 万按「万」截断 | 没有计数器时**不显示**这一行，别造假数据 |
| 分类 tab | `category` + 「我的」= `builtin=false` | 横向 ScrollView + pill |
| 综合 / 最热 / 最新 | `rank↓` / `usedCount↓` / `updatedAt↓` | 纯函数，JVM 可测 |

---

## 6. 与现有代码的接触面（只列会改的）

| 文件 | 改动 | 阶段 |
|---|---|---|
| `core/kb/PersonaStore.kt:19-32` | data class 加 7 字段（全带默认值，v1 天然兼容） | S1 |
| `core/kb/PersonaStore.kt:257-287 / :289 / :344` | 迁移、备份、`seeded` 台账、`touch` | S1 |
| `core/kb/ExpertCatalog.kt` | 新增（分类/筛选/排序） | S1 |
| `SettingsActivity.kt:386-470`、`:934-1262` | 人设区收缩，跳转新页 | S2 |
| `ExpertActivity.kt` | 新增 | S2 |
| `ui/UiKit.kt` | 新增，三处私有实现改调用 | S2 |
| `AndroidManifest.xml:52-62` | 加 `<activity>` | S2 |
| `core/kb/PersonaPresets.kt:29` | 预设扩容 | S3 |
| `core/kb/ContextBuilder.kt:142` | 若走 skillRefs，改读「专家绑定优先，其次 enabled」 | S4 |
| **不动** | `ReplyPrompt.kt`、`PersonaCard.kt`、`ReplyClient.kt:221/316`、`SafetyGate.kt`、`TopicScope.kt` | — |

---

## 7. 风险（与审查报告 R1–R10 互补，这里只列方案层新增）

| # | 风险 | 处置 |
|---|---|---|
| B1 | 「专家」概念膨胀成第四套模板系统 | 写死：专家只允许由 `PersonaProfile` 派生，不新增存储 |
| B2 | S4 技能绑定让「同一个人设」行为悄悄不同 | 灰度开关默认关；关闭路径必须与今天逐字相同，用现有 `ReplyPromptTest` 当回归锁 |
| B3 | `appPkgs` 绕过适配器契约 | 只允许从 `ChatApps.packages` 选，测试钉住 |
| B4 | 热度打点漏一处，「最热」失真 | 收敛到 `PersonaStore.touch(id)` 单点，三处套用都只调它 |
| B5 | 48 个未提交改动 + 9 项未跟踪 | 开工前先提交或 stash，否则回滚边界分不清 |
