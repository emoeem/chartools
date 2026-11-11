import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 传输层的重试 / 状态码 / SSE 规则，打真实的本地 server —— 对照旧仓库
/// `jev/HttpJsonTest.kt`（MockWebServer）的构造方式。
///
/// 这些规则决定一次失败的分析是被重试、被上报还是被放弃，而它们曾经没法测：
/// 对着不存在的服务器只能得到传输错误。本地 HttpServer 能回答任意状态、
/// 任意响应体、任意延迟，每条分支都真实跑一遍。
void main() {
  late MockServer server;

  setUp(() async {
    // 收拢退避：3 次尝试的睡眠从 ~1.5 s 压到 ~7 ms。生产侧不会写这个值。
    HttpJson.retryBackoffMs = 1;
    server = MockServer();
    await server.start();
  });

  tearDown(() async {
    HttpJson.retryBackoffMs = 500;
    await server.close();
  });

  String url() => 'http://127.0.0.1:${server.port}/v1/decisions';

  Map<String, dynamic> body() => {
        'model': 'm',
        'state': {
          'chat': {'relationship': '女朋友'},
        },
      };

  Future<Map<String, dynamic>> post() => HttpJson.post(
        url(),
        'test-key',
        body(),
        Route.judge,
        extraHeaders: const {'X-Test': '1'},
      );

  Future<Object> failure(Future<Object?> Function() run) async {
    try {
      await run();
    } catch (e) {
      return e;
    }
    fail('预期请求失败，但它成功了');
  }

  group('post 缓冲路径', () {
    test('200 正常解码，鉴权头与 UTF-8 体如实送达', () async {
      server.enqueue(const MockResponse(
        200,
        '{"answers":{"danger_level":{"noul":0.2}}}',
      ));

      final resp = await post();

      final answers = resp['answers'] as Map<String, dynamic>;
      final danger = answers['danger_level'] as Map<String, dynamic>;
      expect(danger['noul'], closeTo(0.2, 1e-9));

      final sent = server.requests.single;
      expect(sent.authorization, 'Bearer test-key');
      expect(sent.header('X-Test'), '1');
      expect(sent.contentType, startsWith('application/json'));
      // 中文必须以 UTF-8 原样到岸，不能被编码层毁掉。
      final sentBody = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(sentBody['model'], 'm');
      final state = sentBody['state'] as Map<String, dynamic>;
      final chat = state['chat'] as Map<String, dynamic>;
      expect(chat['relationship'], '女朋友');
    });

    test('401 不重试：文案含真实状态与脱敏后的原因', () async {
      server.enqueue(const MockResponse(
        401,
        '{"error":{"message":"bad test-key"}}',
      ));

      final e = await failure(post);
      final api = e as ApiException;

      expect(api.status, 401);
      expect(api.route, Route.judge);
      // 用户必须看到「为什么」，而不是一句笼统的「请求失败」。
      expect(api.message, contains('判断接口 HTTP 401'));
      // 密钥从错误体里脱敏：出现 [key]，绝不回显原文。
      expect(api.message, contains('bad [key]'));
      expect(api.message, isNot(contains('test-key')));
      // 客户端错误是终局：密钥错了重试只会延迟真正的报错。
      expect(server.requestCount, 1);
    });

    test('429 重试，第二次成功', () async {
      server.enqueue(const MockResponse(429, 'busy'));
      server.enqueue(const MockResponse(200, '{"answers":{}}'));

      final resp = await post();

      expect(resp['answers'], isA<Map<String, dynamic>>());
      expect(server.requestCount, 2);
    });

    test('fix(#8 DS-3) 529（overloaded）走重试，第二次成功', () async {
      // 白名单的另一半：429/529 是仅有的两个「稍后再来」的客户端语义码。
      // 529 不落 [400, 500) 区间，重试判定里显式写出的 status != 529 今天
      // 恒真——这条单测钉住的是行为本身：将来区间或判定被改坏时它先红。
      server.enqueue(const MockResponse(529, 'overloaded'));
      server.enqueue(const MockResponse(200, '{"answers":{}}'));

      final resp = await post();

      expect(resp['answers'], isA<Map<String, dynamic>>());
      expect(server.requestCount, 2);
    });

    test('5xx 重试满三次后按最后一次上报', () async {
      server
        ..enqueue(const MockResponse(500, 'boom'))
        ..enqueue(const MockResponse(500, 'boom'))
        ..enqueue(const MockResponse(500, 'boom'));

      final e = await failure(post);

      expect((e as ApiException).status, 500);
      expect(server.requestCount, 3);
    });

    test('服务端截断回显 key 片段也脱敏：前后 8 字符不泄漏（kimi-review #10）', () async {
      // 19 字符的 key：前 8 = sk-abcde，后 8 = ij123456。响应体里只回显
      // 片段、不含整串——原先的 replaceAll(key) 精确匹配抓不住它们。
      const key = 'sk-abcdefghij123456';
      server.enqueue(const MockResponse(
        401,
        '{"error":{"message":"invalid key: sk-abcde…（prefix）…ij123456（suffix）"}}',
      ));

      final e = await failure(
          () => HttpJson.post(url(), key, body(), Route.judge));
      final api = e as ApiException;

      expect(api.status, 401);
      expect(api.message, contains('[key]'));
      expect(api.message, isNot(contains('sk-abcde')));
      expect(api.message, isNot(contains('ij123456')));
      // 客户端错误是终局，一次出网。
      expect(server.requestCount, 1);
    });

    test('URL 编码形态的 key 回显也脱敏（kimi-review #10）', () async {
      // 含保留字符的 key：Uri.encodeComponent('sk=secret123') =
      // 'sk%3Dsecret123'，服务端按编码形态回显时原先也抓不住。
      const key = 'sk=secret123';
      server.enqueue(const MockResponse(
        401,
        '{"error":{"message":"auth failed for sk%3Dsecret123"}}',
      ));

      final e = await failure(
          () => HttpJson.post(url(), key, body(), Route.judge));
      final api = e as ApiException;

      expect(api.message, contains('[key]'));
      expect(api.message, isNot(contains('sk%3Dsecret123')));
      expect(api.message, isNot(contains('sk=secret123')));
    });

    test('请求体不可编码：抛参数错误，一次都不出网、不重试（kimi-review #9）', () async {
      // body 里塞一个 jsonEncode 处理不了的对象。原先它会被 catch-all 当
      // 传输失败重试满 3 次；现在编码在循环外，编码失败直接抛参数错误。
      final bad = <String, dynamic>{
        'model': 'm',
        'payload': DateTime.now(), // DateTime 没有 toJson，编码必抛
      };

      final e = await failure(
          () => HttpJson.post(url(), 'test-key', bad, Route.judge));

      expect(e, isA<ArgumentError>());
      expect(server.requestCount, 0);
    });
  });

  group('stream SSE 路径', () {
    Future<String> stream(List<MockResponse> script,
        {required void Function(String) onData}) async {
      for (final r in script) {
        server.enqueue(r);
      }
      return HttpJson.stream(
        url(),
        'test-key',
        body(),
        Route.reply,
        onData: onData,
      );
    }

    test('逐事件回调，返回值是各事件的拼接', () async {
      final seen = <String>[];
      final raw = await stream([
        const MockResponse(
          200,
          'data: {"choices":[{"delta":{"content":"你好"}}]}\n\n'
          ': keep-alive\n\n'
          'data: {"choices":[{"delta":{"content":"呀"}}]}\n\n'
          'data: [DONE]\n\n',
          headers: {'Content-Type': 'text/event-stream'},
        ),
      ], onData: seen.add);

      // 注释行（心跳）与 [DONE] 都不算事件。
      expect(seen, hasLength(2));
      expect(seen[0], contains('你好'));
      expect(seen[1], contains('呀'));
      expect('"content"'.allMatches(raw).length, 2);
      final sent = server.requests.single;
      expect(sent.header('Accept'), 'text/event-stream');
      expect(sent.authorization, 'Bearer test-key');
    });

    test('多行 data 拼成一个事件负载', () async {
      final seen = <String>[];
      final raw = await stream([
        const MockResponse(
          200,
          'data: 第一行\n'
          'data: 第二行\n'
          '\n'
          'data: [DONE]\n\n',
        ),
      ], onData: seen.add);

      // SSE 规范：一个事件的多条 data 行以换行连接后再交给调用方。
      expect(seen, ['第一行\n第二行']);
      expect(raw, '第一行\n第二行\n');
    });

    test('[DONE] 提前收线，不等服务器关闭连接', () async {
      // 有的服务器发完 [DONE] 后并不关闭连接；等流自己结束会一直挂到
      // 看门狗超时。读到 [DONE] 就必须收线（与 Kotlin 的 source.cancel()
      // 对齐），服务端那 5 秒不能拖住客户端。
      final seen = <String>[];
      final sw = Stopwatch()..start();
      final raw = await stream([
        MockResponse(
          200,
          'data: hello\n\n'
          'data: [DONE]\n\n',
          holdOpen: const Duration(seconds: 5),
        ),
      ], onData: seen.add);
      sw.stop();

      expect(sw.elapsed, lessThan(const Duration(seconds: 3)));
      expect(seen, ['hello']);
      expect(raw, 'hello\n');
    });

    test('非 200 抛 ApiException 且带真实状态码', () async {
      server.enqueue(const MockResponse(401, 'bad key'));

      final e = await failure(() => HttpJson.stream(
          url(), 'test-key', body(), Route.reply,
          onData: (_) {}));

      expect(e, isA<ApiException>());
      expect((e as ApiException).status, 401);
      expect(e.message, contains('回复接口 HTTP 401'));
    });

    test('stream 路径同样做片段脱敏（kimi-review #10）', () async {
      const key = 'sk-abcdefghij123456';
      server.enqueue(const MockResponse(401, 'leaked prefix sk-abcde here'));

      final e = await failure(() =>
          HttpJson.stream(url(), key, body(), Route.reply, onData: (_) {}));

      expect((e as ApiException).message, isNot(contains('sk-abcde')));
      // fix(kimi-review #N gate)：上行 as 已把局部 e 提升为 ApiException，这里
      // 再 cast 触发 analyzer 的 unnecessary_cast（门禁 0 issue 要求）。
      expect(e.message, contains('[key]'));
    });
  });
}

