import 'dart:convert';
import 'dart:io';

// linter 尚未挂进 barrel（barrel 文件归别的文件所有，见任务 notes），同包内
// 直接走 src 路径；其余类型都从对外出口拿。
import 'package:chartools_core/chartools_core.dart';
import 'package:chartools_core/src/pipeline/ai_flavor_linter.dart';
import 'package:test/test.dart';

/// AI 腔本地 linter（A2）+ 正向示范开关（A1）的测试。
///
/// A1 的测试落在这个文件里是文件所有权使然：本轮只分配了这一个新测试文件，
/// reply_prompt_test.dart 归 prompt 侧所有——A1 的「默认输出不变」对照锁
/// 因此也放在这里（见最后的 group）。
void main() {
  group('FlavorHit', () {
    test('只带 rule 与 evidence，等值按两字段', () {
      const hit = FlavorHit('r', 'e');
      expect(hit.rule, 'r');
      expect(hit.evidence, 'e');
      expect(hit, const FlavorHit('r', 'e'));
      expect(hit, isNot(const FlavorHit('r', 'e2')));
      expect(hit.toString(), contains('r'));
    });
  });

  group('排比堆叠', () {
    test('正例：连续 3 个同头短句', () {
      final hits = AiFlavorLinter.lint('我懂你的累，我懂你的难，我懂你的委屈。');
      final hit = hits
          .firstWhere((h) => h.rule == AiFlavorLinter.ruleParallelStack);
      expect(hit.evidence, contains('我懂你的累'));
      expect(hit.evidence, contains('3 个同构短句'));
    });

    test('正例：连续 3 个同长短句', () {
      final hits = AiFlavorLinter.lint('早起一杯水，饭后百步走，睡前泡个脚。');
      expect(hits.map((h) => h.rule),
          contains(AiFlavorLinter.ruleParallelStack));
    });

    test('反例：正常行文不命中', () {
      final hits = AiFlavorLinter.lint('我先去洗澡，然后吃饭，再写作业。');
      expect(hits.where((h) => h.rule == AiFlavorLinter.ruleParallelStack),
          isEmpty);
    });
  });

  group('总结升华尾句', () {
    test('正例：尾句用「总之」收尾', () {
      final hits = AiFlavorLinter.lint('别多想了，总之都会过去的。');
      final hit =
          hits.firstWhere((h) => h.rule == AiFlavorLinter.ruleSummaryTail);
      expect(hit.evidence, contains('总之'));
    });

    test('正例：「说到底」也是总结腔', () {
      expect(AiFlavorLinter.lint('都过去了。说到底你们都还在意。')
          .map((h) => h.rule), contains(AiFlavorLinter.ruleSummaryTail));
    });

    test('反例：无总结腔不命中', () {
      expect(AiFlavorLinter.lint('别多想了，都会过去的。')
          .where((h) => h.rule == AiFlavorLinter.ruleSummaryTail), isEmpty);
    });

    test('反例：「总之」不在尾句（句中）不命中', () {
      // 尾句是「吃完再说」——总结腔只认最后一个句读。
      expect(AiFlavorLinter.lint('总之先吃饭，吃完再说。')
          .where((h) => h.rule == AiFlavorLinter.ruleSummaryTail), isEmpty);
    });
  });

  group('书面语高频词', () {
    test('正例：「然而」出现在口语流里', () {
      final hits = AiFlavorLinter.lint('然而我觉得没什么。');
      final hit =
          hits.firstWhere((h) => h.rule == AiFlavorLinter.ruleWrittenWord);
      expect(hit.evidence, contains('然而'));
    });

    test('正例：「因此」「此外」同样命中', () {
      expect(AiFlavorLinter.lint('因此你别急。').map((h) => h.rule),
          contains(AiFlavorLinter.ruleWrittenWord));
      expect(AiFlavorLinter.lint('此外没什么了。').map((h) => h.rule),
          contains(AiFlavorLinter.ruleWrittenWord));
    });

    test('反例：口语连接词不命中', () {
      expect(AiFlavorLinter.lint('不过我觉得没什么。')
          .where((h) => h.rule == AiFlavorLinter.ruleWrittenWord), isEmpty);
      expect(AiFlavorLinter.lint('所以你别急。')
          .where((h) => h.rule == AiFlavorLinter.ruleWrittenWord), isEmpty);
    });
  });

  group('「不是…而是…」句式', () {
    test('正例：跨逗号的完整句式', () {
      final hits = AiFlavorLinter.lint('不是我不想帮，而是这个忙我帮不了。');
      final hit = hits.firstWhere((h) => h.rule == AiFlavorLinter.ruleNotBut);
      expect(hit.evidence, contains('不是'));
      expect(hit.evidence, contains('而是'));
    });

    test('反例：只有「不是」没有「而是」', () {
      expect(AiFlavorLinter.lint('我不是不想帮你。')
          .where((h) => h.rule == AiFlavorLinter.ruleNotBut), isEmpty);
    });
  });

  group('句长方差过小（整组）', () {
    test('正例：三条候选几乎一样长且都不短', () {
      final hits = AiFlavorLinter.lintGroup([
        '我今天想在家里好好休息一下',
        '我明天想在家里好好休息一下',
        '我后天想在家里好好休息一下',
      ]);
      expect(hits, hasLength(3));
      for (final h in hits) {
        expect(h.map((x) => x.rule),
            contains(AiFlavorLinter.ruleUniformLength));
      }
      final hit =
          hits.first.firstWhere((x) => x.rule == AiFlavorLinter.ruleUniformLength);
      expect(hit.evidence, contains('13/13/13'));
    });

    test('反例：长短参差不命中', () {
      final hits = AiFlavorLinter.lintGroup([
        '我今天想在家里好好休息一下',
        '嗯',
        '今天实在是太累了，我什么都不想干，就想躺着',
      ]);
      expect(
        hits.every((h) =>
            h.every((x) => x.rule != AiFlavorLinter.ruleUniformLength)),
        isTrue,
      );
    });

    test('反例：含短回复的组不命中（短回复本来就该差不多长）', () {
      final hits = AiFlavorLinter.lintGroup(['好的', '行', '知道了']);
      expect(
        hits.every((h) =>
            h.every((x) => x.rule != AiFlavorLinter.ruleUniformLength)),
        isTrue,
      );
    });
  });

  group('每条都以问号结尾（整组）', () {
    test('正例：整组清一色问号', () {
      final hits = AiFlavorLinter.lintGroup(['你吃饭了吗？', '你要出门吗？', '作业写完了吗？']);
      for (final h in hits) {
        expect(h.map((x) => x.rule), contains(AiFlavorLinter.ruleAllQuestion));
      }
    });

    test('反例：有一条不是问号就不算', () {
      final hits = AiFlavorLinter.lintGroup(['你吃饭了吗？', '你要出门吗？', '作业写完了。']);
      expect(
        hits
            .every((h) => h.every((x) => x.rule != AiFlavorLinter.ruleAllQuestion)),
        isTrue,
      );
    });
  });

  group('emoji / 语气词滥用', () {
    test('正例：emoji 堆叠', () {
      final hits = AiFlavorLinter.lint('哈哈哈哈太好了😂😂😂');
      final hit =
          hits.firstWhere((h) => h.rule == AiFlavorLinter.ruleEmojiAbuse);
      expect(hit.evidence, contains('emoji'));
      expect(hit.evidence, contains('3 次'));
    });

    test('正例：语气词滥用', () {
      final hits = AiFlavorLinter.lint('好呀，来啦，等你哦。');
      final hit =
          hits.firstWhere((h) => h.rule == AiFlavorLinter.ruleEmojiAbuse);
      expect(hit.evidence, contains('呀啦哦'));
      // 「好呀，来啦」是两个两字短句，加「等你哦」凑不成三个同构——这条只算滥用。
      expect(hits.where((h) => h.rule == AiFlavorLinter.ruleParallelStack),
          isEmpty);
    });

    test('反例：单个 emoji 与正常语气不命中', () {
      expect(AiFlavorLinter.lint('太好了😂')
          .where((h) => h.rule == AiFlavorLinter.ruleEmojiAbuse), isEmpty);
      expect(AiFlavorLinter.lint('好呀，那就这样。')
          .where((h) => h.rule == AiFlavorLinter.ruleEmojiAbuse), isEmpty);
    });

    test('反例：「哈哈哈哈」是真人笑，不算滥用', () {
      expect(AiFlavorLinter.lint('哈哈哈哈笑死我了')
          .where((h) => h.rule == AiFlavorLinter.ruleEmojiAbuse), isEmpty);
    });
  });

  group('lintGroup / refineInstruction', () {
    test('整组特征挂在每一条上，单条特征只挂自己', () {
      final hits = AiFlavorLinter.lintGroup([
        '然而我还是要说，不是你不好，而是我们都需要时间。总之别多想了。',
        '今天状态不太好。',
        '先睡吧。',
      ]);
      expect(hits, hasLength(3));
      // 单条特征只落在第一条，顺序固定：tail → written → notBut。
      expect(hits[0].map((h) => h.rule),
          ['summary_tail', 'written_word', 'not_but']);
      // 这一组没有整组特征（长度 31/8/8 参差、无整组问号），其余两条零命中。
      expect(hits[1], isEmpty);
      expect(hits[2], isEmpty);
    });

    test('整组特征命中时每条都带一份', () {
      final hits = AiFlavorLinter.lintGroup(['你吃饭了吗？', '你要出门吗？', '作业写完了吗？']);
      for (final h in hits) {
        expect(h.map((x) => x.rule), contains(AiFlavorLinter.ruleAllQuestion));
      }
    });

    test('重写指令是命中规则的人话描述', () {
      final hits = AiFlavorLinter.lint(
          '然而我还是要说，不是你不好，而是我们都需要时间。总之别多想了。');
      final instruction = AiFlavorLinter.refineInstruction(hits);
      expect(instruction, contains('AI 腔'));
      expect(instruction, contains('总结腔'));
      expect(instruction, contains('书面词'));
      expect(instruction, contains('不是…而是…'));
      // 门槛常量：命中 <2 不进重写。
      expect(AiFlavorLinter.rewriteThreshold, 2);
    });
  });

  // ------------------------------------------------------- draftAndRank 挂接

  group('draftAndRank 的 AI 腔挂接', () {
    late LintStubServer server;
    late JevClient client;

    setUp(() async {
      server = LintStubServer();
      await server.start();
      final config = JevConfig()
        ..judgeBaseUrl = 'http://127.0.0.1:${server.port}'
        ..judgeKey = 'test-key'
        ..judgeModel = 'judge-model'
        ..judgeProtocol = 'chat'
        ..replyBaseUrl = 'http://127.0.0.1:${server.port}'
        ..replyKey = 'test-key'
        ..replyModel = 'reply-model';
      client = JevClient(config);
    });

    tearDown(() async {
      await server.close();
    });

    const snapshot = ChatSnapshot(
      title: '测试会话',
      messages: [
        Msg(side: 'other', text: '最近好累'),
        Msg(side: 'me', text: '多注意休息'),
      ],
    );

    test('默认开关开启：命中 ≥2 的候选自动改写，概率与策略原位保留', () async {
      server.draftContent = flavoredDraftReply;
      server.refineContent = refineOkReply;

      final ranked = await client.draftAndRank(snapshot, '朋友');

      // 起草 1 + 排序 1 + 重写 1（只有第一条过门槛）。
      expect(server.draftCalls, 1);
      expect(server.rankCalls, 1);
      expect(server.refineCalls, 1);
      expect(server.totalRequests, 3);

      expect(ranked, hasLength(3));
      // 原位替换：概率、策略、排序标记全部保留，不重排。
      expect(ranked[0].text, '这事不怪你，咱们都需要点时间，别想太多。');
      expect(ranked[0].prob, closeTo(0.5, 1e-9));
      expect(ranked[0].strategy, 'safe');
      expect(ranked[0].ranked, isTrue);
      expect(ranked[1].text, '周末出来走走吧。');
      expect(ranked[1].prob, closeTo(0.3, 1e-9));
      expect(ranked[2].text, '想吃火锅了吗？');
      expect(ranked[2].prob, closeTo(0.2, 1e-9));

      // 指令 = 命中规则的人话描述，原文随「原回复：」进提示词。
      expect(server.lastRefineUser, contains('改写要求：'));
      expect(server.lastRefineUser, contains('AI 腔'));
      expect(server.lastRefineUser, contains('总结腔'));
      expect(server.lastRefineUser, contains('书面词'));
      expect(server.lastRefineUser, contains('不是…而是…'));
      expect(server.lastRefineUser,
          contains('原回复：然而我还是要说，不是你不好，而是我们都需要时间。总之别多想了。'));
    });

    test('重写失败：保留原文并降权 0.1，其余候选不受影响', () async {
      server.draftContent = flavoredDraftReply;
      // 空重写答复让 refine 解析为空 → 视为失败。
      server.refineContent = '';

      final ranked = await client.draftAndRank(snapshot, '朋友');

      expect(server.refineCalls, 1);
      expect(ranked[0].text, '然而我还是要说，不是你不好，而是我们都需要时间。总之别多想了。');
      expect(ranked[0].prob, closeTo(0.4, 1e-9)); // 0.5 - 0.1
      expect(ranked[0].strategy, 'safe');
      expect(ranked[1].prob, closeTo(0.3, 1e-9));
      expect(ranked[2].prob, closeTo(0.2, 1e-9));
    });

    test('开关关闭：不调用 refine，候选原样', () async {
      server.draftContent = flavoredDraftReply;

      final ranked = await client.draftAndRank(snapshot, '朋友',
          aiFlavorLintEnabled: false);

      expect(server.refineCalls, 0);
      expect(server.totalRequests, 2);
      expect(ranked[0].text, '然而我还是要说，不是你不好，而是我们都需要时间。总之别多想了。');
      expect(ranked[0].prob, closeTo(0.5, 1e-9));
    });

    test('命中不足 2 条：不重写', () async {
      server.draftContent = '['
          '{"strategy":"safe","text":"然而今天有点累。"},'
          '{"strategy":"forward","text":"总之先睡觉。"},'
          '{"strategy":"angle","text":"周末去吧。"}'
          ']';

      final ranked = await client.draftAndRank(snapshot, '朋友');

      expect(server.refineCalls, 0);
      expect(server.totalRequests, 2);
      expect(ranked.map((r) => r.text).toList(),
          ['然而今天有点累。', '总之先睡觉。', '周末去吧。']);
      expect(ranked[0].prob, closeTo(0.5, 1e-9));
    });

    test('开关是缓存键的一部分：翻转开关必须重新出网', () async {
      server.draftContent = flavoredDraftReply;
      server.refineContent = refineOkReply;

      await client.draftAndRank(snapshot, '朋友'); // 默认开：起草+排序+重写
      await client.draftAndRank(snapshot, '朋友',
          aiFlavorLintEnabled: false); // 关：新键，重新起草
      await client.draftAndRank(snapshot, '朋友'); // 开：命中第一次的缓存

      expect(server.draftCalls, 2);
      expect(server.refineCalls, 1);
      expect(server.totalRequests, 5);
    });
  });

  // ------------------------------------------------------------ A1 兼容锁

  group('A1 正向示范开关（reply_prompt）', () {
    test('兼容锁：默认与显式关闭逐字节一致', () {
      expect(
        ReplyPrompt.systemPrompt(3),
        ReplyPrompt.systemPrompt(3, usePositiveExamples: false),
      );
      expect(
        ReplyPrompt.systemPrompt(3, registerOpen: true),
        ReplyPrompt.systemPrompt(3, registerOpen: true,
            usePositiveExamples: false),
      );
      expect(
        ReplyPrompt.systemPrompt(1),
        ReplyPrompt.systemPrompt(1, usePositiveExamples: false),
      );
      final card = PersonaCard.parse('');
      expect(
        ReplyPrompt.draftSystemPrompt(3, 'follow', 'standard', card),
        ReplyPrompt.draftSystemPrompt(3, 'follow', 'standard', card,
            usePositiveExamples: false),
      );
    });

    test('兼容锁：默认输出里两条禁令的完整原文逐字在场', () {
      final sys = ReplyPrompt.systemPrompt(3);
      expect(
        sys,
        contains('硬性禁止（任何情况下都有效）：不要编造没发生过的事，不要提对方没提过的人和计划，'
            '不要写涉及未成年人的性或亲密内容，不要写非自愿、强迫、威胁或会真实伤害到人的内容，'
            '不要冒充他人，不要替用户许诺、转账或点链接。'),
      );
      expect(
        sys,
        contains('另外禁止：不要角色扮演式台词，不要用「主人」「爸爸」「殿下」这类主仆或亲属式称呼，'
            '不要卑微求饶、自我贬低或过度道歉。'),
      );
    });

    test('开关开启：语域禁令改为正向示范 + 反例对照', () {
      final on = ReplyPrompt.systemPrompt(3, usePositiveExamples: true);
      expect(on, isNot(contains('另外禁止：')));
      expect(on, contains('正向示范'));
      expect(on, contains('反例对照'));
      // 反例对照仍然点名原禁令的类别：改写不是放开。
      expect(on, contains('角色扮演式台词'));
      expect(on, contains('「主人」'));
      expect(on, contains('卑微求饶'));
    });

    test('开关开启：安全红线一条不少（G6：safetyBans 永远在上）', () {
      final on = ReplyPrompt.systemPrompt(3, usePositiveExamples: true);
      expect(on, contains('硬性禁止（任何情况下都有效）'));
      for (final banned in const [
        '编造没发生过的事',
        '提对方没提过的人和计划',
        '涉及未成年人的性或亲密内容',
        '非自愿、强迫、威胁或会真实伤害到人的内容',
        '冒充他人',
        '替用户许诺、转账或点链接',
      ]) {
        expect(on, contains(banned), reason: '反例对照缺了：$banned');
      }
    });

    test('开关开启：语域放开的分支不受开关影响', () {
      final open = ReplyPrompt.systemPrompt(
        3,
        registerOpen: true,
        usePositiveExamples: true,
      );
      expect(open, contains('语域已按人设卡放开'));
      expect(open, isNot(contains('不要角色扮演式台词')));
      expect(open, contains('硬性禁止（任何情况下都有效）'));
    });

    test('draftSystemPrompt 透传开关', () {
      final card = PersonaCard.parse('');
      final off = ReplyPrompt.draftSystemPrompt(3, 'follow', 'standard', card);
      final on = ReplyPrompt.draftSystemPrompt(3, 'follow', 'standard', card,
          usePositiveExamples: true);
      expect(on, isNot(off));
      expect(off, contains('另外禁止：'));
      expect(on, contains('正向示范'));
    });
  });
}

