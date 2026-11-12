# legacy 数据迁移设计（W6）

> 状态：设计定稿 + core 骨架已实现。实现：`packages/core/lib/src/migration/legacy_importer.dart`，
> 测试：`packages/core/test/legacy_importer_test.dart`。legacy 参考代码为只读快照
> `_reference/chartools/cn/app/src/main/java/com/jev/probe/`（下文引用行号均指该快照）。

## 1. 背景与隔离现实

旧版应用包名 `com.jev.probe`，新版包名 `dev.chartools.chartools_app`。Android 以包名
划分应用沙箱：两个包名就是两个互不可见的私有目录，新版**不可能**直接读旧版的
`filesDir/kb`。旧版全部用户数据都在那一个目录里（`KbStore.kt:29-35`、`PersonaStore.kt:72-73`）：

```
filesDir/kb/
├── notes.json          笔记（裸数组）
├── contacts.json       联系人（裸数组）
├── personas.json       人设/专家（v2 对象 {version,seeded,removed,items}；v1 裸数组）
└── logs/<contactId>.json  每联系人聊天历史（≤300 条）及 .screen/.summary/.ledger 派生件
```

另一条被否决的路是「新版直接声明旧版路径 + 全文件访问权限」：Android 11+ 的
scoped storage 下读别的应用私有目录要么 root 要么系统级备份通道，普通用户走不通，
也不该让聊天助手申请这种权限。

**结论：数据转移只有一座桥 —— 旧版导出 ZIP，新版通用导入器。** 这也顺带满足
「通用」的要求：导入器不关心 ZIP 从哪台设备来，任何一份符合格式的迁移包都能导。

## 2. 迁移范围

| 数据 | 是否迁移 | 理由 |
| --- | --- | --- |
| notes.json 笔记 | ✅ | 用户手写的知识，legacy 无云端备份（`KbModels.kt:8`：no database, no network, no export），丢了就是真丢 |
| contacts.json 联系人 | ✅ | 关系/备注/绑定的人设原文，判断与起草链路都要用 |
| personas.json 人设/专家 | ✅ | 「人设不该被编译进 APK」的全部产出（`PersonaStore.kt:31-44`）；专家 = 有名的人设条目，同一份文件 |
| logs/ 聊天历史 | ⛔ 默认不迁 | 派生数据（screen 去重、摘要、台账都是推导物，`KbStore.kt:33-35`）；且是采集来的第三方对话内容，进新库需要单独的 opt-in 设计，v1 迁移不做 |
| seeded[]/removed[] 台账 | ⛔ | 语义绑定 legacy 自己的预设 key（`PersonaStore.kt:49-65`）；新版预设体系不同，搬过去只会让「补缺预设」误判 |
| experts.json 专家目录 | ⛔ | 随 APK 打包的只读货架（`ExpertPack.kt` ASSET 常量），不是用户数据；新版专家库走「按需资产包」重新下发 |
| Prefs（API key 等） | ⛔ | 密钥不该进明文 ZIP；新版让用户重填 |

## 3. 总体方案：桥的两半

```
旧版（com.jev.probe）                    新版（dev.chartools.chartools_app）
┌─────────────────────┐                ┌──────────────────────────────┐
│ 设置页「导出迁移包」 │  ZIP（用户自选 │ 解包 → manifest/文件 hash 校验│
│ 读 filesDir/kb 打包  │ ── 通道传输 ─→ │ → 容错解析 → 重复/冲突检测    │
└─────────────────────┘                │ → 迁移预览 → 用户确认 → 落盘  │
                                       └──────────────────────────────┘
```

### 3.1 ZIP 布局与 manifest

```text
chartools-legacy-<时间戳>.zip
├── manifest.json     识别串 / 版本 / 来源包名 / 导出时间 / 各文件 SHA-256 / 条目数
├── notes.json
├── contacts.json
└── personas.json
```

manifest.json 示例（结构在 `legacy_importer.dart` 的 `LegacyManifest`）：

```json
{
  "kind": "chartools-legacy-export",
  "version": 1,
  "fromPackage": "com.jev.probe",
  "exportedAt": 1700000000000,
  "files": { "notes.json": "<sha256>", "contacts.json": "<sha256>", "personas.json": "<sha256>" },
  "counts": { "notes": 12, "contacts": 3, "personas": 14 }
}
```

