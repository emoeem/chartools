import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// kimi-review #20：复查驳回候选的重写并行性钉子。
///
/// _applyReview / _applyFlavorLint 原先对被拒候选逐条 await 重写——3 条全拒
/// = 3 次串行润色往返。改成 Future.wait 并行后，这里用一台按请求体分诊的
/// 桩服务器同时扮演起草 / 排序 / 复查 / 润色四条路（复查、润色 base 留空，
/// 按回退规则都落回复路由 = 同一台服务器），给三条重写各配不同延迟
/// （乙 60ms 最先完成、丙 120ms、甲 180ms 最后完成），钉两件事：
///
///  1. **并行性**：三条重写请求真的同时在线。记请求到达顺序与到达时的
///     在途数——串行实现下后一条到达时前者必已收线，在途数恒为 0；
///  2. **位置序**：Future.wait 按输入顺序回收结果，替换映射不受完成先后
///     影响——按完成顺序收集会把最快的乙错配到第 1 条候选上。
void main() {
  late StubServer server;
  late JevClient client;

  setUp(() async {
    // 不期待重试；真有意外失败时别让退避拖满 1.5 s。
    HttpJson.retryBackoffMs = 1;
    server = StubServer();
    await server.start();
    final config = JevConfig()
      ..judgeBaseUrl = 'http://127.0.0.1:${server.port}'
      ..judgeKey = 'test-key'
      ..judgeModel = 'judge-model'
      ..judgeProtocol = 'chat'
      ..replyBaseUrl = 'http://127.0.0.1:${server.port}'
      ..replyKey = 'test-key'
      ..replyModel = 'reply-model'
      ..reviewEnabled = true;
    client = JevClient(config);
  });

  tearDown(() async {
    HttpJson.retryBackoffMs = 500;
    await server.close();
  });

  final snapshot = ChatSnapshot(
    title: '测试会话',
    messages: const [
      Msg(side: 'other', text: '这周末你有空吗？'),
      Msg(side: 'me', text: '我看看安排'),
    ],
  );

  test('复查驳回三条：重写并行出网、按位置回填（kimi-review #20）', () async {
    // 只测复查链路：linter 关掉，免得重写后的文本再牵扯一层无关行为。
    final ranked = await client.draftAndRank(
      snapshot,
      '女朋友',
      aiFlavorLintEnabled: false,
    );

    // 一轮起草 + 一次排序 + 一次复查 + 三次重写，全部落在这台服务器上。
    expect(server.draftCalls, 1);
    expect(server.rankCalls, 1);
    expect(server.reviewCalls, 1);
    expect(server.rewriteCalls, 3);

    // 并行性（记请求到达顺序与到达时的在途数）：三条重写都必须到达，
    // 顺序本身不承诺；并行实现下至少两条同时在线，串行实现这里恒为 0。
    expect(server.rewriteArrivalOrder, hasLength(3));
    expect(
      server.rewriteArrivalOrder.toSet(),
      unorderedEquals(['候选甲', '候选乙', '候选丙']),
    );
    final overlapped =
        server.rewriteOpenAtArrival.where((open) => open >= 1).length;
    expect(
      overlapped,
      greaterThanOrEqualTo(2),
      reason: '并行实现下至少两条重写同时在线；逐条 await 的串行实现恒为 0',
    );

    // 位置序：完成顺序是 乙(60ms) → 丙(120ms) → 甲(180ms)，回填仍按候选
    // 位置——按完成顺序收集会把最快的乙错配到第 1 条。
    expect(ranked, hasLength(3));
    expect(ranked[0].text, '甲已重写');
    expect(ranked[1].text, '乙已重写');
    expect(ranked[2].text, '丙已重写');
    // 概率与排序标记沿用排序结果，复查备注按槽位跟 verdicts 走。
    expect(ranked[0].prob, closeTo(0.9, 1e-9));
    expect(ranked[1].prob, closeTo(0.5, 1e-9));
    expect(ranked[2].prob, closeTo(0.1, 1e-9));
    expect(ranked.every((r) => r.ranked), isTrue);
    expect(ranked[0].reviewNote, '理由一');
    expect(ranked[1].reviewNote, '理由二');
    expect(ranked[2].reviewNote, '理由三');
  });
}

