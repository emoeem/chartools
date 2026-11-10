import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// A4 润色路由的 HTTP 层钉子（复核项）：`ReplyClient.rewriteOnPolishRoute`
/// 是 A2 linter 与 S1 复查两条自动整改的出口，这里用假服务器钳住「请求真的
/// 去了哪、温度是多少」，而不是只测配置推导：
///  - 配了润色路由 → 打到 polishEndpoint，密钥/模型用润色侧，温度 0.4，
///    提示词与手动 refine 共用（rewriteSystem 字面量 + refineUserPrompt）；
///  - 没配润色路由 → 按回退规则落回回复路由，温度同为 0.4。兼容口径（复核
///    更正）：这不是「与改前逐字节一致」——A4 之前这两处自动整改分别走
///    手动 refine（0.65）与一次批量 draft；逐字节不变的只有手动 refine
///    路径本身。见 reply_client.dart rewriteOnPolishRoute 的注释。
void main() {
  // 与 ReplyClient._rewriteSystem 逐字一致（私有常量，测试侧按字面钉住，
  // 漂移会在 system 断言上大声失败）。
  const rewriteSystem =
      '你是即时通讯回复改写助手。只输出一个 JSON 数组，且只能有一个对象：'
      '{"strategy":"safe","text":"..."}。'
      '保持原意和事实，不补造记忆，不解释，不加引号。';

  const snapshot = ChatSnapshot(
    title: '小美',
    messages: [Msg(side: 'other', text: '周末有空吗')],
  );

  Future<RankedReply?> rewrite(ReplyClient client) =>
      client.rewriteOnPolishRoute(
        snapshot,
        '朋友',
        '周五一定交付。',
        '别做无法兑现的承诺。',
        style: '',
      );

  group('rewriteOnPolishRoute（A4，HTTP 层）', () {
    late ChatStub reply;
    late ChatStub polish;
    late ReplyClient client;

    setUp(() async {
      reply = ChatStub();
      polish = ChatStub();
      await reply.start();
      await polish.start();
      final config = JevConfig()
        ..replyBaseUrl = 'http://127.0.0.1:${reply.port}'
        ..replyKey = 'reply-key'
        ..replyModel = 'reply-model'
        ..polishBaseUrl = 'http://127.0.0.1:${polish.port}'
        ..polishKey = 'polish-key'
        ..polishModel = 'polish-model';
      client = ReplyClient(config);
    });

    tearDown(() async {
      await reply.close();
      await polish.close();
    });

    test('配置润色路由：请求打到 polishEndpoint，温度 0.4，密钥/模型用润色侧', () async {
      polish.next = '[{"strategy":"safe","text":"我和团队核实后今天下班前答复您"}]';
      final out = await rewrite(client);

      expect(out, isNotNull);
      expect(out!.text, '我和团队核实后今天下班前答复您');
      expect(polish.calls, 1, reason: '重写请求必须走润色路由');
      expect(reply.calls, 0, reason: '回复路由不该被这次重写碰到');
      expect(polish.temperature, 0.4);
      expect(polish.auth, 'Bearer polish-key');
      expect(polish.model, 'polish-model');
      expect(polish.system, rewriteSystem);
      expect(
          polish.user,
          refineUserPrompt('朋友', null, 30, '', '别做无法兑现的承诺。',
              '周五一定交付。', convoLines(snapshot.messages)));
    });

    test('未配润色路由：按回退规则落回回复路由，温度仍是 0.4', () async {
      final config = JevConfig()
        ..replyBaseUrl = 'http://127.0.0.1:${reply.port}'
        ..replyKey = 'reply-key'
        ..replyModel = 'reply-model';
      client = ReplyClient(config);

      reply.next = '[{"strategy":"safe","text":"我和团队核实后再答复"}]';
      await rewrite(client);

      expect(reply.calls, 1);
      expect(reply.temperature, 0.4, reason: '回退只换端点不换温度口径');
      expect(reply.auth, 'Bearer reply-key');
      expect(reply.model, 'reply-model');
      expect(polish.calls, 0);
    });
  });
}

/// 单响应桩（与 domain_brief_test 的 ChatStub 同款，本仓库测试桩各自自足）：
/// 记录最近一次请求的路径 / 鉴权 / 模型 / 温度 / 双提示词。
class ChatStub {
  int calls = 0;
  String next = '';
  String auth = '';
  String path = '';
  String model = '';
  double temperature = -1;
  String system = '';
  String user = '';
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
      calls++;
      auth = req.headers.value('authorization') ?? '';
      path = req.uri.path;
      final body = jsonDecode(raw) as Map<String, dynamic>;
      final messages = body['messages'] as List<dynamic>;
      model = body['model'] as String? ?? '';
      temperature = (body['temperature'] as num).toDouble();
      system = (messages[0] as Map<String, dynamic>)['content'] as String;
      user = (messages[1] as Map<String, dynamic>)['content'] as String;

      final res = req.response;
      res.headers.contentType = ContentType.json;
      res.write(jsonEncode({
        'choices': [
          {
            'message': {'role': 'assistant', 'content': next},
          },
        ],
      }));
      await res.close();
    } catch (_) {
      // 测试收尾强制关服时迟到的读写失败不算数。
    }
  }
}
