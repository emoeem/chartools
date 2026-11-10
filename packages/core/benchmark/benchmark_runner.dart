/// G5 中文对话 Benchmark —— 样本加载与校验、匹配函数、边界本地检查、指标聚合
/// 与在线评测编排。
///
/// 规格：docs/p0-plan.md「外部审查借鉴」G5 节。样本 schema 的八个规格字段
/// （conversation / relationship / expected_intent / expected_risk /
/// expected_action / forbidden_commitments / forbidden_facts /
/// acceptable_reply_traits）之外，本目录补充了评测 harness 需要的可选字段
/// （id / tags / persona / fixture_answer / human_reviewed 等），字段表见
/// benchmark/README.md。
///
/// 两层职责：
///  - 离线可测（本文件 + test/benchmark_test.dart 的默认组）：样本解析与
///    expected_* 契约校验、判定结果与 expected_* 的匹配函数、边界遵守的
///    本地规则检查（SafetyGate + 禁语匹配）、指标聚合。全程不调模型，
///    判定输入用样本自带的 fixture_answer。
///  - 在线评测（[runOnlineBenchmark]，测试里标 `online` tag）：对每个样本真调
///    一次判断路由（JudgeClient，chat 协议经 ChatJudge），按同一套匹配函数
///    打分。需要 API key，CI 没有 key 时整组跳过。
///
/// 纯 Dart：除本包与 dart: 核心库外零依赖，与 core 的零第三方约束一致。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:chartools_core/chartools_core.dart';

/// 高风险阈值：expected_risk 达到该档及以上算高风险样本。口径与
/// ReplyPrompt.judgmentBlock 的「局势偏紧」（level >= 6）一致；samples.json
/// meta 里的 high_risk_threshold 只是给人看的镜像，以这个常量为准。
const int highRiskThreshold = 6;

/// noul 类判断（should_reply_now / tension_resolved）按「给不给实质」二值化的
/// 门槛，与 ReplyPrompt 判断块（< 0.5 视为不急）同一口径。
const double noulThreshold = 0.5;

/// 覆盖面要求：规格点名的四类关系，各 ≥2 条。
const List<String> requiredRelationships = ['朋友', '恋人', '客户', '同事'];

/// 覆盖面要求：六类意图，每类至少一条样本（按 tags 记账）。
const List<String> requiredIntentTags = [
  '试探',
  '施压',
  '抱怨',
  '设边界',
  '日常',
  '角色推进',
];

/// 覆盖面要求：三类风险，每类至少一条样本（按 tags 记账）。
const List<String> requiredRiskTags = ['承诺', '金钱', '隐私'];

/// 「对方已明确设边界」场景的标签。
const String boundaryTag = '设边界';

// ---------------------------------------------------------------- 样本模型

/// 一条样本里的人设卡（只为边界本地检查服务，字段与 PersonaCard 对齐）。
class SamplePersona {
  const SamplePersona({
    this.safeword = '',
    this.yellow = '',
    this.boundaries = const [],
  });

  final String safeword;
  final String yellow;
  final List<String> boundaries;
}

/// 一条人工标注的评测样本。
class BenchmarkSample {
  BenchmarkSample({
    required this.id,
    required this.relationship,
    required this.conversation,
    required this.expectedIntent,
    required this.expectedRisk,
    required this.expectedAction,
    required this.forbiddenCommitments,
    required this.forbiddenFacts,
    required this.acceptableReplyTraits,
    this.expectedSheNeeds,
    this.expectedShouldReply,
    this.expectedTensionResolved,
    this.tags = const [],
    this.persona,
    this.fixtureAnswer,
    this.humanReviewed = false,
    this.annotator = '',
    this.note = '',
  });

  final String id;
  final String relationship;

  /// 对话原文。side 只允许 me / other（评测样本不做发言人不明）。
  final List<Msg> conversation;

  final String expectedIntent;
  final int expectedRisk;
  final String expectedAction;
  final List<String> forbiddenCommitments;
  final List<String> forbiddenFacts;

  /// 好回复应有的特质：给人与人工盲评看的对照清单，机器不逐条打分。
  final List<String> acceptableReplyTraits;

  final String? expectedSheNeeds;
  final bool? expectedShouldReply;
  final bool? expectedTensionResolved;
  final List<String> tags;
  final SamplePersona? persona;

  /// 一份「好判官会怎么答」的固定判定 fixture（answers 形状，允许大小写/
  /// 裸值等归一化边角）。离线链路用它走完 ChatJudge.answersFrom → 匹配 →
  /// 打分，全称不调模型。
  final Map<String, dynamic>? fixtureAnswer;

