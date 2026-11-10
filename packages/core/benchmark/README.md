# G5 中文对话 Benchmark

对应 `docs/p0-plan.md`「外部审查借鉴」G5 节：用固定的中文对话样本集度量判断与
回复质量，并按「高风险错判代价不对称」的原则分开计账（漏判高风险 ≠ 误判普通）。

## 目录结构

- `samples.json` —— 固定样本集（当前 14 条，全部模型起草、待人工复核，见下文
  「人工标注规范」）。
- `benchmark_runner.dart` —— 纯 Dart 评测 runner：样本加载与契约校验、判定结果
  与 expected_* 的匹配函数、边界遵守的本地规则检查、指标聚合、在线评测编排。
  只依赖本包与 dart: 核心库，与 core 的零第三方约束一致。
- `../test/benchmark_test.dart` —— `dart test` 形式的入口：默认组全部离线；
  在线组标 `online` tag，需要 API key，CI 没有 key 时整组自动跳过。
- `out/` —— 在线评测的报告输出（运行时生成，不入库）。

## 怎么跑

离线（不调任何模型，CI 与本地默认跑的就是它）：

```bash
cd packages/core
dart test test/benchmark_test.dart
```

在线（对每个样本真调一次判断路由；生产路径 JudgeClient，chat 协议经 ChatJudge）：

```bash
export CHARTOOLS_BENCH_JUDGE_BASE=https://api.deepseek.com
export CHARTOOLS_BENCH_JUDGE_KEY=sk-...
export CHARTOOLS_BENCH_JUDGE_MODEL=deepseek-chat
# 可选，默认 chat；decisions 协议时 BASE 按 JevConfig 规则拼 /alpha/decisions
export CHARTOOLS_BENCH_JUDGE_PROTOCOL=chat

cd packages/core
dart test test/benchmark_test.dart --tags online
```

- 三个必填变量（BASE / KEY / MODEL）缺任何一个，在线组自动 skip（skip 理由里写明），
  不会报错，也不会拖累离线组。
- 在线跑完把报告写到 `benchmark/out/online_report.json`，并往 stderr 打印逐条
  结果与中文汇总（`BenchmarkReport.render()`）。
- `dart test` 可能提示 tag `online` 未在 dart_test.yaml 里声明——只是提示，
  不影响结果。要消除它需在 packages/core/dart_test.yaml 声明该 tag；本次没有动
  那个文件（不属于本目录）。

## 样本 schema

八个规格字段（G5 原文要求，全部必填）：

| 字段 | 说明 |
|---|---|
| `conversation` | 消息数组，每条 `{from: "me"\|"other", text}`；判断按全线程读，最后一条通常是对方最新消息 |
| `relationship` | 关系，取值 朋友 / 恋人 / 客户 / 同事（覆盖面要求各 ≥2） |
| `expected_intent` | Jev `true_intent` 的选项键（如 `confirm_you_care`），加载时对照现役题集校验 |
| `expected_risk` | `danger_level` 期望档位 0..9 |
| `expected_action` | Jev `best_action` 的选项键 |
| `forbidden_commitments` | 回复里不许出现的承诺；**写成会出现在回复里的具体词**（如「周五一定交付」） |
| `forbidden_facts` | 回复里不许断言的事实（模型最爱编的部分） |
| `acceptable_reply_traits` | 好回复应有的特质；给人与人工盲评看的对照清单，机器不逐条打分 |

评测 harness 的扩展字段（可选）：

| 字段 | 说明 |
|---|---|
| `id` | 样本唯一 id，报告与测试按它定位 |
| `expected_she_needs` / `expected_should_reply` / `expected_tension_resolved` | 其余判断维度的期望值；不标则不计入该维度分母 |
| `tags` | 类别标签：意图六类（试探 / 施压 / 抱怨 / 设边界 / 日常 / 角色推进）、风险三类（承诺 / 金钱 / 隐私）、`安全词` |
| `persona` | 人设卡 `{safeword, yellow, boundaries}`；带卡的样本离线走 SafetyGate 边界检查 |
| `fixture_answer` | 一份「好判官会怎么答」的固定判定 fixture（answers 形状，允许大写键、裸值等归一化边角）；离线链路用它走完 ChatJudge.answersFrom → 匹配 → 打分 |
| `human_reviewed` / `annotator` | 人工复核状态与复核人，见下文 |
| `note` | 标注理由，给复核人看 |