/// OpenAI 兼容的桩服务器：按请求体分诊起草 / 排序 / 重写，并各自计数。
/// 分诊判据与 jev_client_test.dart 同源：带「=== QUESTIONS ===」的是判断协议
/// （其中 id: best_reply 是排序），带「改写要求：」的是 refine，其余是起草。
class LintStubServer {
  int draftCalls = 0;
  int rankCalls = 0;
  int refineCalls = 0;
  int totalRequests = 0;

  String lastRefineUser = '';

  /// 起草答复，每个用例自己设置。
  String draftContent = '[]';

  /// 重写答复：空串会让 refine 解析为空 → 视为重写失败。
  String refineContent = '';

  HttpServer? _server;

  int get port => _server!.port;

  Future<void> start() async {
    final bound = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = bound;
    bound.listen(_handle);
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final raw = await utf8.decoder.bind(req).join();
      totalRequests++;
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      final user = (messages.last as Map<String, dynamic>)['content'] as String;

      String content;
      if (user.contains('=== QUESTIONS ===')) {
        rankCalls++;
        content = rankReply;
      } else if (user.contains('改写要求：')) {
        refineCalls++;
        lastRefineUser = user;
        content = refineContent;
      } else {
        draftCalls++;
        content = draftContent;
      }

      final res = req.response;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': content},
          },
        ],
      }));
      await res.close();
    } catch (_) {
      // 测试收尾强制关服时迟到的读写失败不算数。
    }
  }
}

/// 排序答复：reply_a（0.5）> reply_b（0.3）> reply_c（0.2），顺序保持起草序。
const String rankReply = '''
{
  "best_reply": {"choice": "reply_a", "confidence": 0.9,
                 "probabilities": {"reply_a": 0.5, "reply_b": 0.3, "reply_c": 0.2}}
}
''';

/// 起草答复：第一条身兼三个特征（书面词 + 不是而是 + 总结尾句），后两条干净
/// 且长短参差——整组特征不触发，只有第一条过 ≥2 的重写门槛。
const String flavoredDraftReply = '['
    '{"strategy":"safe","text":"然而我还是要说，不是你不好，而是我们都需要时间。总之别多想了。"},'
    '{"strategy":"forward","text":"周末出来走走吧。"},'
    '{"strategy":"angle","text":"想吃火锅了吗？"}'
    ']';

/// 重写答复：refine 契约的单对象 JSON 数组。
const String refineOkReply =
    '[{"strategy":"safe","text":"这事不怪你，咱们都需要点时间，别想太多。"}]';