  /// ground truth 状态：只有人工确认过才是 true。模型起草的样本永远是 false，
  /// 且模型不得自行置 true（见 benchmark/README.md 的人工标注规范）。
  final bool humanReviewed;
  final String annotator;
  final String note;

  /// 对方说过的话。边界检查只看这些行——我方的措辞不该触发对方边界的拦截。
  List<String> otherLines() => [
        for (final m in conversation)
          if (m.side != 'me') m.text
      ];

  /// 送进判断路由的快照（与桌面粘贴流等价：整段对话就是一屏）。
  ChatSnapshot snapshot() => ChatSnapshot(messages: conversation);

  /// 样本自带的人设卡；没带 persona 的样本返回 null。
  PersonaCard? personaCard() {
    final p = persona;
    if (p == null) return null;
    return PersonaCard(
      boundaries: p.boundaries,
      safeword: p.safeword,
      yellow: p.yellow,
    );
  }
}

/// 整个样本集。
class BenchmarkSet {
  const BenchmarkSet({
    required this.name,
    required this.version,
    required this.samples,
  });

  final String name;
  final int version;
  final List<BenchmarkSample> samples;
}

// ------------------------------------------------------------------ 加载

/// 样本文件位置：优先按包根解析（dart test 的 CWD 不保证是包根，工作区内
/// 从仓库根跑也一样能找到），再退回几个常见的工作目录。
Future<File?> findSamplesFile() async {
  final candidates = <String>[];
  Uri? libUri;
  try {
    libUri = await Isolate.resolvePackageUri(
      Uri.parse('package:chartools_core/chartools_core.dart'),
    );
  } catch (_) {
    libUri = null;
  }
  final libPath = libUri?.toFilePath();
  if (libPath != null) {
    // …/packages/core/lib/chartools_core.dart → 包根的 benchmark/samples.json
    final pkgRoot = File(libPath).parent.parent.path;
    candidates.add('$pkgRoot/benchmark/samples.json');
  }
  candidates
    ..add('benchmark/samples.json')
    ..add('packages/core/benchmark/samples.json');
  for (final path in candidates) {
    final f = File(path);
    if (f.existsSync()) return f;
  }
  return null;
}

/// 读取并解析样本集。任何 schema 违规都抛异常（FormatException /
/// StateError），带样本 id——评测集坏了必须大声失败，不能悄悄少测。
Future<BenchmarkSet> loadBenchmarkSet() async {
  final file = await findSamplesFile();
  if (file == null) {
    throw StateError(
      '找不到 benchmark/samples.json：请在 packages/core 或仓库根下运行。',
    );
  }
  return parseBenchmarkSet(file.readAsStringSync());
}

/// 解析样本集文本；样本的 expected_* 逐一对照**现役** JevQuestions 校验，
/// 题集改了契约、样本没跟上时在这里炸出来。
BenchmarkSet parseBenchmarkSet(String raw) {
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('samples.json 顶层必须是 JSON 对象');
  }
  final list = decoded['samples'];
  if (list is! List<dynamic>) {
    throw const FormatException('samples.json 缺少 samples 数组');
  }
  final meta = optMap(decoded, 'meta');

  final judge = JevQuestions.judge();
  final intentKeys = _choiceKeys(judge, 'true_intent');
  final actionKeys = _choiceKeys(judge, 'best_action');
  final needKeys = _choiceKeys(judge, 'she_needs');
  final dangerLevels = _scoreLevels(judge, 'danger_level');

  final samples = <BenchmarkSample>[];
  final seen = <String>{};
  for (final item in list) {
    if (item is! Map<String, dynamic>) {
      throw const FormatException('samples 数组里有非对象元素');
    }
    final s = _parseSample(
      item,
      intentKeys: intentKeys,
      actionKeys: actionKeys,
      needKeys: needKeys,
      dangerLevels: dangerLevels,
    );
    if (seen.contains(s.id)) {
      throw FormatException('样本 id 重复：${s.id}');
    }
    seen.add(s.id);
    samples.add(s);
  }
  if (samples.isEmpty) {
    throw const FormatException('样本集为空');
  }
  return BenchmarkSet(
    name: optString(meta, 'name', 'chartools 中文对话 benchmark'),
    version: optInt(meta, 'version', 1),
    samples: samples,
  );
}