## 怎么加样本

1. 在 `samples.json` 的 `samples` 数组里加一条，八个规格字段必填。
2. 期望值必须来自现役题集：`JevQuestions.judge()` 里 `true_intent` / `best_action`
   / `she_needs` 的 criteria 键、`danger_level` 的 0..9 档。加载时逐一校验，
   写错直接报错——题集改了契约、样本没跟上也会在这里炸出来。
3. `tags` 至少标一个意图类别；涉险再加风险类别；对方明确设边界标「设边界」，
   并保证（带 `persona` 卡）或（`forbidden_commitments` 非空）二者有其一。
4. `fixture_answer` 按 expected_* 填。它是回归 fixture，不是模型输出；整批样本
   的离线测试会断言每个 fixture 都能命中自己的 expected_*。
5. 跑 `dart test test/benchmark_test.dart`：schema、覆盖面（≥12 条、四类关系各
   ≥2、六类意图 + 三类风险、至少一条设边界）、离线链路全绿才算数。

## 人工标注规范（模型不给自己打分）

- expected_* 是 ground truth，**只能由人工确认**。模型可以起草样本、对话、
  expected 初稿与 fixture，但起草态样本一律 `human_reviewed: false`；报告会
  分开报告人工确认比例（`人工确认 N，模型起草待复核 M`）。
- 模型不得自行把 `human_reviewed` 置为 true，也不得在复核流程里给自己的输出
  当复核人。
- 人工复核 checklist：
  1. 对照 `JevQuestions.judge()` 的 instructions / criteria 逐条核对
     expected_intent / expected_action / expected_she_needs——题面怎么定义就怎么标，
     不凭语感。
  2. expected_risk 对照 danger_level 的十条标准逐档核对；拿不准就降一档并把
     理由写进 note。
  3. expected_should_reply 按「实质内容」（认下具体过错 / 给时间计划 / 解释已知
     事实 / 复述被要求的内容）的定义标，**不是**「要不要回消息」。
  4. forbidden_commitments / forbidden_facts 必须写成会出现在回复里的具体词；
     检查器按大小写与空白归一后的子串匹配（与 SafetyGate.flatten 同口径）。
  5. 至少两人独立复核；分歧的样本改对话或弃用，不硬凑共识。
  6. 通过后：`human_reviewed: true`，`annotator` 填复核人，分歧与理由进 note。
- 质量结论只统计 `human_reviewed == true` 的样本；未复核样本只用于回归与冒烟。

## 指标口径

- 各维度准确率：意图 / 行动 / 需求按选项逐字相等；风险分 ±0 与 ±1 两档分别报；
  should_reply_now 与 tension_resolved 按 0.5 门槛二值化后比对。
- 分母 = 标了该维度的样本数；判题没答出来（或调用失败）一律计不中，不剔除——
  「没答」不是「同意」。
- 高风险错判不对称计账（阈值 `high_risk_threshold = 6`，与提示词「局势偏紧」
  level ≥ 6 同口径）：
  - 漏判：expected_risk ≥ 6 而判低或没判出——单独计数，代价最高；
  - 误报：expected_risk < 6 而判到 ≥ 6——单独计数；
  - 两者绝不合并成一个「错误率」。
- 边界遵守：带 persona 卡的样本离线走 SafetyGate（必须拦截，如安全词）；没卡的
  设边界样本用 forbidden_commitments 在回复级检查，检查器本身用 fixture 回复钉住。
- 延迟 P95：在线模式按每次判断调用的真实耗时取最近邻秩 P95；离线模式没有真实
  调用，报告里显示为占位。
- 按关系分组：意图 / 风险(±0) / 行动的命中数按 朋友 / 恋人 / 客户 / 同事 分开报。

## 当前范围（诚实边界）

- 在线评测目前只评**判断路由**（JudgeClient / ChatJudge）的维度。forbidden_*
  的回复级检查在离线用 fixture 回复钉住检查器行为；在线起草评测（ReplyClient）
  是下一步，schema 已为它留好字段。
- G5 指标里的自然度（需要人工盲评）、排序一致性（需要 rank 调用）、单轮费用
  三个尚未接入。
- 本批 14 条样本全部模型起草、`human_reviewed: false`：离线测试只能证明
  解析与匹配链路本身正确，**不能当作任何模型的质量结论**。
