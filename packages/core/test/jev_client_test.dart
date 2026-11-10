import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// JevClient 门面端到端 —— 对照旧仓库 `jev/HttpJsonTest.kt` 与
/// `ChatJudgeTest.kt` 的构造方式：同一个本地 server 同时扮演判断路由与
/// 回复路由（JevConfig 指向它，judgeProtocol='chat'）。
///
/// chat 协议下判断、排序与起草全部落在同一个 `/chat/completions` 上，
/// server 按请求体分诊并计数：user 提示词带「=== QUESTIONS ===」的是判断
/// 协议的提示词，其中带「id: best_reply」的是排序，其余是起草。
/// 「第二次 judge 不再打 server」这类缓存行为只有打真服务器才测得出。
void main() {
  late StubServer server;
  late JevClient client;

  setUp(() async {
    server = StubServer();
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

  final snapshot = ChatSnapshot(
    title: '测试会话',
    messages: const [
      Msg(side: 'other', text: '你昨天又忘了？'),
      Msg(side: 'me', text: '对不起，是我不好'),
    ],
  );

  Future<Object> failure(Future<Object?> Function() run) async {
    try {
      await run();
    } catch (e) {
      return e;
    }
    fail('预期调用失败，但它成功了');
  }

  test('judge：chat 协议的答复归一化成 Analysis 的字段', () async {
    final a = await client.judge(snapshot, '女朋友');

    expect(a.error, isNull);
    expect(a.trueIntent?.choice, 'confirm_you_care');
    expect(a.trueIntent?.confidence, closeTo(0.7, 1e-9));
    expect(a.trueIntent?.probabilities['vent_anger'], closeTo(0.2, 1e-9));
    expect(a.trueIntent?.probabilities['casual_chat'], closeTo(0.1, 1e-9));
    // 第 4 级（0 起）：图例给出 0..9，遮罩层据此显示「4/9」。
    expect(a.dangerLevel?.score, 4.0);
    expect(a.dangerLevel?.maxLevel, 9);
    expect(a.dangerLevel?.confidence, closeTo(0.6, 1e-9));
    expect(a.sheNeeds?.choice, 'care');
    expect(a.sheNeeds?.confidence, closeTo(0.55, 1e-9));
    // 布尔 false 归一化成 0.0；字符串 "0.15" 归一化成 0.15。
    expect(a.shouldReplyNow, 0.0);
    expect(a.bestAction?.choice, 'apologize');
    expect(a.tensionResolved, closeTo(0.15, 1e-9));
    expect(a.literalQuestion, closeTo(0.2, 1e-9));
    expect(a.rankedReplies, isEmpty);

    // 判断请求确实按 chat 协议出网：Bearer 密钥、判断模型、json_object。
    expect(server.lastPath, '/chat/completions');
    expect(server.lastAuth, 'Bearer test-key');
    expect(server.lastJudgeModel, 'judge-model');
    expect(server.lastJudgeHasResponseFormat, isTrue);
    expect(server.judgeCalls, 1);
    expect(server.draftCalls, 0);
    expect(server.rankCalls, 0);
  });

  test('判断缓存：同一会话的第二次 judge 不再打服务器', () async {
    // 判断是一轮里最慢的调用（推理提示词），同一会话重新开一轮会重判——
    // 缓存就是为这条路径存在的。用计数器断言「命中」，比看返回值更硬。
    final first = await client.judge(snapshot, '女朋友');
    expect(server.judgeCalls, 1);

    final again = await client.judge(snapshot, '女朋友');

    expect(server.judgeCalls, 1);
    expect(again.error, isNull);
    expect(again.trueIntent?.choice, first.trueIntent?.choice);
    expect(again.dangerLevel?.score, first.dangerLevel?.score);
  });

  test('draftAndRank：起草 3 条，再用 best_reply 概率排序', () async {
    final ranked = await client.draftAndRank(snapshot, '女朋友');

    // 一轮起草 + 一次排序；七题判断不在这条链路里。
    expect(server.draftCalls, 1);
    expect(server.rankCalls, 1);
    expect(server.judgeCalls, 0);
    expect(server.totalRequests, 2);

    expect(ranked, hasLength(3));
    // 排序概率 reply_b 0.7 > reply_a 0.2 > reply_c 0.1 → B、A、C。
    expect(ranked[0].text, '我想你了，这周末见一面？');
    expect(ranked[0].prob, closeTo(0.7, 1e-9));
    expect(ranked[1].text, '先接住她，别急着解释');
    expect(ranked[1].prob, closeTo(0.2, 1e-9));
    expect(ranked[2].text, '换我主动汇报行程，如何？');
    expect(ranked[2].prob, closeTo(0.1, 1e-9));
    expect(ranked.every((r) => r.ranked), isTrue);
    // strategy 沿起草顺序配对（对照 Kotlin JevClient.kt 的 mapIndexed）。
    expect(
        ranked.map((r) => r.strategy).toList(), ['safe', 'forward', 'angle']);

    // 起草请求带的是回复模型与整段对话窗口。
    expect(server.lastDraftModel, 'reply-model');
    expect(server.lastDraftUser, contains('对方：你昨天又忘了？'));
    expect(server.lastDraftUser, contains('我：对不起，是我不好'));
    expect(server.lastDraftUser, contains('请给出 3 条候选回复。'));
  });

  test('SafetyBlockedException：违法词直接拦下，一个请求都不出网', () async {
    final bad = ChatSnapshot(
      title: '测试会话',
      messages: const [
        Msg(side: 'other', text: '我们下药吧'),
        Msg(side: 'me', text: '不行'),
      ],
    );

    final e = await failure(() => client.draftAndRank(bad, '女朋友'));

    expect(e, isA<SafetyBlockedException>());
    // 文案原样给用户：「没有候选」不说原因就分不清是网络故障还是拒绝。
    expect((e as SafetyBlockedException).message, contains('涉嫌违法'));
    // 预检在任何 API 调用之前：这条消息没出过这台机器。
    expect(server.totalRequests, 0);
  });

  test('判断缓存：第 51 条才淘汰最旧的一条（对照 Kotlin CACHE_SIZE=50）', () async {
    // 旧仓库 judgeCache 的 LinkedHashMap(16, 0.75f, true) 里 16 只是初始
    // 容量，removeEldestEntry 判据是 size > CACHE_SIZE = 50。这里用计数器
    // 钉住同一上限：51 个不同会话全部出网，此后最旧的不再命中。
    final snaps = [
      for (var i = 0; i < 51; i++)
        ChatSnapshot(
          title: '会话 $i',
          messages: [Msg(side: 'other', text: '第 $i 条消息')],
        ),
    ];
    for (final s in snaps) {
      await client.judge(s, '女朋友');
    }
    expect(server.judgeCalls, 51);

    // 第 1 个会话已被挤出：重判必须重新出网（第 52 次调用）。
    await client.judge(snaps[0], '女朋友');
    expect(server.judgeCalls, 52);

    // 最近用过的第 51 个会话还在缓存里：不再出网。
    await client.judge(snaps[50], '女朋友');
    expect(server.judgeCalls, 52);
  });
}

/// OpenAI 兼容的桩服务器：一个地址同时服务判断与起草，按请求体分诊计数。
class StubServer {
  int judgeCalls = 0;
  int rankCalls = 0;
  int draftCalls = 0;
  int totalRequests = 0;

  String lastAuth = '';
  String lastPath = '';
  String lastJudgeModel = '';
  bool lastJudgeHasResponseFormat = false;
  String lastDraftModel = '';
  String lastDraftUser = '';

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
      lastAuth = req.headers.value('authorization') ?? '';
      lastPath = req.uri.path;
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      final last = messages.last as Map<String, dynamic>;
      final user = last['content'] as String;
      final model = body['model'] as String? ?? '';

      String content;
      if (user.contains('=== QUESTIONS ===')) {
        lastJudgeModel = model;
        lastJudgeHasResponseFormat =
            body['response_format'] is Map<String, dynamic>;
        if (user.contains('id: best_reply')) {
          rankCalls++;
          content = rankReply;
        } else {
          judgeCalls++;
          content = judgeReply;
        }
      } else {
        draftCalls++;
        lastDraftModel = model;
        lastDraftUser = user;
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
    }
  }
}

/// 七题判断的答复：带 answers 包装，字段形状仿 DeepSeek 的实际答复
/// （布尔、字符串、带 probabilities 的选项各来一种）。
const String judgeReply = '''
{
  "answers": {
    "literal_question": {"noul": 0.2, "confidence": 0.8},
    "true_intent": {"choice": "confirm_you_care", "confidence": 0.7,
                    "probabilities": {"confirm_you_care": 0.7, "vent_anger": 0.2, "casual_chat": 0.1}},
    "danger_level": {"score": 4, "confidence": 0.6},
    "should_reply_now": {"noul": false, "confidence": 0.9},
    "she_needs": {"choice": "care", "confidence": 0.55,
                  "probabilities": {"care": 0.55, "apology": 0.45}},
    "best_action": {"choice": "apologize", "confidence": 0.6,
                    "probabilities": {"apologize": 1.0}},
    "tension_resolved": {"noul": "0.15", "confidence": 0.5}
  }
}
''';

/// 起草答复：ReplyPrompt 契约的 JSON 数组，strategy 三条各一。
const String draftReply = '['
    '{"strategy":"safe","text":"先接住她，别急着解释"},'
    '{"strategy":"forward","text":"我想你了，这周末见一面？"},'
    '{"strategy":"angle","text":"换我主动汇报行程，如何？"}'
    ']';

/// 排序答复：best_reply 题按 choice + probabilities 作答，
/// reply_b（0.7）胜出。
const String rankReply = '''
{
  "best_reply": {"choice": "reply_b", "confidence": 0.9,
                 "probabilities": {"reply_a": 0.2, "reply_b": 0.7, "reply_c": 0.1}}
}
''';