Set<String> _choiceKeys(Map<String, dynamic> judge, String id) {
  final criteria = optMap(judge, id)?['criteria'];
  if (criteria is! Map<String, dynamic> || criteria.isEmpty) {
    throw StateError('JevQuestions.$id 缺少 choice criteria，契约校验无法进行');
  }
  return Set<String>.from(criteria.keys);
}

List<dynamic> _scoreLevels(Map<String, dynamic> judge, String id) {
  final criteria = optMap(judge, id)?['criteria'];
  if (criteria is! List<dynamic> || criteria.isEmpty) {
    throw StateError('JevQuestions.$id 缺少 score criteria');
  }
  return criteria;
}

BenchmarkSample _parseSample(
  Map<String, dynamic> j, {
  required Set<String> intentKeys,
  required Set<String> actionKeys,
  required Set<String> needKeys,
  required List<dynamic> dangerLevels,
}) {
  Never fail(String msg) => throw FormatException(msg);

  String requiredString(String key) {
    final v = j[key];
    if (v is String && v.trim().isNotEmpty) return v.trim();
    fail('样本缺少必填字符串字段 $key');
  }

  List<String> stringList(Map<String, dynamic> m, String key) {
    final v = m[key];
    if (v == null) return const [];
    if (v is! List<dynamic>) fail('样本字段 $key 必须是字符串数组');
    final out = <String>[];
    for (final e in v) {
      if (e is String && e.trim().isNotEmpty) out.add(e.trim());
    }
    return out;
  }

  bool? optBoolStrict(String key) {
    final v = j[key];
    if (v == null) return null;
    if (v is bool) return v;
    fail('样本字段 $key 必须是布尔');
  }

  final id = requiredString('id');
  final intent = requiredString('expected_intent');
  if (!intentKeys.contains(intent)) {
    fail('样本 $id：expected_intent「$intent」不在 JevQuestions.true_intent 的选项里');
  }
  final action = requiredString('expected_action');
  if (!actionKeys.contains(action)) {
    fail('样本 $id：expected_action「$action」不在 JevQuestions.best_action 的选项里');
  }
  final riskRaw = j['expected_risk'];
  if (riskRaw is! num) fail('样本 $id：expected_risk 必须是数字');
  final risk = riskRaw.toInt();
  if (risk < 0 || risk >= dangerLevels.length) {
    fail(
        '样本 $id：expected_risk 超出 danger_level 的 0..${dangerLevels.length - 1}');
  }
  String? needs;
  final needsRaw = j['expected_she_needs'];
  if (needsRaw != null) {
    if (needsRaw is! String || !needKeys.contains(needsRaw)) {
      fail(
          '样本 $id：expected_she_needs「$needsRaw」不在 JevQuestions.she_needs 的选项里');
    }
    needs = needsRaw;
  }

  final rawConv = j['conversation'];
  if (rawConv is! List<dynamic> || rawConv.isEmpty) {
    fail('样本 $id：conversation 必须是非空数组');
  }
  final conversation = <Msg>[];
  for (final e in rawConv) {
    if (e is! Map<String, dynamic>) fail('样本 $id：conversation 里有非对象元素');
    final from = optString(e, 'from');
    final text = optString(e, 'text');
    if (text.trim().isEmpty) fail('样本 $id：conversation 里有空消息');
    if (from != 'me' && from != 'other') {
      fail('样本 $id：conversation 的 from 只能是 me/other（评测样本不做发言人不明）');
    }
    conversation.add(Msg(side: from, text: text));
  }

  SamplePersona? persona;
  final rawPersona = j['persona'];
  if (rawPersona != null) {
    if (rawPersona is! Map<String, dynamic>) fail('样本 $id：persona 必须是对象');
    persona = SamplePersona(
      safeword: optString(rawPersona, 'safeword'),
      yellow: optString(rawPersona, 'yellow'),
      boundaries: stringList(rawPersona, 'boundaries'),
    );
  }

  Map<String, dynamic>? fixture;
  final rawFixture = j['fixture_answer'];
  if (rawFixture != null) {
    if (rawFixture is! Map<String, dynamic>) {
      fail('样本 $id：fixture_answer 必须是 JSON 对象');
    }
    fixture = rawFixture;
  }

  final traits = stringList(j, 'acceptable_reply_traits');
  if (traits.isEmpty) {
    fail('样本 $id：acceptable_reply_traits 不能为空（人工评审要看它）');
  }
  final humanReviewed = optBoolStrict('human_reviewed') ?? false;

  return BenchmarkSample(
    id: id,
    relationship: requiredString('relationship'),
    conversation: conversation,
    expectedIntent: intent,
    expectedRisk: risk,
    expectedAction: action,
    forbiddenCommitments: stringList(j, 'forbidden_commitments'),
    forbiddenFacts: stringList(j, 'forbidden_facts'),
    acceptableReplyTraits: traits,
    expectedSheNeeds: needs,
    expectedShouldReply: optBoolStrict('expected_should_reply'),
    expectedTensionResolved: optBoolStrict('expected_tension_resolved'),
    tags: stringList(j, 'tags'),
    persona: persona,
    fixtureAnswer: fixture,
    humanReviewed: humanReviewed,
    annotator: optString(j, 'annotator'),
    note: optString(j, 'note'),
  );
}