/// 仿 MockWebServer 的极简脚本服务器：按入队顺序回响应，逐条记录收到的请求。
class MockServer {
  final List<MockResponse> _queue = [];
  final List<RecordedRequest> requests = [];
  HttpServer? _server;

  void enqueue(MockResponse response) => _queue.add(response);

  int get requestCount => requests.length;

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
      requests.add(RecordedRequest(
        path: req.uri.path,
        authorization: req.headers.value('authorization') ?? '',
        accept: req.headers.value('accept') ?? '',
        contentType: req.headers.contentType?.toString() ?? '',
        headers: req.headers,
        body: raw,
      ));
      final script = _queue.isNotEmpty
          ? _queue.removeAt(0)
          : const MockResponse(500, '无脚本');
      final res = req.response;
      // MockWebServer 语义：写出去的字节立即上线（「先冲出去再拖住连接」
      // 的前提）。dart:io 默认 bufferOutput=true 时 flush() 也不推块，数据
      // 要等到 res.close() 才和终止块一起发出，holdOpen 就成了「服务器什么
      // 都没发」，[DONE] 提前收线的场景无从谈起。
      res.bufferOutput = false;
      res.statusCode = script.status;
      script.headers.forEach(res.headers.set);
      // 脚本体按 UTF-8 字节上线（本文件读请求侧也是 utf8.decoder）。用
      // res.write(String) 会按响应 Content-Type 推导编码——text/event-stream
      // 不带 charset 时按 latin1 写，带中文的脚本体当场抛 Invalid argument，
      // 连响应头都发不出去，客户端只能干等。
      res.add(utf8.encode(script.body));
      if (script.holdOpen != null) {
        // 先冲出去再拖住连接：模拟「服务器不结束这次响应」的悬置状态。
        await res.flush();
        await Future<void>.delayed(script.holdOpen!);
      }
      await res.close();
    } catch (_) {
      // 测试收尾强制关服、或客户端已按 [DONE] 收线时，迟到的失败不算数。
    }
  }
}

class MockResponse {
  const MockResponse(this.status, this.body,
      {this.headers = const {}, this.holdOpen});

  final int status;
  final String body;
  final Map<String, String> headers;

  /// 非 null 时：写完响应体先 flush，再等满 [holdOpen] 才关闭，
  /// 用来验证客户端不会陪着服务器干等。
  final Duration? holdOpen;
}

class RecordedRequest {
  const RecordedRequest({
    required this.path,
    required this.authorization,
    required this.accept,
    required this.contentType,
    required this.headers,
    required this.body,
  });

  final String path;
  final String authorization;
  final String accept;
  final String contentType;
  final HttpHeaders headers;
  final String body;

  String header(String name) => headers.value(name) ?? '';
}
