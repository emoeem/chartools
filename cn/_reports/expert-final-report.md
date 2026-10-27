# 专家库 S1–S5 最终报告

日期：2026-10-27 ｜ 工程：`/home/emo/code/chartools`（`cn/`）｜ 计划：[expert-plan.md](expert-plan.md)

---

## 1. 结果一览（每个数字都是当轮跑出来的）

| 阶段 | 提交 | suites | tests | failures | errors | skipped |
|---|---|---|---|---|---|---|
| 基线 | `eb431a4` | 73 | 620 | 0 | 0 | 2 |
| S1 地基 | `0f81700` | 76 | 652 | 0 | 0 | 2 |
| S2 页面 | `402c318` | 77 | 659 | 0 | 0 | 2 |
| S3 预设 | `64506b0` | 77 | 661 | 0 | 0 | 2 |
| S4 绑定 | `fee208a` | 78 | 666 | 0 | 0 | 2 |
| S5 复用层 | `b2c07af` | 79 | 668 | 0 | 0 | 2 |

命令：`./gradlew :app:testDebugUnitTest --offline --no-build-cache`（每次先删 `app/build/test-results`，避免拿到缓存里的旧结果）。
新增 48 个用例。全程本地提交，**没有 push**。

---

## 2. 各阶段改了什么

### S1 地基（`core/kb/`）

| 文件 | 改动 |
|---|---|
| `PersonaBaselineTest.kt`（新） | **先于任何改动**写的 characterization test：出厂 4 张预设的名字与顺序、首读播种一次且 id 稳定、每张都能解析成结构化卡、**改名不改变提示词**、删一张不复活 |
| `PersonaStore.kt` | `PersonaProfile` 加 8 个字段（avatar/description/tags/category/usedCount/presetKey/skillRefs/appPkgs，全部带默认值）；`decode()` 返回 `Doc(version/items/seeded/removed)`；v1→v2 迁移（备份 → 原子写 → 失败只读）；`topUpLocked`；`touch`/`touchActive`；`delete` 写墓碑；`restoreBuiltins` 按 `presetKey` 且放行墓碑；导入导出带浏览层 |
| `PersonaPresets.kt` | 引入 `PersonaPreset`（key/name/body/category/tags/description/avatar）作为**单一数据源**，`ALL: List<Pair<String,String>>` 由它派生（老接口与老测试一行未改） |
| `ExpertCatalog.kt`（新） | 纯 Kotlin：`categories` / `filter`（名字/简介/标签/正文）/ `sort`（综合=usedCount×3+builtin×2，最热，最新）/ `browse` |
| 测试 | `PersonaMigrationTest`(14)、`ExpertCatalogTest`(13)、`PersonaBaselineTest`(5) |

**为什么需要第 8 个字段 `presetKey`**：`seeded[]` 台账要认得出「这条是哪个预设」。只按名字认的话，用户把「日常」改成「闲聊」后台账失联，下次启动会复活一份**重名副本**。

**v1 迁移为什么把全部内置 key 都记进 `seeded[]`**：v1 的首读会把所有预设播种一遍，所以「库里没有某张」等价于「用户删了它」——被删的条目连名字都没留下，无从反推。这是 v1 的唯一解。

### S2 页面（`ui/` + `ExpertActivity` + `SettingsActivity`）

| 文件 | 改动 |
|---|---|
| `ui/UiKit.kt`（新，220 行） | `Context` 扩展：dp/text/round/card/edit/label/header/section/chip/filterChip/cardTitle/resultText/primaryBtn/cardBtn/foldSection/openUrl/versionLabel/pct/toast/appLabel/confirm |
| `ui/ExpertCard.kt`（新） | 卡面文案纯函数：头像回退 `🧩`、简介为空取正文首行并剥掉键名、标签上限 3、热度文案 |
| `ui/ExpertAdapter.kt`（新） | `ListAdapter` + `DiffUtil`（卡面每个字段都参与比较） |
| `ExpertActivity.kt`（新，566 行） | 顶栏（导入/导出/更多）+ 搜索 + 分类抽屉 + 三种排序 + 2 列 `GridLayoutManager` 网格 + 详情 + 新建/编辑 + 导入导出 + 恢复模板 |
| `SettingsActivity.kt` | 1523 → **1100** 行；`private fun dp(` → **0**；人设区收成「当前生效 + 打开专家库 + 原文编辑」 |
| `AndroidManifest.xml` | 注册 `.ExpertActivity`（`exported=false`） |
| `app/build.gradle.kts` | 显式 `androidx.recyclerview:recyclerview:1.3.2` |

**`dp(` 归零没改 123 个调用点**：`Activity` 本身就是 `Context`，删掉私有 `dp(`、把 `Context.dp` 扩展 import 进来，所有 `dp(12)` 自动解析过去。编译通过即证明。

**一处容易踩的坑（已处理）**：从专家库回到设置页，编辑框可能仍显示旧文本 —— 若用户此时点「保存全部设置」，就会把刚套用的专家顶掉。做法是只在「编辑框内容 == 上次对齐值」（即用户没在这里改过）时才采纳 `Prefs.style`；否则不覆盖，只提示「设置里有未保存的人设改动」。

### S3 预设（4 → 14）