/// 覆盖面检查：不满足规格要求的覆盖面就返回非空违规清单（每条一句话）。
List<String> coverageViolations(BenchmarkSet set) {
  final violations = <String>[];
  if (set.samples.length < 12) {
    violations.add('样本数 ${set.samples.length} 少于规格要求的 12 条');
  }
  final byRel = <String, int>{};
  final tagsSeen = <String>{};
  var boundarySamples = 0;
  for (final s in set.samples) {
    byRel[s.relationship] = (byRel[s.relationship] ?? 0) + 1;
    tagsSeen.addAll(s.tags);
    if (s.tags.contains(boundaryTag)) {
      boundarySamples++;
      if (s.persona == null && s.forbiddenCommitments.isEmpty) {
        violations.add(
          '样本 ${s.id} 标了「$boundaryTag」，但既没有人设卡也没有 '
          'forbidden_commitments，边界遵守无从检查',
        );
      }
    }
  }
  for (final rel in requiredRelationships) {
    final n = byRel[rel] ?? 0;
    if (n < 2) violations.add('关系「$rel」只有 $n 条样本，规格要求 ≥2');
  }
  for (final tag in requiredIntentTags) {
    if (!tagsSeen.contains(tag)) violations.add('意图类别「$tag」没有样本覆盖');
  }
  for (final tag in requiredRiskTags) {
    if (!tagsSeen.contains(tag)) violations.add('风险类别「$tag」没有样本覆盖');
  }
  if (boundarySamples == 0) {
    violations.add('没有「对方已明确设边界」（tag $boundaryTag）的样本');
  }
  return violations;
}

// ---------------------------------------------------------------- 匹配函数

/// choice 判定是否命中期望：没答出来算不中，答案必须逐字等于期望键。
bool choiceMatches(Choice? judged, String expected) =>
    judged != null && judged.choice == expected;

/// noul 判定是否与期望一致；没答出来算不中（「没说」不是「同意」）。
bool noulMatches(double? judged, bool expected) =>
    judged != null && (judged >= noulThreshold) == expected;

/// 回复里出现了被禁止的承诺/事实（大小写与空白归一后子串命中，与
/// SafetyGate.flatten 同一归一口径）。返回命中的禁语；没命中返回 null。
String? hitForbiddenPhrase(String reply, List<String> forbidden) {
  final flat = SafetyGate.flatten(reply);
  for (final f in forbidden) {
    if (flat.contains(SafetyGate.flatten(f))) return f;
  }
  return null;
}

// -------------------------------------------------------------- 判定与打分

/// 一条样本的打分结果（离线 fixture 与在线真调共用同一套口径）。
class SampleResult {
  SampleResult({
    required this.sample,
    required this.callOk,
    required this.error,
    required this.intentHit,
    required this.actionHit,
    required this.judgedRisk,
    required this.judgedIntent,
    required this.judgedAction,
    required this.judgedNeeds,
    required this.needsHit,
    required this.shouldReplyHit,
    required this.tensionHit,
    required this.latencyMs,
  });

  final BenchmarkSample sample;

  /// 判定调用本身是否成功（解析出了答案）。失败时各维度一律算不中。
  final bool callOk;
  final String? error;

  final bool intentHit;
  final bool actionHit;

  /// 判出的风险档；null = 没判出来（调用失败或答案缺失）。
  final int? judgedRisk;
  final String judgedIntent;
  final String judgedAction;
  final String judgedNeeds;

  /// 样本没标对应 expected_* 时为 null（不计入该维度分母）。
  final bool? needsHit;
  final bool? shouldReplyHit;
  final bool? tensionHit;
  final int latencyMs;

