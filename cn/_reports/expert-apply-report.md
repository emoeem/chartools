# 专家库全量生效验收 + 套用原子化（E1–E2）

日期：2026-10-27 · 设备：OPPO PJE110 / Android 16（`3afd9f4e`）

## 0. 一句话结论

331 位专家**每一位**都能从「点用」一路走到起草提示词，这条链现在由 331 条参数化用例逐条钉住；
套用过程从「先改设置再落库」改成「先落库再改设置、失败回滚」，磁盘写失败不再留下半截状态。

## 1. 测试数字（每阶段真跑，`--rerun-tasks`）

| 阶段 | 提交 | suites | tests | failures | errors | skipped |
|---|---|---|---|---|---|---|
| 基线 | `016d8b1` | 80 | 677 | 0 | 0 | 2 |
| E1 全量生效 | `b1029c8` | 82 | **1010** | 0 | 0 | 2 |
| E2 原子化 | `8517ab9` | 83 | **1019** | 0 | 0 | 2 |

计划预估 1008，实际 1010（331 参数化 + 2 独立 + 677）。差额原因见 §3.2。

## 2. 改了什么

| 文件 | 改动 | 属于 |
|---|---|---|
| `core/kb/ExpertApply.kt` | **新增**。三步（落库 → 热度 → 换 style）固定顺序，失败回滚；纯 Kotlin，零 `import android.` | core/kb |
| `ExpertActivity.kt` | 「用」改走 `ExpertApply`；失败不再 `finish()`、不再说「已套用」；新增 `StyleSink` 适配器（仍然只写 `Prefs.style`） | ui |
| `test/.../TestPrefs.kt` | **新增**。HashMap 支撑的 `SharedPreferences` + 能接管 `getSharedPreferences` 的 Context，让**真实的 `Prefs`** 能在 JVM 里构造 | test |
| `test/.../ExpertApplyEndToEndTest.kt` | **新增**。331 条参数化，逐位走完整条链 | test |
| `test/.../ExpertApplySwitchTest.kt` | **新增**。换人无残留、空 style 零字节 | test |
| `test/.../ExpertApplyTest.kt` | **新增**。9 例，含 3 条真实失败注入 | test |
| `tools/gen_experts.py` | 主题兜底分支补 `strip()`；重生成 `experts.json`（3 条正文 + contentHash） | tools |

## 3. E1：331 位全量生效

### 3.1 每一例断言了什么

链条：`install → touch → Prefs.style → PersonaCard.parse → promptText → ReplyPrompt.styleBlock`。

1. 落库后 `presetKey` / `body` / 头像 / 简介 / 标签 / 分类都对得上；
2. **重造一个 `PersonaStore` 实例**（= App 重启）后条目还在，正文没变；
3. `touch` 后 `usedCount == 1`，**再读一次盘**仍是 1；且 `updatedAt` 没被 touch 改（「最新」不被「最近使用」污染）；
4. `seeded` 台账含这个 key 且已落盘，`removed` 里没有它；
5. `Prefs.style = body` 后**读回来就是它**，`activeOf(style)` 反查回同一条；
6. 解析出的卡 `structured == true`，`promptText()` 含 `主题：X` / `称呼：X` / `语气：X`，且 X **就是 body 里声明的那个值**；
7. `styleBlock` 与「没选专家」时不同，且带 `<persona_card>`；
8. 把浏览层字段换成 `ZZ_*` 哨兵后，`promptText()` **逐字不变**，哨兵一个都不出现。

### 3.2 一个必须写下来的设计判断：负向断言不能写成 `contains(description)`

实测：**331 份 body 里有 302 份把 description 的前缀写进了 `情境` 行**（生成器干的）。所以
「简介不出现在提示词里」按字面是**假的** —— 但那是 body 自己写的内容，不是浏览层字段泄漏。

真正要守的不变量是「换掉元数据，提示词逐字不变」，所以用**哨兵**验：这一条不会被巧合击穿，
也不会假失败。如果当初图省事写成 `assertFalse(prompt.contains(preset.description))`，
会有 302 条用例红掉，然后人会去「调测试」而不是「看问题」。