/// OpenAI 兼容的桩服务器：一个地址同时服务起草 / 排序 / 复查 / 重写。
///
/// 分诊按 system 提示词打头（改写助手 / 核验助手各自独占一句话），再按
/// user 的题集标记认排序，剩下的都是起草。重写请求按 user 里的
/// 「原回复：候选X…」识别它改的是哪条候选，配不同延迟与答复。
class StubServer {
  int draftCalls = 0;
  int rankCalls = 0;
  int reviewCalls = 0;
  int rewriteCalls = 0;

  /// 重写请求的到达顺序（按其改写的候选原文打标，顺序不承诺）与到达时刻
  /// 的在途请求数。串行实现在途数恒为 0；并行实现至少两条重叠。
  final List<String> rewriteArrivalOrder = [];
  final List<int> rewriteOpenAtArrival = [];

  int _open = 0;
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
    // 在途计数在进入处理器时同步完成（读请求体之前）：并行请求的到达重叠
    // 在这里观测，不因读体 await 的交错而漏记。
    _open++;
    final openAtArrival = _open - 1;
    try {
      final raw = await utf8.decoder.bind(req).join();
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      final system =
          (messages[0] as Map<String, dynamic>)['content'] as String;
      final user = (messages[1] as Map<String, dynamic>)['content'] as String;

      String content;
      if (system.contains('改写助手')) {
        rewriteCalls++;
        rewriteOpenAtArrival.add(openAtArrival);
        rewriteArrivalOrder.add(_rewriteTag(user));
        content = _rewriteContent(user);
        // 慢模型：应答前拖住连接，制造可观测的重叠窗口。
        await Future<void>.delayed(_rewriteDelay(user));
      } else if (system.contains('核验助手')) {
        reviewCalls++;
        content = reviewReply;
      } else if (user.contains('=== QUESTIONS ===')) {
        rankCalls++;
        content = rankReply;
      } else {
        draftCalls++;
        content = draftReply;
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
    } finally {
      _open--;
    }
  }

  String _rewriteTag(String user) {
    if (user.contains('候选甲')) return '候选甲';
    if (user.contains('候选乙')) return '候选乙';
    if (user.contains('候选丙')) return '候选丙';
    return '未知';
  }

  /// 三条重写各配不同延迟：完成顺序（乙→丙→甲）刻意与候选顺序（甲→乙→丙）
  /// 不同，按完成顺序收集结果必然错配，文本断言会大声失败。
  Duration _rewriteDelay(String user) => switch (_rewriteTag(user)) {
        '候选甲' => const Duration(milliseconds: 180),
        '候选乙' => const Duration(milliseconds: 60),
        '候选丙' => const Duration(milliseconds: 120),
        _ => Duration.zero,
      };

  String _rewriteContent(String user) => switch (_rewriteTag(user)) {
        '候选甲' => '[{"strategy":"safe","text":"甲已重写"}]',
        '候选乙' => '[{"strategy":"safe","text":"乙已重写"}]',
        '候选丙' => '[{"strategy":"safe","text":"丙已重写"}]',
        _ => '[{"strategy":"safe","text":"未知重写"}]',
      };
}

/// 起草答复：三条候选各带「候选X」标记，重写请求按它识别自己改的是哪条。
const String draftReply = '['
    '{"strategy":"safe","text":"候选甲的原文回复"},'
    '{"strategy":"forward","text":"候选乙的原文回复"},'
    '{"strategy":"angle","text":"候选丙的原文回复"}'
    ']';

/// 排序答复：reply_a（0.9）> reply_b（0.5）> reply_c（0.1），顺序保持起草序。
const String rankReply = '''
{
  "best_reply": {"choice": "reply_a", "confidence": 0.9,
                 "probabilities": {"reply_a": 0.9, "reply_b": 0.5, "reply_c": 0.1}}
}
''';

/// 复查答复：三条全部驳回，各带一句理由——触发三次重写。
const String reviewReply = '''
{
  "verdicts": [
    {"index": 1, "keep": false, "reason": "理由一"},
    {"index": 2, "keep": false, "reason": "理由二"},
    {"index": 3, "keep": false, "reason": "理由三"}
  ]
}
''';