  int? get riskGap =>
      judgedRisk == null ? null : judgedRisk! - sample.expectedRisk;

  bool get riskExact => judgedRisk != null && judgedRisk == sample.expectedRisk;

  bool get riskWithin1 => riskGap != null && riskGap! >= -1 && riskGap! <= 1;

  /// 期望高风险却判低（或没判出）——错判里代价最高的一类，单独记账。
  bool get highRiskMissed =>
      sample.expectedRisk >= highRiskThreshold &&
      (judgedRisk == null || judgedRisk! < highRiskThreshold);

  /// 期望普通风险却判成高风险——单独记账，绝不与漏判合并。
  bool get normalRiskFalseAlarm =>
      sample.expectedRisk < highRiskThreshold &&
      judgedRisk != null &&
      judgedRisk! >= highRiskThreshold;

  Map<String, dynamic> toJson() => {
        'id': sample.id,
        'relationship': sample.relationship,
        'human_reviewed': sample.humanReviewed,
        'call_ok': callOk,
        'error': error,
        'intent': {
          'expected': sample.expectedIntent,
          'judged': judgedIntent,
          'hit': intentHit,
        },
        'risk': {
          'expected': sample.expectedRisk,
          'judged': judgedRisk,
          'gap': riskGap,
          'hit': riskExact,
        },
        'action': {
          'expected': sample.expectedAction,
          'judged': judgedAction,
          'hit': actionHit,
        },
        'needs_hit': needsHit,
        'should_reply_hit': shouldReplyHit,
        'tension_hit': tensionHit,
        'latency_ms': latencyMs,
      };
}

/// 判定结果（Analysis）与 expected_* 的匹配。离线与在线唯一的不同是
/// Analysis 从哪来：fixture 解析，还是真调判断路由。
SampleResult evaluateAnalysis(BenchmarkSample s, Analysis a) {
  final risk = a.dangerLevel;
  return SampleResult(
    sample: s,
    callOk: a.error == null,
    error: a.error,
    intentHit: choiceMatches(a.trueIntent, s.expectedIntent),
    actionHit: choiceMatches(a.bestAction, s.expectedAction),
    judgedRisk: risk == null ? null : risk.score.round(),
    judgedIntent: a.trueIntent?.choice ?? '',
    judgedAction: a.bestAction?.choice ?? '',
    judgedNeeds: a.sheNeeds?.choice ?? '',
    needsHit: s.expectedSheNeeds == null
        ? null
        : choiceMatches(a.sheNeeds, s.expectedSheNeeds!),
    shouldReplyHit: s.expectedShouldReply == null
        ? null
        : noulMatches(a.shouldReplyNow, s.expectedShouldReply!),
    tensionHit: s.expectedTensionResolved == null
        ? null
        : noulMatches(a.tensionResolved, s.expectedTensionResolved!),
    latencyMs: a.latencyMs,
  );
}

/// 离线评测一条样本：fixture_answer（JSON 对象）序列化后走
/// ChatJudge.answersFrom 的完整归一化链路，再镜像 JudgeClient.judge 的
/// answers → Analysis 读法打分。全程不调模型。
SampleResult evaluateSampleOffline(BenchmarkSample s) {
  final fixture = s.fixtureAnswer;
  if (fixture == null) {
    return _offlineFailure(s, '样本没有 fixture_answer，离线链路无从断言');
  }
  Map<String, dynamic> answers;
  try {
    answers = ChatJudge.answersFrom(jsonEncode(fixture), JevQuestions.judge());
  } catch (e) {
    return _offlineFailure(s, 'fixture_answer 解析失败：$e');
  }
  return evaluateAnalysis(s, _analysisFromAnswers(answers, 0));
}

SampleResult _offlineFailure(BenchmarkSample s, String msg) => SampleResult(
      sample: s,
      callOk: false,
      error: msg,
      intentHit: false,
      actionHit: false,
      judgedRisk: null,
      judgedIntent: '',
      judgedAction: '',
      judgedNeeds: '',
      needsHit: s.expectedSheNeeds == null ? null : false,
      shouldReplyHit: s.expectedShouldReply == null ? null : false,
      tensionHit: s.expectedTensionResolved == null ? null : false,
      latencyMs: 0,
    );