### 3.3 两处真失败的复盘（没有放宽断言）

首轮 331 条里有 2 条红：

| 用例 | 现象 | 根因 | 处理 |
|---|---|---|---|
| 移动应用开发者 / 高级开发者 | `主题「iOS」不是 body 里写的` | body 写成 `主题： iOS`（**冒号后带空格**），而 `PersonaCard` 按声明会 trim | 回 `gen_experts.py` 修映射（见 §3.4） |

同时改进断言本身：从「字面子串」改成「**与 body 声明的值相等**」（`declaredTopic == card.topic`）。
这不是放宽 —— 它比子串更严（要求完全相等），并且顺带免疫空白差异。

### 3.4 生成器修复

`topic_of()` 的兜底分支从简介里切出短语后，去掉「精通」这类废话会留下空格，而 `.strip()`
只在兜底**之前**调过。出口补一次 `strip()` 后重生成：

```
wrote .../experts.json: 331 experts, 181710 bytes, 25 categories, hash 837153411685464d
--check → OK 331 experts, hash 837153411685464d
```

命中 **3 位**（我最初只按前导空格找，只找到 2 位；尾随空格的那位是 diff 才暴露的）：
`移动应用开发者`、`高级开发者`、`macOS Metal 空间工程师`。diff 只有 4 行（3 条正文 + contentHash）。

### 3.5 测试数量对不上的原因（记一笔）

`@RunWith(Parameterized::class)` 会让**每一个** `@Test` 都随参数各跑一遍。第一版把两个额外用例
也写在参数化类里，于是 331×3 = **993** 次执行（多出 662 次纯重复）。拆成
`ExpertApplyEndToEndTest`（只放参数化那一条）+ `ExpertApplySwitchTest`（各跑一次）后是 333。

## 4. E2：套用原子化

### 4.1 旧实现的病

```kotlin
prefs.style = p.body          // ← 先换设置
worker.execute { install(); touch() }   // ← 再落库
```
磁盘写失败（空间不够、目录没写权限）时：设置里已是新专家、库里没有这一条，**界面照样弹「已套用」**。
用户下次打开专家库发现「我的」里没有它，热度也是 0 —— 看起来成功，数据和显示不一致，且无任何报错。

### 4.2 新顺序与失败语义

| 步骤 | 失败时 |
|---|---|
| 1. 落库（`install` / 取已有条目） | **立刻返回，`style` 一个字节不动**，原因写进 `problem` |
| 2. 记热度（`touch`） | 降级成 `warning`，**不挡套用**（热度是计数器，丢一票不值得挡住用户） |
| 3. 换 `style` | **回滚**到进来时那句；库里那条**保留**（它是完整合法的卡，删掉才是二次破坏） |

失败时 Activity 不 `finish()`、`setResult` 也不改，让用户留在专家库换一位再试。

### 4.3 失败是怎么造出来的（不打桩）

- **落库失败 / 热度失败**：`chmod` 把 `kb/` 目录改成只读，真实的 JSON 原子写就在创建 `.tmp` 时失败。
  两条用例靠「先装 A（可写）→ 再只读 → 装 B（新条目，必须写盘）→ install 失败」与
  「再装 A（已在库，install 不写盘）→ touch 写盘失败」区分开，**测的是 `writeLocked` 的真行为**。
- **style 写失败**：`SharedPreferences` 的事，用会抛异常的 `StyleSink`，断言回滚到原值。
- **坏文件**：写一段非法 JSON，套用后断言 `personas.corrupt-*` 备份存在、内容逐字等于原始坏文件。

9 条用例全绿，全量 1019 / 0 / 0 / 2。

## 5. 真机抽样（3 位、3 个分类）

| # | 分类 | 专家 | 库数量 | 热度 | `reply_style` 主题 | 上一位残留 |
|---|---|---|---|---|---|---|
| 1 | 职场 | `职场·催进度`（内置预设） | 15 → 15（已在库） | `职场·催进度`=1 | `职场` | 无（原为 `AI 数据修复`） |
| 2 | 客服 | `基础设施运维师`（目录，新落库） | **15 → 16** | `基础设施运维师`=1 | `基础设施运维` | 无 |
| 3 | 情感 | `恋爱·冷战破冰`（内置预设） | 16 → 16 | `恋爱·冷战破冰`=1 | `恋爱` | 无 |

