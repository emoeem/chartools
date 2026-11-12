# 专家资产包统一格式（jev-expert-pack/1）

> 状态：**权威规范**（独立复核裁定后补记）。裁定结论：core 三件套
> （`expert_pack.dart` / `expert_catalog.dart` / `expert_apply.dart`）是专家库的
> **预留权威 API**；app 层当前的平行实现（`app/lib/application/experts_controller.dart`
> 的 `ExpertPack/ExpertCatalog/ExpertSort/StyleSink`）按 legacy 形状运行，
> **#13 接线时必须二选一收敛**（推荐：app 弃用自有包体系改用 core 三件套，
> core 校验更严、有来源追踪与降级拒装）。收敛完成前，两套解析器对同一份
> 远端包必须认得出同一批专家——本文件写死互认规则，格式演进以 core 为准。

## 1. 唯一格式：`jev-expert-pack/1`

```json
{
  "format": "jev-expert-pack/1",
  "pack":   { "id": "sales-pro", "version": "1.2.0", "origin": "remote",
              "name": "", "source": "", "sourceCommit": "", "contentHash": "" },
  "experts": [ { "id": "followup", "promptText": "称呼：您\n…" } ]
}
```

- `format` 字段**只能**是 `jev-expert-pack/1`。core `PackCodec.parse`（安装路径）
  缺 format / 值不匹配即拒——升级格式时旧解析器必须拒绝而不是猜着解析。
- `pack.id` 禁止 `/`（会破坏专家全局 id 的 `pack:<packId>/<key>` 形状）。
- 远端清单（「货架目录的目录」）格式：`jev-expert-remote-manifest/1`，
  形状 `{"format": ..., "packs": [{"id","version","url",...}]}`。

## 2. 字段别名互认（双拼写，主拼写在前）

app 层当前包体系沿用 legacy ExpertPack.kt 的字段名，收敛前两套拼写都必须被
两套解析器认出（任一侧全量跳过 = 同一份远端包在某边「消失」，独立复核判为
高危）：

| 语义 | core 主拼写 | app/legacy 别名 | 互认位置 |
|---|---|---|---|
| 条目键（全局 id 的一半） | `id` | `key` | core `decodeExpertEntry`；app `ExpertPack.parse` |
| 进提示词的正文 | `promptText` | `body` | 同上 |
| 浏览层分类 | `domain` | `category` | 同上（core 主拼写是 `domain`） |
| 包级元数据 | `pack{...}` 对象 | 顶层 `name`/`source`/`sourceCommit`/`contentHash` | app `ExpertPack.parse` 顶层缺席时回退读 `pack` |

app 解析器对 `format` 只容忍不校验（严格校验归 core PackCodec）；core 解析器
对 `key`/`body` 别名的容忍**不**延伸到 `format`——想让 app 形状的历史包走 core
安装路径，必须补上 `format` 与 `pack{id,version}`。

## 3. 不可信清单的尺寸护栏

远端清单是不可信数据，解析路径一律设上限（超限**跳过该条并计数进
problem**，与逐条容错风格一致，不整包放弃）：

| 护栏 | 值 | 位置 |
|---|---|---|
| 单包 `experts[]` 条数 | `PackCodec.maxExpertsPerPack = 2000`（对应 legacy 文档导入 MAX_CHUNKS=2000，DocImport.kt:53） | `PackCodec.parse` |
| 单条 `promptText` 字节数（utf8） | `expertPromptTextMaxBytes = 64 KiB` | `decodeExpertEntry`（浏览路径与安装路径共用） |
| 远端清单 `packs[]` 条数 | `PackCodec.maxPacksPerManifest = 2000` | `RemoteManifestCodec.parse` |

`contentHash` / `sha256` 只透传不校验（core 零第三方依赖没有 SHA-256），校验
归 app 层——不假装验证过。

## 4. PackStore 实现要求（安全键）

`PackStore`（`expert_pack.dart`）的 `save/remove/loadAll(packId)`：

- `packId` 是**不可信数据**，必须只作键名/键值使用，**绝不直接拼进文件路径**
  ——core 只拦 `/`，`..\`、控制字符等由实现方拒绝；
- 最稳做法与 `MemoryPackStore` 同款：KV 存原文（SharedPreferences 一类），
  文件名用固定名或自造 id，不用 pack.id。

## 5. 套用动作（ExpertApply / StyleSource）

「专用人设压全局风格」的优先级判定、冲突检测（`StyleSource.resolve`）、
needsChoice 时不落笔——唯一出处是 core `expert_apply.dart` + `style_source.dart`。
app 页面层不得手写同等判定（复核对齐要求：判定规则变更只改一处）。app 层
`experts_page.dart` 的套用确认弹窗据此提供 core 语义的两种选择：
**覆盖**（重写专用人设）/ **并存**（写入全局风格、专用人设保留并继续压全局）。