/// 与 JudgeClient.judge 的 answers → Analysis 映射保持一致（那一半在
/// JudgeClient 里与 HTTP 耦合，这里镜像同样的读法，离线链路才等价）。
Analysis _analysisFromAnswers(Map<String, dynamic> answers, int latencyMs) =>
    Analysis(
      trueIntent: JudgeAnswers.choice(optMap(answers, 'true_intent')),
      dangerLevel: JudgeAnswers.score(optMap(answers, 'danger_level')),
      sheNeeds: JudgeAnswers.choice(optMap(answers, 'she_needs')),
      shouldReplyNow: _optNoul(answers, 'should_reply_now'),
      bestAction: JudgeAnswers.choice(optMap(answers, 'best_action')),
      tensionResolved: _optNoul(answers, 'tension_resolved'),
      literalQuestion: _optNoul(answers, 'literal_question'),
      rankedReplies: const [],
      latencyMs: latencyMs,
    );

double? _optNoul(Map<String, dynamic> answers, String key) {
  final o = optMap(answers, key);
  if (o == null || o['noul'] == null) return null;
  return optDouble(o, 'noul');
}

// ------------------------------------------------------------ 边界本地检查

/// 一条样本的边界本地检查结果。
class SampleBoundaryResult {
  const SampleBoundaryResult({
    required this.sample,
    required this.blocked,
    required this.checkedByGate,
    this.blockReason,
    this.caution = '',
  });

  final BenchmarkSample sample;

  /// 本地门禁（SafetyGate）是否拦下这一轮。
  final bool blocked;
  final String? blockReason;
  final String caution;

  /// 是否走了 SafetyGate：样本带人设卡才走。没卡的设边界样本，边界约束落在
  /// forbidden_commitments 的回复级检查上（见 hitForbiddenPhrase）。
  final bool checkedByGate;
}

/// 用样本自带的人设卡对对方的行做本地门禁检查（生产同款逻辑，零模型调用）。
SampleBoundaryResult checkSampleBoundary(BenchmarkSample s) {
  final card = s.personaCard();
  if (card == null) {
    return SampleBoundaryResult(
        sample: s, blocked: false, checkedByGate: false);
  }
  final v = SafetyGate.check(s.otherLines(), card);
  return SampleBoundaryResult(
    sample: s,
    blocked: v.blocked,
    blockReason: v.blockReason,
    caution: v.caution,
    checkedByGate: true,
  );
}

// ------------------------------------------------------------------ 报告

/// 一个维度的命中统计。分母 = 标了该维度的样本数；没答出来（或调用失败）
/// 一律计不中，不剔除。
class DimensionStat {
  DimensionStat(this.label);

  final String label;
  int total = 0;
  int hits = 0;
  int misses = 0;

  double? get accuracy => total == 0 ? null : hits / total;

  void add(bool? hit) {
    if (hit == null) return;
    total++;
    if (hit) {
      hits++;
    } else {
      misses++;
    }
  }

  Map<String, dynamic> toJson() => {
        'label': label,
        'total': total,
        'hits': hits,
        'misses': misses,
        'accuracy': accuracy,
      };
}

/// 按关系分组的命中统计。
class RelationshipStat {
  RelationshipStat(this.relationship);

  final String relationship;
  int total = 0;
  int intentHits = 0;
  int riskExactHits = 0;
  int actionHits = 0;

  Map<String, dynamic> toJson() => {
        'relationship': relationship,
        'total': total,
        'intent_hits': intentHits,
        'risk_exact_hits': riskExactHits,
        'action_hits': actionHits,
      };
}

/// 一次评测（离线或在线）的汇总报告。
class BenchmarkReport {
  BenchmarkReport({
    required List<SampleResult> results,
    required List<SampleBoundaryResult> boundaries,
    required this.online,
  })  : results = List<SampleResult>.unmodifiable(results),
        boundaries = List<SampleBoundaryResult>.unmodifiable(boundaries) {
    for (final r in results) {
      intent.add(r.intentHit);
      riskExact.add(r.riskExact);
      riskWithin1.add(r.riskWithin1);
      action.add(r.actionHit);
      needs.add(r.needsHit);
      shouldReply.add(r.shouldReplyHit);
      tension.add(r.tensionHit);
      final rel = byRelationshipMap.putIfAbsent(
        r.sample.relationship,
        () => RelationshipStat(r.sample.relationship),
      );
      rel.total++;
      if (r.intentHit) rel.intentHits++;
      if (r.riskExact) rel.riskExactHits++;
      if (r.actionHit) rel.actionHits++;
    }
  }

  final List<SampleResult> results;
  final List<SampleBoundaryResult> boundaries;

  /// true = 在线真调（延迟是真的）；false = 离线 fixture（延迟 P95 是占位）。
  final bool online;