- `seeded` 随落库同步增长（15 → 16），台账没有说谎；
- 设置页显示 `当前生效：「恋爱·冷战破冰」`，人设原文就是该专家 body（见截图）；
- 网格页 `共 345 位（我的 16 · 目录 329）`，四位用过的专家角标都是「用过 1 次」。

截图：`_reports/shots/expert-apply-settings-20261027.png`、`_reports/shots/expert-apply-grid-20261027.png`

> 抽样时我把「点分类 chip 后第一张卡」当取样规则。中间那位 `基础设施运维师` 看着像技术工程，
> 我先去查了它的 `category` —— 确实是 `客服`（上游 division = support）。**没查就写「分类不对」
> 会是一条假发现。**

## 6. E3 / E4 / E5 的真实状态（零 diff，不是没做）

| 项 | 证据 | 结论 |
|---|---|---|
| E3 绑定（灰度默认关） | `ContextBuilder.kt:143-146` 已按 `skillRefs` 过滤；`Prefs.kt:177` `getBoolean(K_EXPERT_BINDING, false)`；`ExpertBindingTest` 在跑 | S4 已完成，**本轮不需要改代码** |
| E4 收口 | `SettingsActivity.kt` **1100** 行；`private fun dp(` **0** 处 | 已达标，无 diff |
| E5 复用层 | `PersonaProfile` / `PersonaCard` / `ExpertCatalog` / `ExpertPack` / `ExpertApply` 的 `import android.` 计数**全为 0** | 纯 Kotlin 层已达成；`global/` 真正跨工程 import 仍未做（见 §7） |

没有为 E3/E4 造空提交 —— 零改动就是零改动，把它们的验证记在这里而不是包装成提交。

## 7. 遗留 / 下一轮建议

1. **真机抓不到实况提示词**（本轮最大缺口）。App 没有提示词预览入口，也不把提示词写进 logcat，
   所以「设备上这次起草的 prompt 里含该 body」目前只有 JVM 层证据（331 条逐条断言），
   设备上验到的是**状态**（`reply_style` 逐字等于该专家 body + 设置页回显 + 详情页「识别到的键」）。
   要补真机实况，最省的配方：`adb reverse tcp:PORT tcp:PORT` + 本地回环 HTTP 服务把请求体落盘，
   把 Base URL 指过去，再用手动生成触发一轮 —— 这样能拿到**逐字的 system/user prompt**。
2. **`global/` 仍不能直接 import**：需抽共享 Kotlin 模块（构建结构调整会洗掉 1019 的基线），单独立项。
3. **`情境` 行复用了 `description` 前缀（302/331）**：功能无害，但让「简介」与「正文」内容重复。
   要么生成时去掉 `情境`，要么让上游描述与场景各自独立 —— 这属于内容取舍，需要你拍板。
4. **卡片标签在窄卡里竖排**（截图可见 `高性能`、`给方案` 被挤成一列）。既有布局问题，与本次改动无关。
5. **搜索框真机仍未验**：这台 ColorOS 上 `input text` / `keyevent` 落不进输入框（IME 未连接）。
6. `cn/CLAUDE.md` 第 8 条要求 commit 由人拍板；本轮按任务书要求每阶段一个可回滚提交，**未 push**。

## 8. 复现命令

```bash
cd cn
./gradlew :app:testDebugUnitTest --offline --rerun-tasks
# suites=83 tests=1019 failures=0 errors=0 skipped=2

cd ..
python3 tools/gen_experts.py --check
# OK 331 experts, 181710 bytes, hash 837153411685464d

./gradlew :app:assembleDebug && adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell run-as com.jev.probe cat files/kb/personas.json
adb shell run-as com.jev.probe cat shared_prefs/jev_assistant.xml | grep reply_style
```
