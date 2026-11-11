import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 第 3 轮外部审查 K-1 的复现测试：**改安全闸词表 → 同会话旧候选会不会经
/// 缓存绕过新闸？**
///
/// 被审的主张：安全闸词表不进任何缓存键分量，用户改边界词后同会话旧候选
/// 照旧展示。这组测试钉住的是反驳它的那条传递链：
///
///  1. 闸的用户可配输入（硬边界 / 安全词 / 黄灯）全部来自 [PersonaCard]，
///     而卡是在起草预检时从 `StyleSource.resolve(全局 style, 联系人 persona)`
///     的那段文本解析出来的（reply_client.dart `_draftAsk`）；
///  2. 同一段文本正是回复缓存键的 `style` 分量（jev_client.dart `_cacheKey`
///     里同一个 resolve 调用）。
///
/// 所以「改词表 → style 变 → 键变 → 缓存作废 → 闸按新卡重评」，没有旁路。
/// 谁哪天把 `style` 从键里摘掉、或让闸改用一段不经 style 的词表来源，这里
/// 立刻红——键分量完备性按 reply_cache_key.dart 顶部注释的说法「只能靠
/// 测试咬住」，这一组就是咬住闸那条分量的牙。
///
/// 对照组（第一个 test）先证明计数器真的测得出缓存命中，否则后面
/// 「第二轮重新起草」的断言都是空话。
void main() {
  late StubServer server;
  late JevConfig config;
  late JevClient client;

  setUp(() async {
    server = StubServer();
    await server.start();
    config = JevConfig()
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

  /// 同一个会话（同标题、同消息）：两轮之间**只有人设词表在变**——键里其余
  /// 分量（signature / relationship / ctxKey / ledger / judgment / params）
  /// 全部不动，键变了就只能来自 style。
  ChatSnapshot snapshotFor(String otherText) => ChatSnapshot(
        title: '测试会话',
        messages: [Msg(side: 'other', text: otherText)],
      );

  ChatContext ctxWith(String persona) => ChatContext(
        contact: Contact(id: 'c1', name: '小希', persona: persona),
      );

  /// 全局 style 留空（JevConfig 默认），联系人专用人设压过它——与 app 里
  /// 「给某个联系人写词表」的最常见路径一致。
  const noWordsPersona = '称呼：先生';

  test('对照：不改词表，同会话第二轮命中缓存（计数器真的测得出缓存）', () async {
    final snapshot = snapshotFor('今天加班到几点？');
    final ctx = ctxWith(noWordsPersona);

    await client.draftAndRank(snapshot, '女朋友', ctx: ctx);
    expect(server.draftCalls, 1);
    expect(server.rankCalls, 1);

    await client.draftAndRank(snapshot, '女朋友', ctx: ctx);

    // 第二轮零出网：缓存命中。这证明后面的测试用计数器判断「键变/没变」是
    // 可靠的——没有这组对照，「重新起草」可能是 stub 失灵的假象。
    expect(server.draftCalls, 1, reason: '未改词表时必须命中缓存');
    expect(server.rankCalls, 1);
    expect(server.totalRequests, 2);
  });

  test('K-1/硬边界：加上硬边界词后，同会话第二轮按新词表拦截而不是回放旧候选', () async {
    final snapshot = snapshotFor('记得删记录，别留痕');
    final ctx = ctxWith(noWordsPersona);

    // 第一轮：卡里没有边界词，这条消息不触闸，候选照常起草并进缓存。
    final first = await client.draftAndRank(snapshot, '女朋友', ctx: ctx);
    expect(first, hasLength(3));
    expect(server.draftCalls, 1);

    // 用户在设置里给这张卡加了硬边界（Kimi 场景里的「改边界词配置」）。
    final withBoundary =
        ctxWith('$noWordsPersona\n硬边界：不要留痕');

    Object? caught;
    try {
      await client.draftAndRank(snapshot, '女朋友', ctx: withBoundary);
    } catch (e) {
      caught = e;
    }

    // 若词表真的不在键里，这里会原样回放第一轮的缓存候选、不抛任何异常。
    expect(caught, isA<SafetyBlockedException>(),
        reason: '改了边界词后必须作废缓存、由闸按新卡重拦');
    // 闸报的是 _splitBoundaries 展开后的可匹配关键词（「不要留痕」剥前缀
    // 得「留痕」），不是原句——断言按闸的实际口径写。
    final blockedMessage = (caught as SafetyBlockedException).message;
    expect(blockedMessage, contains('硬边界'),
        reason: '拦截原因必须来自新加的那条边界，而不是内置词表');
    expect(blockedMessage, contains('留痕'));
    // 预检在任何出网之前：第二轮一个请求都没发——旧候选也不是重新算出来的。
    expect(server.totalRequests, 2, reason: '第二轮应零出网（第一轮 draft+rank）');
  });

  test('K-1/安全词：加安全词后，同会话第二轮按新安全词拦截而不是回放旧候选', () async {
    final snapshot = snapshotFor('红灯。先停一下');
    final ctx = ctxWith(noWordsPersona);

    await client.draftAndRank(snapshot, '女朋友', ctx: ctx);
    expect(server.draftCalls, 1);

    final withSafeword = ctxWith('$noWordsPersona\n安全词：红灯');

    Object? caught;
    try {
      await client.draftAndRank(snapshot, '女朋友', ctx: withSafeword);
    } catch (e) {
      caught = e;
    }

    expect(caught, isA<SafetyBlockedException>(),
        reason: '改了安全词后必须作废缓存、由闸按新卡重拦');
    expect((caught as SafetyBlockedException).message, contains('安全词'));
    expect(server.totalRequests, 2);
  });

  test('K-1/黄灯：加黄灯词后，同会话第二轮把新 caution 带进新的起草请求', () async {
    final snapshot = snapshotFor('先减速，我们聊聊');
    final ctx = ctxWith(noWordsPersona);

    await client.draftAndRank(snapshot, '女朋友', ctx: ctx);
    final round1User = server.lastDraftUser;
    expect(round1User, isNot(contains('黄灯信号')), reason: '第一轮没有黄灯词');

    final withYellow = ctxWith('$noWordsPersona\n黄灯：减速');
    final second = await client.draftAndRank(snapshot, '女朋友', ctx: withYellow);

    // 黄灯不拦整轮、只挂 caution（safety_gate.dart），所以第二轮有真出网——
    // 关键是它必须是**新起草**而不是缓存回放：caution 是闸的输出，进了键里
    // 没有的缓存值就永远带不出来。
    expect(server.draftCalls, 2, reason: '改黄灯词后必须换键重起草');
    expect(second, hasLength(3));
    // 「黄灯信号「减速」」是闸 caution 的专属措辞；persona 卡块渲染的是
    // 「黄灯：减速（…）」，不会撞上这个断言。
    expect(server.lastDraftUser, contains('黄灯信号「减速」'));
  });

  test('K-1/键变直证：词表变了但闸结果不变时，同会话第二轮照样重新起草', () async {
    final snapshot = snapshotFor('记得删记录，别留痕');
    final ctx = ctxWith(noWordsPersona);

    await client.draftAndRank(snapshot, '女朋友', ctx: ctx);

    // 加一条与这条消息无关的边界词：闸放行结果不变，但卡文本变了 →
    // style 分量变 → 键变。第二轮必须重新出网，而不是命中旧缓存。
    final unrelatedBoundary = ctxWith('$noWordsPersona\n硬边界：不要提前任');
    final second =
        await client.draftAndRank(snapshot, '女朋友', ctx: unrelatedBoundary);

    expect(server.draftCalls, 2, reason: '词表进键：改词表即换键，哪怕闸放行');
    expect(server.rankCalls, 2);
    expect(second, hasLength(3));
    // 桩数据不变所以两轮文本相同——键变的证据在计数器上，不在文本上。
    expect(server.totalRequests, 4);
  });

  // ------------------------------------------------------- fix(#9 K-3)
  // rankOnly 的排序资格守卫（协议槽位数 3）保留原行为，但必须可见：
  // 不符时显式 ranked:false + trace 留痕，不再是无提示的静默退化。

  test('K-3：rankOnly 非 3 条 → 显式 ranked:false、零出网、trace 留痕', () async {
    final traceLines = <String>[];
    final traced = JevClient(config, onTrace: traceLines.add);

    final candidates = [
      const RankedReply(text: '先接住她，别急着解释'),
      const RankedReply(text: '我想你了，这周末见一面？'),
    ];
    final out = await traced.rankOnly(snapshotFor('在忙吗？'), '女朋友', null,
        candidates);

    // 现行为保留：原样返回、未排序、概率全 0（负值会画出负长度的概率条，
    // 这里是 0 而不是负数）。
    expect(out, hasLength(2));
    expect(out.every((r) => !r.ranked), isTrue);
    expect(out.every((r) => r.prob == 0.0), isTrue);
    expect(out.map((r) => r.text), ['先接住她，别急着解释', '我想你了，这周末见一面？']);
    // 守卫在任何出网之前：count=2 这类非协议形状不该打服务器。
    expect(server.totalRequests, 0);
    // 可见性：trace 恰好一行，说清几条、为什么不排。
    expect(traceLines, hasLength(1));
    expect(traceLines.single, contains('2 条'));
    expect(traceLines.single, contains('ranked:false'));
  });

  test('K-3：rankOnly 3 条 → 正常排序且不产生 trace', () async {
    final traceLines = <String>[];
    final traced = JevClient(config, onTrace: traceLines.add);

    final candidates = [
      const RankedReply(text: '先接住她，别急着解释', strategy: 'safe'),
      const RankedReply(text: '我想你了，这周末见一面？', strategy: 'forward'),
      const RankedReply(text: '换我主动汇报行程，如何？', strategy: 'angle'),
    ];
    final out =
        await traced.rankOnly(snapshotFor('在忙吗？'), '女朋友', null, candidates);

    expect(out, hasLength(3));
    expect(out.every((r) => r.ranked), isTrue);
    // reply_b（0.7）胜出：best-first。
    expect(out[0].text, '我想你了，这周末见一面？');
    expect(out[0].prob, closeTo(0.7, 1e-9));
    expect(server.rankCalls, 1);
    // 合格路径零留痕：trace 只报异常形状，不当流水账。
    expect(traceLines, isEmpty);
  });

  test('K-3：未接 onTrace 的客户端在非 3 条下行为不变（兼容锁）', () async {
    // setUp 里的 client 没传 onTrace：守卫照常降级，绝不因回调缺省而崩。
    final out = await client.rankOnly(snapshotFor('在忙吗？'), '女朋友', null, [
      const RankedReply(text: '甲'),
      const RankedReply(text: '乙'),
    ]);
    expect(out, hasLength(2));
    expect(out.every((r) => !r.ranked), isTrue);
    expect(server.totalRequests, 0);
  });
}

/// OpenAI 兼容的桩服务器：只分诊起草与排序两条路（本组测试不跑七问判断），
/// 按 jev_client_test.dart 同款的请求体标记识别。
class StubServer {
  int draftCalls = 0;
  int rankCalls = 0;
  int totalRequests = 0;

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
      final last = messages.last as Map<String, dynamic>;
      final user = last['content'] as String;

      String content;
      if (user.contains('=== QUESTIONS ===') &&
          user.contains('id: best_reply')) {
        rankCalls++;
        content = rankReply;
      } else if (user.contains('=== QUESTIONS ===')) {
        // 七问判断不在本组测试的链路里，出现了就计一笔便于排查。
        content = judgeReply;
      } else {
        draftCalls++;
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

/// 起草答复：ReplyPrompt 契约的 JSON 数组，三条候选（与 jev_client_test.dart
/// 同一份文本——那份测试已证明它们不会触发 linter 重写，prob 断言才站得住）。
const String draftReply = '['
    '{"strategy":"safe","text":"先接住她，别急着解释"},'
    '{"strategy":"forward","text":"我想你了，这周末见一面？"},'
    '{"strategy":"angle","text":"换我主动汇报行程，如何？"}'
    ']';

/// 排序答复：reply_b（0.7）胜出。
const String rankReply = '''
{
  "best_reply": {"choice": "reply_b", "confidence": 0.9,
                 "probabilities": {"reply_a": 0.2, "reply_b": 0.7, "reply_c": 0.1}}
}
''';

/// 七问判断的答复（本组测试不触发，仅为 stub 完整性保留）。
const String judgeReply = '{"answers": {}}';