两条硬规则：

- `kind` 不是 `chartools-legacy-export` → **整包拒绝**，防止把随手压的 ZIP 导进一半；
- manifest 里没登记的文件**一律不导入**（`LegacyManifest.declares`），防夹带。

### 3.2 旧版侧怎么出包（现实约束）

legacy 本身**没有**导出功能 —— `KbModels.kt:8` 明写 v1.3 是 "no export"。可走的路按
推荐顺序：

1. **推荐：旧版设置页加「导出迁移包」**。改动最小：`KbStore.kt:100/153` 已有
   `notes()`/`contacts()` 全量读接口，`PersonaStore.kt:328-346` 已有 `exportJson()`，
   缺的只是打包成 ZIP + SAF 写到用户可见目录，一次改动可复用到所有旧版用户。
2. 备选：Android 系统的「备份与恢复」/厂商换机工具把 `com.jev.probe` 整体搬到
   新手机后再由新版旧包名过渡页出包——依赖厂商实现，不可控，只作兜底说明。
3. 不推荐：root/adb pull `filesDir/kb`。仅适合极客用户，文档里给附录级说明，不进产品路径。

## 4. 新版导入器管线

实现落点：`packages/core/lib/src/migration/legacy_importer.dart`（纯 Dart、零第三方
依赖；ZIP 解包因依赖平台 IO 留在 app 层，core 只吃解出的 JSON 字符串）。

```
① 格式校验    manifest kind/version → 文件清单 → 每个文件内容 SHA-256 与 manifest 对拍
② 容错解析    parseLegacyNotesJson / parseLegacyContactsJson / parseLegacyPersonasJson
③ 重复检测    内容 hash（内置 SHA-256，零依赖）对「新版已有数据 + 包内前文」判定
④ 迁移预览    MigrationPreview（N/M/K + 全部明细 + 问题清单）→ 用户确认 → MigrationSink 落盘
```

### 4.1 容错解析（不连坐）

字段结构对照 `KbStore.kt:414-428`（notes）、`KbStore.kt:430-452`（contacts）、
`PersonaStore.kt:608-641`（personas，v1 裸数组与 v2 对象双形态）。规则：

| 情况 | 处理 |
| --- | --- |
| 元素不是对象（裸字符串/数字） | 记 `MigrationProblem`（下标指回源文件第几条），跳过该条，其余照常 |
| 字段缺失 | 新版默认值（与 legacy `optXXX` 兜底同语义） |
| 字段类型不符 | 能收就收（数字标题→文本、字符串时间戳→数字、1.7e12→取整）；收不了退默认值（`tags` 非数组→空表、`alwaysOn:3`→false，与 org.json `optBoolean` 行为一致） |
| 笔记 title+content 双空 / 联系人 name 空 / 人设 body 空 | 记 problem 跳过（这条数据什么都不携带，legacy 同语义：`PersonaStore.kt:374`） |
| 整个文件不是 JSON | `parsed=false` + 文件级 problem；**只影响该文件**，另两个文件照常 |
| id 缺失 | 用内容 hash 合成 `imp-<类别>-<hash前10位>`：同一段内容重导得到同一个 id，重导幂等由此而来（legacy 是随手 `newId()`，重导会生重复条目） |

### 4.2 字段映射

| legacy | 新版 | 备注 |
| --- | --- | --- |
| notes.json 条目 | `Note`（`kb_models.dart:28`） | 全字段一一对应，tags/alwaysOn/enabled 属元数据不参与内容判定 |
| contacts.json 条目 | `Contact`（`kb_models.dart:66`） | 全字段一一对应；`contact.persona` 文本随迁 |
| personas.json 条目 | `ImportedPersona`（迁移契约记录） | 新版正式专家库模型定稿前，这份记录保证 legacy 全字段无损（行为层 body / 浏览层 name·avatar·description·tags·category·presetKey·usedCount·skillRefs·appPkgs，铁律见 `PersonaProfile.kt`） |
| personas.body | `PersonaCard.parse(body)`（`persona_card.dart`） | Character Card V2 兼容钩子：卡内键值（称呼/语气/边界/示例，含 `{{user}}`/`{{char}}`）被现算成结构化卡；认不出键 → 自由文本原样 |

### 4.3 重复检测与冲突

内容 hash 口径（归一化：去零宽字符 → trim → 连续空白折叠，参考 legacy
`normalizeName`，`KbStore.kt:639-643`）：