五类：情感 4（网调 ×2 原有、恋爱·刚认识、恋爱·冷战破冰）、销售 3（跟单原有、报价、追尾款）、职场 3（向上汇报、同事协作、催进度）、客服 2（售后、投诉安抚）、日常 2（日常原有、家人·日常问候）。

每张都带 key/category/tags/description/avatar，且**前四张顺序不动**（老用户 `seeded` 台账与它是同一身份序列）。`PersonaPresetsTest` 新增两条：分类必须在预定义集合 / 标签 ≥2 / 头像单码位 / key 唯一 / 五类都有货；**元数据不改变提示词**（比较「带元数据 vs 不带元数据」的 `promptText()` 逐字相同）。

### S4 绑定（灰度，默认关）

- `Prefs.expertBindingEnabled`（默认 `false`）
- `ContextBuilder` 只加一层过滤：开关开 **且** 当前专家写了 `skillRefs` 才收窄技能清单
- `ExpertBinding` 纯函数：`allowedSkillNames`（开关关 → 原样返回；refs 空 → 原样返回；引用了已删技能 → 静默忽略，不清空整轮）、`sanitizeAppPkgs`（只允许已适配包名）
- `ReplyPromptTest` 41 例逐字通过 = 关闭路径的回归锁

### S5 复用层

- `core/kb/PersonaProfile.kt` 从 `PersonaStore.kt` 拆出，**零 android import**；`ExpertCatalog` / `ExpertBinding` / `ui/ExpertCard` 同样纯
- `PurityTest`(2) 把两条只在文档里的约束变成机器守卫：① 这四个文件不许 `import android.`；② 全仓不许出现 `activeExpertId` 这类第二份「当前生效」状态

---

## 3. 过程中的两次返工（如实记录）

改 `SettingsActivity` 时我先写了自动化脚本按「函数名 + 大括号配对」删代码，**两次把文件改坏**：

1. 第一次停在 `section` 未找到就中止（文件未落盘，无损失）；
2. 第二次跑完只剩 458 行 —— 根因是删 `PERSONA_SKELETON` 时用了 `(?:.*\n)*?` 从**文件里第一个** `/**` 开始跨行匹配，把中间几百行一起吃掉。

处置：两次都从 `/tmp/SettingsActivity.kt.bak` 还原（还原后 `wc -l` = 1523、`private fun dp(` = 1 才继续），最终改用**行号区间 + 每步校验**的方式，并在脚本里加了「删之前断言这行是 `private fun`」「删之后核对分节横幅与 `onResume`/`onDestroy`/`companion` 仍在」两条检查。

教训：这类「大文件外科手术」不能靠跨行正则，只能靠可验证的行号切片 + 每步回读。

---

## 4. 自验缺口（没验到的，不装验过）

1. **真机 UI 未取证**。`assembleDebug` 成功、APK 44 MB 已产出，但**设备在装配完成后从 adb 掉线**（`3afd9f4e` 消失，`adb kill-server` 重启后仍无设备），所以计划里的 `uiautomator dump` 截图、网格布局、详情弹层、从设置页跳转专家库这条链路**只有编译级证据，没有真机证据**。
2. **`global/` 尚未真正 import**。S5 做到了「四个文件零 Android 依赖 + 机器守卫」，但要让 `global/core` 真的引用它们，需要抽一个共享 Kotlin 模块（或让 `global` 的 sourceSet 指向 cn 的纯文件目录）。这是构建结构调整，**没有在本轮做**。
3. **1.3.2 需要一次联网 resolve**。首次 `--offline` 构建失败（`No cached version available for offline mode`），联网跑一次后 AAR 进缓存，之后 `--offline` 正常。离网机器首次构建需要注意。
4. **没有实况 A/B**。专家库是「改提示词输入的选择方式」，本轮没有任何模型侧效果对比；「14 张预设比 4 张更好用」目前是产品判断，不是数据结论。
5. **`.github/README*.md` 未同步**（CLAUDE.md 要求三份主文档同步，本轮只更新了 `CHANGELOG.md` 与 `docs/feature-guide.md`）。

---

## 5. 下一轮建议

1. **真机验收补跑**：设备接回后 `adb install -r` → 设置页 →「打开专家库」→ 截图网格/详情/编辑弹层；顺带确认窄屏（375/320dp）卡片不被裁。
2. **抽共享模块**：`cn` 与 `global` 之间加一个 `:expert-model`（纯 Kotlin，无 Android），把 `PersonaProfile` / `ExpertCatalog` / `ExpertBinding` 放进去，两边 `implementation(project(":expert-model"))`。S5 已经把这四个文件准备好，只差工程改造。
3. **专家绑定的 UI**：S4 只有数据与开关，编辑器里还没有「勾选技能 / 勾选 App」的界面 —— 下一轮给 `ExpertActivity` 的编辑弹层加两排多选（技能来自 `SkillStore.list()`，App 来自 `ChatApps.packages`）。
4. **导出格式版本化**：现在导出带浏览层字段但不带 `presetKey`（本机台账）；若以后要做「专家包」分享（别人导入的专家能同步更新预设），需要给导出加一个 `kind: "expert-pack"` 标记与版本号。
5. **`.github/README*.md` 补同步**。