  final intent = DimensionStat('意图');
  final riskExact = DimensionStat('风险(±0)');
  final riskWithin1 = DimensionStat('风险(±1)');
  final action = DimensionStat('行动');
  final needs = DimensionStat('需求');
  final shouldReply = DimensionStat('该不该给实质');
  final tension = DimensionStat('张力已化解');

  final Map<String, RelationshipStat> byRelationshipMap = {};
  late final List<RelationshipStat> byRelationship =
      byRelationshipMap.values.toList(growable: false);

  int get highRiskTotal =>
      results.where((r) => r.sample.expectedRisk >= highRiskThreshold).length;

  int get highRiskMissedCount => results.where((r) => r.highRiskMissed).length;

  int get normalRiskTotal =>
      results.where((r) => r.sample.expectedRisk < highRiskThreshold).length;

  int get falseAlarmNormalCount =>
      results.where((r) => r.normalRiskFalseAlarm).length;

  int get gateCheckedTotal => boundaries.where((b) => b.checkedByGate).length;

  int get gateBlockedTotal =>
      boundaries.where((b) => b.checkedByGate && b.blocked).length;

  int get humanReviewedCount =>
      results.where((r) => r.sample.humanReviewed).length;

  /// 延迟 P95。离线模式恒为 null（fixture 没有真实调用），渲染成占位。
  int? get p95LatencyMs => online
      ? percentile95([
          for (final r in results)
            if (r.callOk) r.latencyMs
        ])
      : null;

  String render() {
    final sb = StringBuffer();
    sb.write(
      'G5 中文对话 Benchmark 报告（模式：${online ? '在线真调' : '离线 fixture'}）\n',
    );
    sb.write(
      '样本数：${results.length}（人工确认 $humanReviewedCount，'
      '模型起草待复核 ${results.length - humanReviewedCount}）\n',
    );
    void line(String label, DimensionStat d) {
      final acc = d.accuracy;
      final pct = acc == null ? '—' : '${(acc * 100).toStringAsFixed(1)}%';
      sb.write('$label：${d.hits}/${d.total} = $pct（不中 ${d.misses}）\n');
    }

    line('意图准确率', intent);
    line('风险准确率(±0)', riskExact);
    line('风险准确率(±1)', riskWithin1);
    line('行动准确率', action);
    line('需求准确率', needs);
    line('该不该给实质', shouldReply);
    line('张力已化解', tension);
    sb.write('\n—— 高风险错判（不对称计账：漏判 ≠ 误报）——\n');
    sb.write(
      '高风险样本（expected_risk ≥ $highRiskThreshold）：$highRiskTotal；'
      '漏判（判低或没判出）：$highRiskMissedCount\n',
    );
    sb.write(
      '普通样本：$normalRiskTotal；误报（判成高风险）：$falseAlarmNormalCount\n',
    );
    sb.write('\n—— 边界遵守（本地规则）——\n');
    sb.write(
      '带人设卡走 SafetyGate 的样本：$gateCheckedTotal；本地拦截：$gateBlockedTotal\n',
    );
    sb.write('\n—— 按关系分组（意图/风险±0/行动命中数）——\n');
    for (final r in byRelationship) {
      sb.write(
        '${r.relationship}：${r.total} 条，意图 ${r.intentHits}，'
        '风险 ${r.riskExactHits}，行动 ${r.actionHits}\n',
      );
    }
    final p95 = p95LatencyMs;
    sb.write(
      '\n延迟 P95：${p95 == null ? '占位（离线模式无真实调用）' : '$p95 ms'}\n',
    );
    return sb.toString();
  }

  Map<String, dynamic> toJson() => {
        'mode': online ? 'online' : 'offline_fixture',
        'high_risk_threshold': highRiskThreshold,
        'sample_count': results.length,
        'human_reviewed_count': humanReviewedCount,
        'intent': intent.toJson(),
        'risk_exact': riskExact.toJson(),
        'risk_within_1': riskWithin1.toJson(),
        'action': action.toJson(),
        'needs': needs.toJson(),
        'should_reply': shouldReply.toJson(),
        'tension': tension.toJson(),
        'high_risk': {
          'total': highRiskTotal,
          'missed': highRiskMissedCount,
        },
        'normal_risk': {
          'total': normalRiskTotal,
          'false_alarm': falseAlarmNormalCount,
        },
        'boundary_gate': {
          'checked': gateCheckedTotal,
          'blocked': gateBlockedTotal,
        },
        'by_relationship': [
          for (final r in byRelationship) r.toJson(),
        ],
        'p95_latency_ms': p95LatencyMs,
        'results': [for (final r in results) r.toJson()],
      };
}

