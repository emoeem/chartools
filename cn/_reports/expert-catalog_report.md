# 专家目录：接入 331 位专家（MichengAI/dsh-agency-agents）

日期：2026-10-27 ｜ 归属：`core/kb/` + `ExpertActivity` + `tools/` ｜ 未提交（by 拍板）

## 1. 做法（为什么是这个形状）

用户要的是「像 WorkBuddy 那样，能选不同专家，也能自己建一个」。上一轮已经把
「专家 = 人设正文 + 浏览层元数据」这条地基打完了（14 张手写预设、v2 库、台账、目录页面）。
这一轮要做的是**把外部一个 331 位专家的仓库接进来**，并且不能把地基踩坏。

三条不变量决定了实现形状：

1. **只有 `body` 进提示词** → 上游 2–8KB 的 agent system prompt **不能**直接当 body。
   它写的是「工作流程 / 交付物格式 / 自检清单」，塞进一条聊天回复的提示词里，
   预算爆、重点散。所以生成的是**提炼卡**：称呼 / 关系 / 语气 / 主题 / 情境 /
   三条规矩 / 两三句示例，约 250 字。
2. **专家只能由 `PersonaProfile` 派生** → 目录条目必须是 `PersonaPreset`（和内置预设
   同一个类型），派生只有一条路径：`PersonaPreset.asProfile(id)`。
   此前这条 13 行藏在 `PersonaStore` 的文件私有扩展里，目录再写一份就会漂移，
   而漂移的症状是「从目录加入的专家少了分类」—— 不报错。
3. **`Prefs.style` 是唯一真源** → 目录里没有「当前选中」。套用仍然只是把 body
   写进设置，再 `touch` 记热度。

## 2. 改了什么

| 文件 | 改动 | 为什么 |
|---|---|---|
| `tools/gen_experts.py`（新） | 读上游 331 个 `.md`，解析 frontmatter（name/description/emoji）+ 正文小节（沟通风格 / 关键规则 / 核心使命），生成 `experts.json`；`--check` 校验与上游一致 | 331 条 × 250 字不可能手写；脚本进仓库才能随上游更新 |
| `app/src/main/assets/kb/experts.json`（新，350 KB） | 331 条目录数据，`categories` 25 个，带 `sourceCommit` / `contentHash` | 随 APK 打包，只读货架 |
| `core/kb/ExpertPack.kt`（新，纯 Kotlin） | `parse(json)`：逐条容错解析，坏条跳过不整包放弃；`PersonaPreset.asProfile(id)`；`ExpertShelf.merge(mine, pack)`：同 `presetKey` 时**我的库优先** | 解析不进 Activity，才能用真实 assets 做单测 |
| `core/kb/PersonaStore.kt` | 新增 `install(preset)`：已装则原样返回不复制；台账更新在 `writeLocked` **之前**。`toProfile` 改为委托 `asProfile` | 一条派生路径；台账顺序沿用上次真机抓到的教训 |
| `core/kb/ExpertCatalog.kt` | 新增 `ORDER` = 老 5 类 + 目录 22 个 division；`categories()` 按 `ORDER` 排 | 老分类必须在前：手写 14 张全在里面 |
| `ExpertActivity.kt` | worker 里读一次 assets（缓存），`items = merge(库里, 目录)`；状态行改「我的 / 目录」；目录条目详情按钮变「用这个专家 / 加入我的专家库」；长按目录条目只给「加入 / 复制正文」 | 目录样品不能改名删除（它不是用户的东西） |
| `test/.../ExpertPackTest.kt`（新，8 例） | 331 条逐条解析、分类顺序、每个 division 都非空、坏目录降级、货架拼接、改名不重复、入库台账、目录可搜索 | 生成物写错时 `PersonaCard` 会**静默**退回自由文本，只有逐条断言能发现 |
| `test/.../PurityTest.kt` | 把 `ExpertPack.kt` 加进「不许 import android」名单 | 它要能被 `global/` 复用 |

`CHANGELOG.md` / `docs/feature-guide.md` 已同步。

## 3. 验收（真实输出）

```
$ ./gradlew :app:testDebugUnitTest --offline --rerun-tasks
BUILD SUCCESSFUL in 22s
FINAL suites=80 tests=677 failures=0 errors=0 skipped=2      # 上一轮 79 / 669

$ python3 tools/gen_experts.py --src /tmp/dsh-agency-agents --check
OK 331 experts, 181716 bytes, hash 88690ab726cd1ca3

$ unzip -l app-debug.apk | grep kb/
   358669  assets/kb/experts.json
```

真机（OPPO PJE110 / Android 16，`adb install -r` Success）：

| # | 操作 | 实测 |
|---|---|---|
| 1 | 进入专家库 | `共 345 位（我的 14 · 目录 331）· 当前显示 345 个` |
| 2 | 分类条滚动 | 可见 `日常 / 学术研究 / 企业战略 / 设计 / 技术工程`… |
| 3 | 点「技术工程」 | `当前显示 74 个`（上游 engineering = 74，对得上） |
| 4 | 点「AI 数据修复工程师」 | 详情标题 `专家详情 · 目录`；`识别到的键：主题「AI 数据修复」· 称呼「你」· 示例 2 句` |
| 5 | 点「用这个专家」 | `personas.json` items 14→15、`seeded` 14→15 且含 `agency.engineering-ai-data-remediation-engineer`、该条 `usedCount=1` |
| 6 | 检查唯一真源 | `shared_prefs/jev_assistant.xml` 的 `reply_style` 已是该专家的 body |
| 7 | 重新进入专家库 | `共 345 位（我的 15 · 目录 330）` —— 目录样品被库里那条**顶替**，没有重复 |

## 4. 自验缺口（没验到的明说）

1. **搜索没在真机验**：这台 ColorOS 上 `adb shell input text` 与 `input keyevent`
   都落不进搜索框（EditText 已 `focused=true` 但文本为空，IME 未连）。
   搜索能力只有单测覆盖（`theShelfIsSearchableByNameBlurbTagAndBody`）。
2. **没有「一键全装」**：331 条一次性写进人设库会让库没法翻，也会让每次写盘多几百 KB。
   现在是按需加入。
3. **提炼卡不是上游原文**：上游完整手册（2–8KB）不进提示词。若以后要做「深度模式」，
   得给 `PersonaProfile` 加一个只读的 `brief` 字段并单独控制它的注入点，
   不能直接往 body 里拼。
4. **未提交**：按 `cn/CLAUDE.md` 第 8 条，commit/push 由人拍板。
