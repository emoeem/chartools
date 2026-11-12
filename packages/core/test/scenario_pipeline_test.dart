import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 场景接线的管线级钉子（fix(#11 P0-N)）。
///
/// reply_prompt_test 已在提示词装配层钳住「chat_copilot 逐字节一致 / 附加段
/// 位置」，本文件把同一件事钉在**真正的 HTTP 层**与缓存上——只测装配层堵不住
/// 「调用方忘了把场景参数传到请求里」这类断线：
///
///  - `ReplyClient.draft` / `draftStream`：无场景与 chat_copilot 出网字节逐字
///    相同（兼容锁）；非默认场景的附加段真的出现在出网的双提示词里；
///  - `JevClient.draftAndRank`：场景进缓存键——同场景命中、换场景作废、
///    无场景与 chat_copilot 是两个键（后者提示词相同，只是各占一格缓存）。
void main() {
  late StubServer server;

  setUp(() async {
    server = StubServer();
    await server.start();
  });

  tearDown(() async {
    await server.close();
  });

  JevConfig configFor(StubServer stub) => JevConfig()
    ..judgeBaseUrl = 'http://127.0.0.1:${stub.port}'
    ..judgeKey = 'test-key'
    ..judgeModel = 'judge-model'
    ..judgeProtocol = 'chat'
    ..replyBaseUrl = 'http://127.0.0.1:${stub.port}'
    ..replyKey = 'test-key'
    ..replyModel = 'reply-model';

  const snapshot = ChatSnapshot(
    title: '测试会话',
    messages: [
      Msg(side: 'other', text: '周末有空吗'),
      Msg(side: 'me', text: '在加班，周五之前都悬'),
    ],
  );

  final support = Scenarios.byId('support_agent');
  final learning = Scenarios.byId('language_learning');

  setUpAll(() {
    expect(support, isNotNull);
    expect(learning, isNotNull);
  });

  group('ReplyClient.draft（HTTP 层）', () {
    late ReplyClient client;
    late StubServer stub;

    setUp(() async {
      stub = StubServer();
      await stub.start();
      client = ReplyClient(configFor(stub));
    });

    tearDown(() async {
      await stub.close();
    });

    Future<void> draft({ScenarioTemplate? scenario}) => client.draft(
          snapshot,
          '朋友',
          scenario: scenario,
        );

    test('无场景与 chat_copilot 出网的双提示词逐字节一致（兼容锁）', () async {
      await draft();
      final plainSystem = stub.lastDraftSystem;
      final plainUser = stub.lastDraftUser;

      await draft(scenario: Scenarios.chatCopilot);

      expect(stub.lastDraftSystem, plainSystem);
      expect(stub.lastDraftUser, plainUser);
    });

    test('非默认场景：system 附加段逐字追加在末尾，user 附加段插在候选条数行之前', () async {
      await draft();
      final plainSystem = stub.lastDraftSystem;
      final plainUser = stub.lastDraftUser;

      await draft(scenario: support);
      final s = support!;
      const ask = '请给出 3 条候选回复。';
      // system = 无场景的 system 原样 + 附加段（追加在末尾，别处不动）。
      expect(stub.lastDraftSystem, plainSystem + s.systemAddendum);
      // user = 无场景的 tail 之前原样 + 附加段 + 同一个尾行（ReplyPrompt 的
      // 既有插入点）。
      final head = plainUser.substring(0, plainUser.lastIndexOf(ask));
      expect(stub.lastDraftUser, head + s.userAddendum + ask);
    });

    test('draftStream 与缓冲路径同源：场景附加段随流式请求出网', () async {
      final s = support!;
      final out = await client.draftStream(
        snapshot,
        '朋友',
        scenario: s,
        onVisible: (_) {},
      );

      expect(out, hasLength(2));
      expect(stub.draftCalls, 1);
      // 与缓冲 draft 的装配是同一个 _draftAsk：附加段必须出现在出网 system 里。
      expect(stub.lastDraftSystem, contains(s.systemAddendum));
      expect(stub.lastDraftUser, contains(s.userAddendum));
    });

    test('draftStream 无场景时与无场景缓冲请求逐字节一致', () async {
      await draft();
      final plainSystem = stub.lastDraftSystem;
      final plainUser = stub.lastDraftUser;

      await client.draftStream(snapshot, '朋友', onVisible: (_) {});

      expect(stub.lastDraftSystem, plainSystem);
      expect(stub.lastDraftUser, plainUser);
    });
  });

  group('JevClient.draftAndRank（缓存键含场景）', () {
    late JevClient client;

    setUp(() async {
      client = JevClient(configFor(server));
    });

    Future<List<RankedReply>> rank({ScenarioTemplate? scenario}) =>
        client.draftAndRank(snapshot, '朋友', scenario: scenario);

    test('场景随请求出网：非默认场景的附加段出现在起草提示词里', () async {
      final s = support!;
      await rank(scenario: s);

      expect(server.draftCalls, 1);
      expect(server.lastDraftSystem, contains(s.systemAddendum));
      expect(server.lastDraftUser, contains(s.userAddendum));
    });

    test('同场景同输入第二次命中缓存，不再打服务器', () async {
      await rank(scenario: support);
      expect(server.draftCalls, 1);
      expect(server.rankCalls, 1);

      await rank(scenario: support);

      expect(server.draftCalls, 1, reason: '同场景同输入必须命中回复缓存');
      expect(server.rankCalls, 1);
    });

    test('场景变了缓存必须作废：换一个场景就重新出网', () async {
      final s = support!;
      final l = learning!;
      await rank(scenario: s);
      await rank(scenario: s);
      expect(server.draftCalls, 1);

      await rank(scenario: l);

      // language_learning 的键与 support_agent 不同：缓存作废，重新起草+排序。
      expect(server.draftCalls, 2);
      expect(server.rankCalls, 2);
      // 出网的就是新场景的附加段，不是旧场景缓存的回放。
      expect(server.lastDraftSystem, contains(l.systemAddendum));
      expect(server.lastDraftSystem, isNot(contains(s.systemAddendum)));
    });

    test('无场景（null）与 chat_copilot 是两个键，互不命中', () async {
      await rank();
      expect(server.draftCalls, 1);
      await rank(scenario: Scenarios.chatCopilot);
      // 提示词逐字节相同（兼容锁），但键不同：各占一格缓存，都不串味。
      expect(server.draftCalls, 2);
      await rank();
      expect(server.draftCalls, 2, reason: '回到无场景：命中第一格缓存');
      await rank(scenario: Scenarios.chatCopilot);
      expect(server.draftCalls, 2, reason: '回到 chat_copilot：命中第二格缓存');
    });

    test('不传场景参数（缺省）与显式 null 同键，行为与接入前一致', () async {
      // 不写 scenario 参数（旧调用方的写法）。
      await client.draftAndRank(snapshot, '朋友');
      expect(server.draftCalls, 1);
      // 显式 null 与缺省同键——第二次调用命中缓存，不出网。
      await rank();
      expect(server.draftCalls, 1);
    });
  });
}

/// 判断/回复/排序同址的桩服务器（与 jev_client_test 的 StubServer 同款思路，
/// 按请求体分诊），另加记录起草双提示词与 SSE 分支（draftStream 用）。
class StubServer {
  int draftCalls = 0;
  int rankCalls = 0;
  int totalRequests = 0;

  String lastDraftModel = '';
  String lastDraftSystem = '';
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
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      final systemMessage = messages.first as Map<String, dynamic>;
      final last = messages.last as Map<String, dynamic>;
      final system = systemMessage['content'] as String? ?? '';
      final user = last['content'] as String;
      final model = body['model'] as String? ?? '';

      // 流式分支（draftStream）：Accept 是 text/event-stream 时回两段增量。
      if (req.headers.value('accept') == 'text/event-stream') {
        draftCalls++;
        lastDraftModel = model;
        lastDraftSystem = system;
        lastDraftUser = user;
        final res = req.response;
        res.headers.contentType =
            ContentType('text', 'event-stream', charset: 'utf-8');
        res.write(_sse('[{"strategy":"safe","text":"先接住她"}'));
        res.write(_sse(',{"strategy":"forward","text":"我去接你"}]'));
        res.write('data: [DONE]\n\n');
        await res.close();
        return;
      }

      String content;
      if (user.contains('=== QUESTIONS ===') &&
          user.contains('id: best_reply')) {
        rankCalls++;
        content = rankReply;
      } else {
        draftCalls++;
        lastDraftModel = model;
        lastDraftSystem = system;
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
      // 测试收尾强制关服时迟到的读写失败不算数（与 jev_client_test 同口径）。
    }
  }

  /// 一条 SSE 增量：内容用 jsonEncode 转义，inner 引号不会写坏事件。
  static String _sse(String text) =>
      'data: {"choices":[{"delta":{"content":${jsonEncode(text)}}}]}\n\n';
}

/// 七题判断/排序/起草的桩答复（与 jev_client_test 逐字同口径；本文件自足）。
const String draftReply = '['
    '{"strategy":"safe","text":"先接住她，别急着解释"},'
    '{"strategy":"forward","text":"我想你了，这周末见一面？"},'
    '{"strategy":"angle","text":"换我主动汇报行程，如何？"}'
    ']';

const String rankReply = '''
{
  "best_reply": {"choice": "reply_b", "confidence": 0.9,
                 "probabilities": {"reply_a": 0.2, "reply_b": 0.7, "reply_c": 0.1}}
}
''';