| 类别 | 参与判定的字段 | 不参与（元数据） |
| --- | --- | --- |
| note | type + title + content | tags / alwaysOn / enabled |
| contact | 名字 + 别名集合 + app 集合 + relationship + notes（列表排序后比） | persona / autoSummary |
| persona | 名字 + 正文 | avatar / description / tags / category（浏览层） |

判定顺序（`buildMigrationPreview`）：**先重复后冲突** —— 内容 hash 相同永远算重复
（无损跳过，哪怕名字也撞了）；hash 不同但同键（note 用 legacy id、contact/persona 用
归一化名）才算冲突，等用户裁决。判定对「新版已有数据」与「包内前文」同等生效。

| 结果 | 含义 | 默认去向 |
| --- | --- | --- |
| `insert`（将导入 N 条） | 全新内容 | 确认后入库 |
| `duplicate`（跳过 M 条） | 与已有/包内前文 hash 相同 | 不动已有数据，明细可查 |
| `conflict`（冲突 K 条） | 同键不同文 | 预览列明细（指回包内/既有哪条），用户三选一：改名导入 / 覆盖 / 放弃 |

重复检测沿用 legacy 的两条教训并加强：legacy `importJson` 自动把同名不同文改名为
「名字(导入)」（`PersonaStore.kt:399-413`）——好用但替用户做了决定；新版把决定权还给
用户，`detail` 里写明冲突对象与建议。

### 4.4 预览与确认后落盘（G8）

`MigrationPreview` 是导入器**唯一**的产出：N/M/K 计数 + 每条明细（来源文件、下标、
hash、状态、说明）+ 问题清单 + `describe()` 一句话摘要。core 里不存在任何从预览直接
写存储的路径；落盘契约是 `MigrationSink` 接口，由 app 层实现，且**必须**发生在用户
确认预览之后（G8「确认后入库」，`docs/p0-plan.md:140`、`docs/architecture.md` §9.3）。

- `preview.confirmedNotes/confirmedContacts/confirmedPersonas` 只含 `insert` 状态：
  冲突项必须被用户逐条点名（或整体选择「仍导入」）才会由 app 层从明细里挑出来；
- app 层也可以先只显示预览、明天再确认——预览是纯数据，不含任何待办副作用。

### 4.5 失败回滚

分两层：

1. **ZIP/解析层**：某文件损坏 → 只该文件记 problem，其余文件照常导入（对应 legacy
   `readJsonArray` 把坏文件改名 `.corrupt.<时间戳>` 保全而非覆盖的思路，`KbStore.kt:529-545`）。
   manifest hash 对拍在进解析器之前就能抓住传输损坏。
2. **落盘层（app 层实现 MigrationSink 时的契约）**：每段（notes/contacts/personas）
   要么全进要么全不进——写一半失败必须回滚该段，绝不留半截；实现建议 temp 文件 +
   rename 原子替换（legacy `writeAtomic` 同思路，`KbStore.kt:555-576`）；某段返回失败
   → 调用方停止后续段、把失败如实展示，**不得**把部分成功当整体成功报出去。

## 5. 验收用例表

实现与测试落点：`packages/core/test/legacy_importer_test.dart`（package:test）。

