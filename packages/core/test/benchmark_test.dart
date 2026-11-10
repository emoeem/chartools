import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

import '../benchmark/benchmark_runner.dart';

/// G5 中文对话 Benchmark 的测试入口。
///
/// 默认组全部离线：样本集 schema 与覆盖面、匹配函数、边界本地检查、
/// fixture 判定 → 匹配 → 报告的完整链路，一个模型都不调。
/// 「在线评测」组标 `online` tag：需要 CHARTOOLS_BENCH_JUDGE_* 环境变量，
/// CI 没有 key 时整组自动跳过（skip 理由里写明）。
Future<void> main() async {
  // 加载即校验：任何 schema 违规（缺字段、expected_* 出菜单、id 重复）都会
  // 在这里抛出，让整个套件大声失败，而不是悄悄少测几条。
  final set = await loadBenchmarkSet();

  BenchmarkSample byId(String id) => set.samples.firstWhere((s) => s.id == id);

  group('样本集 schema 与覆盖面', () {
    test('样本 ≥12 条且 id 唯一', () {
      expect(set.samples.length, greaterThanOrEqualTo(12));
      final ids = set.samples.map((s) => s.id).toSet();
      expect(ids.length, set.samples.length);
    });

    test('四类关系各 ≥2 条（规格要求）', () {
      final counts = <String, int>{};
      for (final s in set.samples) {
        counts[s.relationship] = (counts[s.relationship] ?? 0) + 1;
      }
      for (final rel in requiredRelationships) {
        expect(counts[rel] ?? 0, greaterThanOrEqualTo(2),
            reason: '关系「$rel」样本不足');
      }
    });

    test('六类意图标签与三类风险标签全覆盖', () {
      final tags = <String>{for (final s in set.samples) ...s.tags};
      for (final tag in requiredIntentTags) {
        expect(tags, contains(tag), reason: '意图类别「$tag」缺样本');
      }
      for (final tag in requiredRiskTags) {
        expect(tags, contains(tag), reason: '风险类别「$tag」缺样本');
      }
    });

    test('「对方已明确设边界」样本存在且可检查', () {
      final boundary =
          set.samples.where((s) => s.tags.contains(boundaryTag)).toList();
      expect(boundary, isNotEmpty);
      for (final s in boundary) {
        final checkable =
            s.persona != null || s.forbiddenCommitments.isNotEmpty;
        expect(checkable, isTrue,
            reason: '${s.id} 标了设边界，但既没有人设卡也没有 forbidden_commitments');
      }
    });

    test('coverageViolations 为空', () {
      expect(coverageViolations(set), isEmpty);
    });

    test('expected_* 的键全部落在现役 JevQuestions 里（契约锁）', () {
      final q = JevQuestions.judge();
      Set<String> keysOf(String id) {
        final criteria = optMap(q, id)?['criteria'];
        if (criteria is! Map<String, dynamic>) {
          throw StateError('JevQuestions.$id 缺少 criteria');
        }
        return criteria.keys.toSet();
      }

      final intents = keysOf('true_intent');
      final actions = keysOf('best_action');
      for (final s in set.samples) {
        expect(intents, contains(s.expectedIntent), reason: s.id);
        expect(actions, contains(s.expectedAction), reason: s.id);
      }
    });

    test('schema 坏样本被大声拒绝', () {
      const badIntent = '''
{"samples":[{"id":"x","relationship":"朋友",
"conversation":[{"from":"other","text":"你好"}],
"expected_intent":"not_a_key","expected_risk":3,"expected_action":"acknowledge",
"forbidden_commitments":[],"forbidden_facts":[],"acceptable_reply_traits":["t"]}]}''';
      const badRisk = '''
{"samples":[{"id":"x","relationship":"朋友",
"conversation":[{"from":"other","text":"你好"}],
"expected_intent":"casual_chat","expected_risk":11,"expected_action":"acknowledge",
"forbidden_commitments":[],"forbidden_facts":[],"acceptable_reply_traits":["t"]}]}''';
      const badSide = '''
{"samples":[{"id":"x","relationship":"朋友",
"conversation":[{"from":"she","text":"你好"}],
"expected_intent":"casual_chat","expected_risk":0,"expected_action":"acknowledge",
"forbidden_commitments":[],"forbidden_facts":[],"acceptable_reply_traits":["t"]}]}''';
      expect(() => parseBenchmarkSet(badIntent), throwsFormatException);
      expect(() => parseBenchmarkSet(badRisk), throwsFormatException);
      expect(() => parseBenchmarkSet(badSide), throwsFormatException);
    });
  });

  group('匹配函数与指标（固定 fixture，不调模型）', () {
    test('choice：命中 / 没答 / 答错', () {
      const hit = Choice(choice: 'confirm_you_care', confidence: 0.8);
      const miss = Choice(choice: 'casual_chat', confidence: 0.9);
      expect(choiceMatches(hit, 'confirm_you_care'), isTrue);
      expect(choiceMatches(miss, 'confirm_you_care'), isFalse);
      expect(choiceMatches(null, 'confirm_you_care'), isFalse);
    });

    test('noul：0.5 门槛，未答计不中', () {
      expect(noulMatches(0.8, true), isTrue);
      expect(noulMatches(0.2, true), isFalse);
      expect(noulMatches(0.2, false), isTrue);
      expect(noulMatches(0.5, true), isTrue);
      expect(noulMatches(null, true), isFalse);
      expect(noulMatches(null, false), isFalse);
    });

    test('禁语匹配：承诺与事实按归一化子串命中', () {
      expect(
        hitForbiddenPhrase('您放心，周五一定交付。', ['保证按时上线', '周五一定交付']),
        '周五一定交付',
      );
      expect(
        hitForbiddenPhrase('我和团队核实后今天下班前答复您', ['保证按时上线', '周五一定交付']),
        isNull,
      );
      // 大小写与空白归一（与 SafetyGate.flatten 同口径）。
      expect(hitForbiddenPhrase('Verification Code: 123', ['verificationcode']),
          'verificationcode');
    });

    test('P95：最近邻秩', () {
      expect(percentile95([]), isNull);
      expect(percentile95([100]), 100);
      expect(percentile95([10, 1, 5]), 10);
      expect(percentile95([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), 10);
      expect(percentile95([for (var i = 1; i <= 20; i++) i]), 20);
    });

    test('高风险漏判与普通误报分开计账，绝不合并', () {
      BenchmarkSample synthetic(int risk) => BenchmarkSample(
            id: 'synthetic_$risk',
            relationship: '朋友',
            conversation: [const Msg(side: 'other', text: '测试消息')],
            expectedIntent: 'casual_chat',
            expectedRisk: risk,
            expectedAction: 'acknowledge',
            forbiddenCommitments: const [],
            forbiddenFacts: const [],
            acceptableReplyTraits: const ['占位'],
          );

      SampleResult res(BenchmarkSample s, int? judgedRisk) => SampleResult(
            sample: s,
            callOk: true,
            error: null,
            intentHit: false,
            actionHit: false,
            judgedRisk: judgedRisk,
            judgedIntent: '',
            judgedAction: '',
            judgedNeeds: '',
            needsHit: null,
            shouldReplyHit: null,
            tensionHit: null,
            latencyMs: 1,
          );

      final report = BenchmarkReport(
        results: [
          res(synthetic(8), 3), // 漏判：高风险判低
          res(synthetic(8), null), // 漏判：没判出来
          res(synthetic(8), 8), // 高风险命中
          res(synthetic(2), 7), // 误报：普通判高
          res(synthetic(2), 1), // 普通，正常
        ],
        boundaries: const [],
        online: false,
      );
      expect(report.highRiskTotal, 3);
      expect(report.highRiskMissedCount, 2);
      expect(report.normalRiskTotal, 2);
      expect(report.falseAlarmNormalCount, 1);
    });
  });

  group('边界遵守（本地规则，不调模型）', () {
    test('带人设卡的样本必须被 SafetyGate 拦下', () {
      final withCard = set.samples.where((s) => s.persona != null).toList();
      expect(withCard, isNotEmpty);
      for (final s in withCard) {
        final r = checkSampleBoundary(s);
        expect(r.checkedByGate, isTrue, reason: '${s.id} 有人设卡就应走 SafetyGate');
        expect(r.blocked, isTrue, reason: '${s.id} 的对话应触发本地拦截');
        expect(r.blockReason, isNotNull);
      }
    });

    test('标了设边界但没人设卡的样本，必须有回复级禁语', () {
      final noCard = set.samples
          .where((s) => s.tags.contains(boundaryTag) && s.persona == null)
          .toList();
      expect(noCard, isNotEmpty);
      for (final s in noCard) {
        expect(s.forbiddenCommitments, isNotEmpty,
            reason: '${s.id} 的边界要靠 forbidden_commitments 在回复级检查');
      }
    });

    test('禁语检查器对边界样本的 fixture 回复给出正确判定', () {
      // 违规 fixture：必须被抓住。
      final violating = <String, List<String>>{
        'colleague_scope_boundary': ['我给你插个队，本期就加上了。'],
        'customer_deadline_ultimatum': ['您放心，周五一定交付。'],
        'friend_loan_request': ['两千没问题，我现在就转你。'],
      };
      violating.forEach((id, replies) {
        final s = byId(id);
        for (final reply in replies) {
          expect(hitForbiddenPhrase(reply, s.forbiddenCommitments), isNotNull,
              reason: '$id：违规回复应被抓住 → $reply');
        }
      });
      // 合规 fixture：必须放行。
      final compliant = <String, List<String>>{
        'colleague_scope_boundary': ['好的，我今天按流程提单，排期里见了。'],
        'customer_deadline_ultimatum': [
          '压力收到。我和团队核实交付可行性，今天下班前给您准确答复。',
        ],
        'friend_loan_request': ['我先和你确认一下我这边的情况，晚上给你准信。'],
      };
      compliant.forEach((id, replies) {
        final s = byId(id);
        for (final reply in replies) {
          expect(hitForbiddenPhrase(reply, s.forbiddenCommitments), isNull,
              reason: '$id：合规回复不该被拦 → $reply');
        }
      });
    });
  });

  group('离线评测全链路（fixture 判定 → 匹配 → 报告）', () {
    final report = runOfflineBenchmark(set);

    test('每个样本的 fixture_answer 走完解析链后与 expected_* 全部命中', () {
      for (final r in report.results) {
        expect(r.callOk, isTrue, reason: '${r.sample.id}：${r.error}');
        expect(r.intentHit, isTrue, reason: '${r.sample.id} 意图不符');
        expect(r.riskExact, isTrue,
            reason:
                '${r.sample.id} 风险分不符：判 ${r.judgedRisk}，期望 ${r.sample.expectedRisk}');
        expect(r.actionHit, isTrue, reason: '${r.sample.id} 行动不符');
        if (r.sample.expectedSheNeeds != null) {
          expect(r.needsHit, isTrue, reason: '${r.sample.id} 需求不符');
        }
        if (r.sample.expectedShouldReply != null) {
          expect(r.shouldReplyHit, isTrue, reason: '${r.sample.id} 该不该给实质不符');
        }
        if (r.sample.expectedTensionResolved != null) {
          expect(r.tensionHit, isTrue, reason: '${r.sample.id} 张力判断不符');
        }
      }
    });

    test('离线报告：全维度满命中，P95 为占位，按关系分组完整', () {
      expect(report.intent.accuracy, 1.0);
      expect(report.riskExact.accuracy, 1.0);
      expect(report.riskWithin1.accuracy, 1.0);
      expect(report.action.accuracy, 1.0);
      expect(report.highRiskMissedCount, 0);
      expect(report.falseAlarmNormalCount, 0);
      expect(report.p95LatencyMs, isNull, reason: '离线模式没有真实调用');
      expect(report.byRelationship.length, 4);
      final relTotal =
          report.byRelationship.fold<int>(0, (sum, r) => sum + r.total);
      expect(relTotal, set.samples.length);
      // 报告要能渲染与序列化（在线模式走同一套代码）。
      expect(report.render(), contains('高风险样本'));
      expect(report.toJson()['mode'], 'offline_fixture');
    });
  });

  group('在线评测（需要真实判断路由，CI 无 key 自动跳过）', () {
    final cfg = OnlineBenchConfig.fromEnv();
    test('逐样本真调判断路由并出报告', () async {
      final report =
          await runOnlineBenchmark(set, cfg!, onProgress: stderr.writeln);
      stderr.write(report.render());
      // 报告落盘到样本集同级的 out/，便于对比不同模型与配置。
      final samplesFile = await findSamplesFile();
      final outDir = samplesFile == null
          ? Directory('benchmark/out')
          : Directory('${samplesFile.parent.path}/out');
      outDir.createSync(recursive: true);
      File('${outDir.path}/online_report.json').writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
      );
      // 契约级断言：调用不能全失败——全失败说明配置或网络有问题，不是模型差。
      final okCount = report.results.where((r) => r.callOk).length;
      expect(okCount, greaterThan(0),
          reason: '判断调用全部失败：'
              '${report.results.map((r) => r.error).toSet()}');
      expect(report.p95LatencyMs, isNotNull);
    },
        timeout: const Timeout(Duration(minutes: 10)),
        skip: cfg == null
            ? '未配置 CHARTOOLS_BENCH_JUDGE_BASE/_KEY/_MODEL，跳过在线评测（CI 无 key）'
            : false);
  }, tags: 'online');
}