/// 最近邻秩（nearest-rank）P95：升序取第 ⌊0.95·n⌋+1 个（1 起），即
/// 「至少 95% 的样本严格小于该值」——当 0.95·n 恰为整数时取再上一个，
/// 例如 20 条取第 20 个。秩用整数运算 `95n~/100` 计算，避免浮点误差。
/// 空表返回 null。
int? percentile95(List<int> xs) {
  if (xs.isEmpty) return null;
  final sorted = [...xs]..sort();
  var idx = sorted.length * 95 ~/ 100 + 1; // 1 起的秩
  if (idx < 1) idx = 1;
  if (idx > sorted.length) idx = sorted.length;
  return sorted[idx - 1];
}

/// 离线跑全量样本：fixture 解析 + 匹配 + 边界本地检查，聚合出报告。
BenchmarkReport runOfflineBenchmark(BenchmarkSet set) {
  final results = <SampleResult>[];
  final boundaries = <SampleBoundaryResult>[];
  for (final s in set.samples) {
    results.add(evaluateSampleOffline(s));
    boundaries.add(checkSampleBoundary(s));
  }
  return BenchmarkReport(
    results: results,
    boundaries: boundaries,
    online: false,
  );
}

// ---------------------------------------------------------------- 在线评测

/// 在线评测的环境变量契约（详见 benchmark/README.md）：
/// CHARTOOLS_BENCH_JUDGE_BASE / _KEY / _MODEL 必填，_PROTOCOL 可选（默认 chat）。
class OnlineBenchConfig {
  const OnlineBenchConfig({
    required this.baseUrl,
    required this.key,
    required this.model,
    required this.protocol,
  });

  final String baseUrl;
  final String key;
  final String model;
  final String protocol;

  /// 三个必填变量缺任何一个就返回 null，调用方整组跳过（CI 没有 key）。
  static OnlineBenchConfig? fromEnv() {
    final base = Platform.environment['CHARTOOLS_BENCH_JUDGE_BASE'] ?? '';
    final key = Platform.environment['CHARTOOLS_BENCH_JUDGE_KEY'] ?? '';
    final model = Platform.environment['CHARTOOLS_BENCH_JUDGE_MODEL'] ?? '';
    final protocol =
        Platform.environment['CHARTOOLS_BENCH_JUDGE_PROTOCOL'] ?? 'chat';
    if (base.trim().isEmpty || key.trim().isEmpty || model.trim().isEmpty) {
      return null;
    }
    return OnlineBenchConfig(
      baseUrl: base.trim(),
      key: key.trim(),
      model: model.trim(),
      protocol: protocol.trim(),
    );
  }

  JevConfig toJevConfig() => JevConfig()
    ..judgeProvider = 'jev'
    ..judgeBaseUrl = baseUrl
    ..judgeKey = key
    ..judgeModel = model
    ..judgeProtocol = protocol;
}

/// 在线评测：逐条真调判断路由（每个样本一次 judge 调用），用与离线相同的
/// 匹配函数打分。串行执行，避免并发触发限流；调用失败不中断，按「没判出来」
/// 计账（高风险样本失败即漏判——这正是代价不对称要暴露的）。
Future<BenchmarkReport> runOnlineBenchmark(
  BenchmarkSet set,
  OnlineBenchConfig cfg, {
  void Function(String line)? onProgress,
}) async {
  final client = JudgeClient(cfg.toJevConfig());
  final results = <SampleResult>[];
  final boundaries = <SampleBoundaryResult>[];
  var i = 0;
  for (final s in set.samples) {
    i++;
    final analysis = await client.judge(s.snapshot(), s.relationship);
    results.add(evaluateAnalysis(s, analysis));
    boundaries.add(checkSampleBoundary(s));
    onProgress?.call(
      '[$i/${set.samples.length}] ${s.id}: '
      '${analysis.error ?? _judgeLine(analysis)}',
    );
  }
  return BenchmarkReport(
    results: results,
    boundaries: boundaries,
    online: true,
  );
}

String _judgeLine(Analysis a) => '意图=${a.trueIntent?.choice ?? '未答'} '
    '风险=${a.dangerLevel == null ? '未答' : a.dangerLevel!.score.round()} '
    '行动=${a.bestAction?.choice ?? '未答'}';
