# 测试

测试分为两类：每次构建都会运行的离线单元测试，以及会产生少量费用、需手动运行的真实模型评估。

## 离线单元测试

在 `global/` 目录下运行：

```bash
export JAVA_HOME=/path/to/jdk-17
./gradlew test
```

无需 API 密钥或网络。模型请求由 `FakeGateway`（`core/src/test/kotlin/com/jev/overseas/core/testing/`）模拟；它可以按脚本返回答案或错误，并记录每次请求。

| 测试类 | 覆盖内容 |
|---|---|
| `OpenRouterGatewayTest` | 请求头和请求体、状态码映射、缺失而非臆造的格式错误答案、超时、错误文本中不泄露密钥、空密钥、`keyInfo()` |
| `ConversationTest` | 最新轮次划分、未知发送者、仅含媒体的轮次、说明文字、引用、700 字符截断、24 条消息窗口、行过滤、拉丁文字检查、短回复和结构特征、拼写方式 |
| `LexiconTest` | 缩写词汇表：仅匹配完整单词、大小写、单字母 |
| `GoalBuilderTest` | 根据立场、补充信息、开关和修改后的摘要生成目标 |
| `SceneDataTest` | 每种场景、关系（含无关系）和冲突设置：问题 ID 唯一性、请求大小、优先级 ID、每个操作均可回答、六个等级、选项规则、变体、语气规则、问题文本不含表情符号或长破折号 |
| `ApprovedMatrixTest` | 手工填写在 `approved/matrix.tsv`（165 行）的五个已批准矩阵的所有单元格：每格均实际运行分析，并要求给出获批的立场和下一步；短回复语气规则；矩阵指定不提问的场景不提问；通用场景中的“想你”。恋爱场景 R08 尚待决定（会列出，但不作为断言） |
| `ApprovedApologyTest` | 每种立场在不同关系下的道歉等级；依据手工填写的 `approved/apology.tsv`（85 行） |
| `ReadingTableGoldenTest` | 代码自身读取表的快照（`golden/reading-table.txt`）。它只能证明代码没有意外变更，不能证明代码符合已批准行为（后者由 `ApprovedMatrixTest` 检查） |
| `AnalysisEngineTest` | 六种下一步、先处理威胁再处理界限、不确定答案要求用户选择、仅基于线索的分组、语气卡、提示、标签数量上限、缺失答案、阈值边界 |
| `DraftingTest` | 解析（代码围栏、替代键、截断 JSON、循环、套话）、清理、提示词结构、聊天文本作为数据传递 |
| `CandidateChecksTest` | 需要执行的检查、六种候选状态及其顺序、阈值边界、S 公式、仅表达方式评分、排序、“评分相近” |
| `AssistantTest` | 跳过原因、使用完全相同的请求重试一次、认证错误不重试、起草重试、根据反馈修订一次、请求预算不超限（200 个随机脚本）、90 秒等待上限、取消 |
| `WhatsAppReplayTest` | 录制的八个 WhatsApp 屏幕 |

设置 `JEV_UPDATE_GOLDEN=1` 可重新生成黄金文件；仅在有意修改后执行，并仔细检查差异。`approved/` 下的文件不会自动生成：只有在行为变更已获同意时才修改，并在提交说明中注明。

## 实时评估（付费）

需要在 `OPENROUTER_API_KEY` 中设置 OpenRouter 密钥，或写入 `~/.config/jev/openrouter.env`（格式为 `OPENROUTER_API_KEY=<key>`，也可以只写密钥）。每次调用都会追加到未纳入版本控制的 `_reports/ledger.jsonl`。

```bash
./gradlew -q :core:liveEval -PevalArgs="analysis"    # 试验语料：行为检测
./gradlew -q :core:liveEval -PevalArgs="candidates"  # 作者编写回复的硬性检查和评分
./gradlew -q :core:liveEval -PevalArgs="ladders"     # 不同等级回复的评分顺序
./gradlew -q :core:liveEval -PevalArgs="draft"       # 端到端起草和检查
./gradlew -q :core:liveEval -PevalArgs="edge"        # 非常规输入（corpus/edge-v1）
./gradlew -q :core:liveEval -PevalArgs="revision"    # v0.1 修订调试集；case=g|apology|matrix|checks|friction
```

添加 `case=<prefix>` 可只运行一部分用例；添加 `raw` 可打印每个概率值。
设置 `JEV_DEBUG_CHAT=1` 可打印起草模型的原始输出。

### 当前结果

以下结果是与语料作者预期标签的一致率，测试对象是用于调整阈值的同一组 37 个试验用例。它们不是准确率，也未经独立标注者验证。

| 运行项 | 结果 |
|---|---|
| analysis | 预期为真的行为命中 48/48；预期为假的行为中 51/54 明确排除（3 个不确定，0 个错误）；摩擦 73/74；语气 37/37；必须先选择 37/37；基准立场 31/31 |
| candidates | 有违规的回复拦截 6/6；无问题的回复未被拦截 11/12 |
| ladders | 4 组等级回复，没有顺序倒置 |
| draft（2026-10-02，重复内容修复后） | 7/7 个目标均生成了两条可解析回复；21 次请求，费用 $0.0038 |
| edge（2026-10-02） | 符合预期 12/13；22 次请求，费用 $0.0035 |
| revision（2026-10-03） | G 完成度阶梯：60 对有序样本中有 1 对倒置超过 0.25。道歉草稿：预期情况下会给出简短道歉，avoid 和“Don't apologise”情况下不会道歉；所有礼貌性道歉中的 `admits_fault` 均 ≤ 0.08。此前从未进行实时评估的 24 行矩阵：检测 24/24，立场 16/16。`beyond_goal` 6/6，`contradicts_earlier` 6/6。仅修改措辞时摩擦范围为 5/8；让摩擦单独请求最新轮次和此前 4 条消息后为 8/8（试验组 `analysis` 重跑结果未变：摩擦 73/74、语气 37/37、必须先选择 37/37、立场 31/31）。共 80 + 8 + 74 次请求，费用总计 $0.0205 |

修订集是为该轮次编写的调试集，并非独立验证集。

已知不足：

- 回复仅隐含“工作会延期”（例如 “It'll be ready on Monday, sorry for the delay”）时，有时会被判为不确定；由于不确定的必需项会要求用户检查，因此会显示“有 1 项需要检查”。
- 两个同名联系人会被视为同一个身份（使用标题哈希），记住的场景和“填入”操作的“同一聊天”检查也会受影响。
- 15 分钟缓存无法发现较早消息被编辑或删除的情况。
- WhatsApp 读取循环（滚动、指纹识别）只在设备上运行，没有 JVM 测试。
- 通过消息上方另一位成员的姓名识别群聊。如果群聊屏幕只显示用户自己的消息，在更早的屏幕显示其他成员之前，它会被误认为一对一聊天。

边界用例评估发现：

- 对方引用了较早请求，随后回复“nvm sorted it, thanks anyway”时，仍会要求用户选择立场：操作相关问题落入不确定范围；按设计，不确定的答案会计入“先选择”。
- 对方表示“please stop texting me”后，简短回复“I'll stop”会被标记为未经授权的承诺。尊重界限的回复会要求用户确认或被拦截。