| # | 用例 | 输入 | 期望 | 测试 |
| --- | --- | --- | --- | --- |
| A1 | 完整导入 | 全字段齐全的 notes/contacts/personas + 空 `LegacyExistingIndex` | 三段逐字落位；缺 id 条目得到 `imp-*` 合成 id；`describe()` 报「将导入 N 条」 | `正常：字段齐全逐字落位…`、`v2 完整字段…`、`正常：全字段落位…` |
| A2 | 重复——包内 | 同一包内两条同内容笔记 | 第 1 条 insert、第 2 条 duplicate，明细指回「与包内第 1 条内容相同」 | `包内：同内容判重复、同 id 不同文判冲突` |
| A3 | 重复——对已有数据 | 包内内容与新版已有数据 hash 相同 | duplicate，明细报「与新版已有数据完全相同」；零宽字符不迷惑名字判定 | `对既有数据…`、`联系人：同名不同文冲突…` |
| A4 | 冲突 | 同 id/同名不同文 | conflict + 明细（对象与建议三选一）；确认集**不含**冲突项 | 同上两条 + `confirmed 集合只含 insert…` |
| A5 | 损坏文件 | 整文件非法 JSON / 顶层形状不对 / 空文件 | `parsed=false` + 文件级 problem，条目为空；manifest hash 对拍在解析前拦截 | `整包损坏 / 空文件…`、`kind 不对 / 版本超前 / 不是 JSON…` |
| A6 | 部分失败 | 一包里混坏条目（裸字符串、坏类型、空正文、空名）+ 好条目 | 好条目全进，坏条目各记一条 problem（下标指回源文件）；`describe()` 同时报 N/M/K 与问题数 | `坏类型…`、`没名字的联系人…`、`usedCount 负数…`、`describe 一句话…` |
| A7 | 缺文件 | ZIP 里少 contacts.json | 文件级 problem「迁移包里没有这个文件」，其余文件照常导入 | `缺文件：collectLegacyBundle…` |
| A8 | 重导幂等 | 上轮确认后的库 + 同一包再导 | 上轮已入库条目全部 duplicate，`importCount==0`；未确认的冲突项原样再冲突 | `重导幂等…` |
| A9 | manifest 校验 | kind 不符 / version 超前 / 未登记文件 | 整包拒绝或文件不导入，报因可读 | `合法 manifest…`、`kind 不对…` |
| A10 | hash 正确性 | — | 内置 SHA-256 通过 FIPS 空串/`abc` 校准向量 | `校准向量：空串`、`校准向量：abc` |

UI/E2E 级验收（出包 → 传输 → 导入 → 抽查 → 卸载）在旧版导出功能落地后补测，
不在本骨架的可测范围内——如实声明。

## 6. 时间线（用户卸载旧版前完成转移）

卸载旧版 = `filesDir/kb` 随沙箱一起销毁，**没有第二次机会**。整个流程必须先把数据
安全落进新版、抽查通过，才允许卸载；旧版在确认期保持只读不动。

| 阶段 | 动作 | 完成判据 |
| --- | --- | --- |
| T-0 发布前 | W6 core 骨架 + 测试过门禁；app 层排期：ZIP 解包页、预览 UI、MigrationSink 实现 | 本文档 + 测试全绿 |
| T1 旧版出包 | 用户在旧版设置页「导出迁移包」（或走附录级 adb 通道） | 拿到 ZIP；导出页显示条目数，与 manifest `counts` 一致 |
| T2 新版导入预览 | 新版「从旧版迁移」入口选 ZIP → 解包校验 → 展示 `MigrationPreview` | 预览 N/M/K 与明细、问题清单可逐条看懂 |
| T3 确认入库 | 用户确认 → `MigrationSink` 三段落盘（段级原子，失败即停） | 落盘返回 true；失败时库内容与导入前完全一致（回滚成立） |
| T4 抽查核对 | 用户抽查：笔记条数、关键联系人、2–3 张人设卡渲染 | 抽查项与旧版一致；冲突项已逐条裁决 |
| T5 观察期（建议 ≥3 天） | 旧版**保留不卸载**（只读），新版日常使用 | 新版无数据缺失反馈 |
| T6 卸载旧版 | 用户卸载 `com.jev.probe` | 数据已在新版沙箱内，旧目录销毁不再有影响 |

红线：T1 之前卸载旧版 → 数据不可恢复；T3 失败 → 保留旧版并反馈问题，禁止「删了重装试试」。

## 7. 范围外与后续

- **logs/ 聊天历史**：默认不迁（§2）。如后续做，必须单独 opt-in，且按联系人原样归档，
  不自动进提示词（历史是被采集的第三方话语，不是用户写的知识）。
- **专家资产包**：legacy 的 331 位目录不迁，新版按「按需资产包」设计重新下发；
  `ImportedPersona.presetKey` 只作来源登记，不参与新版播种/删除台账。
- **barrel 挂载**：`src/migration/legacy_importer.dart` 需挂进 `chartools_core.dart`
  才对 app 层可见（包约定「新增文件必须挂进 barrel」）；barrel 文件不在本工作流
  清单内，已留待 barrel 所有者处理——当前测试以 src 路径直引，功能不受影响。
- **UI/IO 层**：ZIP 解包、SAF 选文件、预览页面、MigrationSink 的具体存储实现，全部
  属于 app 层后续工作（G8 入口只有 UI 的既定架构）。
