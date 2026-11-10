import 'dart:convert';
import 'dart:io';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 领域卡与台账构建入口的移植钉子 —— 对照旧仓库
/// `core/kb/DomainBrief.kt`、`core/kb/Ledger.kt`（object LedgerPrompt）与
/// `jev/ReplyClient.kt` 的 domainBrief / rebuildLedger。
///
/// 文案断言逐字钉住：这些字符串直接进模型提示词，改一个字，
/// 行为就静默漂移到旧仓库验证过的结论之外。
void main() {
  group('DomainBrief 文案（逐字对照 DomainBrief.kt）', () {
    test('SYSTEM：逐字', () {
      expect(
          DomainBrief.system,
          '你在给一个中文私密角色扮演助手写**领域设定卡**。用户和对方是成年人、自愿、'
          '已经约定好安全词和硬边界。这张卡会被逐字放进每次回复的提示词里，作用是让'
          '回复保持在这个语境的规矩、流程和说法里，而不是给出通用的安慰或说教。\n'
          '你只做归纳：素材里没有的东西不要编。用中文，不要 Markdown 标题符号，'
          '直接分小段写，每段以「词：」开头。');
    });

    test('user：主题、900 上限与素材分隔线', () {
      final p = DomainBrief.user('网调', '素材正文');
      expect(p, startsWith('下面是从一个「网调」知识库里按来源均衡采样出来的片段。'));
      expect(p, contains('1. 总长不超过 900 个汉字。'));
      expect(p, contains('素材：\n----------------\n素材正文\n----------------'));
      expect(p.endsWith('----------------'), isTrue);
      // 空主题回退 DEFAULT_TOPIC = 网调。
      expect(DomainBrief.user('', 'x'), contains('「网调」'));
    });

    test('六段小节标题逐字在位', () {
      final p = DomainBrief.user('网调', '');
      for (final seg in [
        '   角色与关系：谁是什么身份，谁定规矩',
        '   称呼与语气：常用的称呼、说话的口吻和长度',
        '   典型流程：这类对话通常怎么推进（开场／布置／执行／汇报／收尾）',
        '   常用说法：这个领域里高频出现的词和句式（列 15-25 个词即可）',
        '   边界与安全：必须一直遵守的底线、安全词怎么用、事后怎么处理',
        '   不要做什么：最容易让回复「出戏」的几种写法',
      ]) {
        expect(p, contains(seg));
      }
    });
  });

  group('DomainBrief.sample（按来源均衡采样）', () {
    Note note(String id, String doc, String content, {bool enabled = true}) =>
        Note(
          id: id,
          title: 't$id',
          content: content,
          tags: ['kb', doc],
          enabled: enabled,
        );

    test('每份来源先拿标题行，再按步长均匀取段', () {
      final notes = [
        for (var i = 0; i < 8; i++) note('a$i', '书A', 'A 段 $i'),
        for (var i = 0; i < 4; i++) note('b$i', '书B', 'B 段 $i'),
      ];
      final s = DomainBrief.sample(notes);
      // 书A 8 段：take = 1600/400 = 4，step = 8/4 = 2 → 取下标 0,2,4,6。
      expect(s, contains('### 来源：书A（共 8 段）'));
      expect(s, contains('A 段 0'));
      expect(s, contains('A 段 2'));
      expect(s, contains('A 段 4'));
      expect(s, contains('A 段 6'));
      expect(s, isNot(contains('A 段 1')));
      // 书B 4 段：step = 1 → 全取。
      expect(s, contains('### 来源：书B（共 4 段）'));
      expect(s, contains('B 段 3'));
      // 段数多的来源排前面（稳定排序：并列时保持插入序）。
      expect(s.indexOf('书A'), lessThan(s.indexOf('书B')));
    });

    test('禁用的笔记不参与，无 tags[1] 退回标题，标题也空退回（无标题）', () {
      final s = DomainBrief.sample([
        note('x', '书C', '内容', enabled: false),
        const Note(id: 'y', title: '独立笔记', content: '正文'),
        const Note(id: 'z', title: '', content: '正文2'),
      ]);
      expect(s, isNot(contains('书C')));
      expect(s, contains('### 来源：独立笔记（共 1 段）'));
      expect(s, contains('### 来源：（无标题）（共 1 段）'));
    });

    test('每段只取开头 400 字，总量封顶后停止', () {
      final long = List.filled(500, '汉').join();
      final s = DomainBrief.sample([note('a', '书A', long)]);
      expect(s, contains(long.substring(0, 400)));
      expect(s, isNot(contains('汉' * 500)));
    });

    test('预算封顶：塞满 24000 字预算后不再取段', () {
      // 每段 400 字、预算 24000 → 最多 60 段；给 100 段也只取到封顶。
      final seg = List.filled(400, '字').join();
      final notes = [
        for (var i = 0; i < 100; i++) note('n$i', '书', seg),
      ];
      final s = DomainBrief.sample(notes);
      expect(('字' * 400).allMatches(s).length, lessThanOrEqualTo(60));
    });
  });

  group('DomainBrief.normalize / note', () {
    test('清掉围栏与加粗', () {
      expect(DomainBrief.normalize('```\n**角色**：主\n```'), '角色：主');
    });

    test('没有汉字返回 null', () {
      expect(DomainBrief.normalize('   '), isNull);
      expect(DomainBrief.normalize('abc123'), isNull);
    });

    test('超过 900 汉字在最后一个句末处断句', () {
      final half = List.filled(500, '长').join();
      final out = DomainBrief.normalize('$half。${half}尾巴');
      expect(out, '$half。');
      expect(DomainBrief.hanCount(out!), lessThanOrEqualTo(900));
    });

    test('note：常驻、标题带主题、空输出返回 null', () {
      final n = DomainBrief.note('内容', '网调', id: 'id1', now: 7);
      expect(n!.id, 'id1');
      expect(n.title, '网调领域卡（自动预扫）');
      expect(n.tags, ['领域卡', '网调']);
      expect(n.alwaysOn, isTrue);
      expect(n.enabled, isTrue);
      expect(n.updatedAt, 7);
      expect(n.type, 'note');
      // 空主题回退默认主题；全空白输出不可用。
      expect(DomainBrief.note('内容', '', id: 'x')!.tags, ['领域卡', '网调']);
      expect(DomainBrief.note('内容', '', id: 'x')!.title, '网调领域卡（自动预扫）');
      expect(DomainBrief.note('　', '网调', id: 'x'), isNull);
    });
  });

  group('LedgerPrompt 文案（逐字对照 Ledger.kt 的 object LedgerPrompt）', () {
    test('system：字段骨架与规则逐字在位', () {
      final sys = LedgerPrompt.system();
      expect(
          sys,
          startsWith('你是聊天记录的整理助手。把给到的一段聊天记录整理成'
              '一份供后续回复使用的「会话台账」。\n'));
      expect(
          sys,
          contains('{"address":"","relation":"","tone":"","threads":[],'
              '"boundaries":[],"terms":[{"term":"","value":""}]}'));
      for (final rule in [
        '- address（称呼）：双方实际用过的称呼，以及各自怎么自称。',
        '- relation（关系）：一句话说清现在是什么关系、进行到哪一步。',
        '- tone（语气基线）：一句话说清两人说话的语气、节奏和亲密程度。',
        '- threads（在办的事）：还没结束的话题或约定，每条一句话，最多 6 条。',
        '- boundaries（边界）：双方明确说过的限制、禁区、安全词、不能碰的话题，最多 6 条。',
        '- terms（固定说法）：这一场里约定过的角色名、代号、专有说法；term 是词，'
            'value 是它的含义或用法。最多 12 条。',
        '- 只写记录里真实出现过的东西，不要推断、不要补全、不要写泛泛的好话。',
        '- 空的内容必须是空字符串或空数组，不要写「无」「暂无」「没有」。',
        '- 台账是给回复模型看的，用陈述句，不要写建议、不要写分析、不要评论。',
      ]) {
        expect(sys, contains(rule));
      }
    });

    test('user：首建与增量两个分支', () {
      expect(LedgerPrompt.user(null, '记录\n'),
          startsWith('上一版台账：无（这是第一次整理）\n'));
      expect(
          LedgerPrompt.user('  {"address":"老公"}  ', '记录'),
          contains('上一版台账（在此基础上补充，不要丢掉仍然有效的条目）：\n'
              '{"address":"老公"}\n'));
      final p = LedgerPrompt.user(null, '  记录  ');
      expect(p, contains('\n本轮要整理的新增聊天记录（越靠下越新）：\n记录\n'));
      expect(p.endsWith('\n请输出更新后的完整台账 JSON。'), isTrue);
    });
  });

  group('ReplyClient 生成入口（对照 ReplyClient.kt 的 domainBrief / rebuildLedger）',
      () {
    late ChatStub server;
    late ReplyClient client;

    setUp(() async {
      server = ChatStub();
      await server.start();
      final config = JevConfig()
        ..replyBaseUrl = 'http://127.0.0.1:${server.port}'
        ..replyKey = 'gen-key'
        ..replyModel = 'reply-model';
      client = ReplyClient(config);
    });

    tearDown(() async {
      await server.close();
    });

    test('domainBrief：生成路由、温度 0.3、SYSTEM 逐字、输出裁边', () async {
      server.next = '  一张领域卡  ';
      final out = await client.domainBrief('网调', '素材');

      expect(out, '一张领域卡');
      expect(server.calls, 1);
      expect(server.temperature, 0.3);
      expect(server.system, DomainBrief.system);
      expect(server.user, DomainBrief.user('网调', '素材'));
      expect(server.model, 'reply-model');
      expect(server.auth, 'Bearer gen-key');
      expect(server.path, '/chat/completions');
    });

    test('domainBrief：空 sample 直接返回空串，不出网', () async {
      expect(await client.domainBrief('网调', '   '), '');
      expect(server.calls, 0);
    });

    test('rebuildLedger：温度 0.2、带上版台账、输出走 Ledger.parse', () async {
      server.next =
          '{"address":"老公","relation":"情侣","tone":"亲昵",'
          '"threads":["周末见面"],"boundaries":[],"terms":[]}';
      final prev = Ledger(
          address: '老公', relation: '旧关系', coveredUntil: 5, builtAt: 6);
      final before = DateTime.now().millisecondsSinceEpoch;
      final ledger = await client.rebuildLedger(prev, '对方：在吗', 42);
      final after = DateTime.now().millisecondsSinceEpoch;

      expect(ledger, isNotNull);
      expect(ledger!.address, '老公');
      expect(ledger.relation, '情侣');
      expect(ledger.threads, ['周末见面']);
      expect(ledger.coveredUntil, 42);
      // builtAt 取当下，不是沿用旧台账的 6。
      expect(ledger.builtAt, inInclusiveRange(before, after));
      expect(server.temperature, 0.2);
      expect(server.system, LedgerPrompt.system());
      // user 提示词带着上一版台账的 JSON（增量更新语义）。
      expect(server.user, LedgerPrompt.user(prev.encode(), '对方：在吗'));
    });

    test('rebuildLedger：空 transcript 返回 null，不出网', () async {
      expect(await client.rebuildLedger(null, '   ', 1), isNull);
      expect(server.calls, 0);
    });

    test('rebuildLedger：不可解析的输出返回 null 而不是抛异常', () async {
      server.next = '模型抽风了，没有 JSON';
      expect(await client.rebuildLedger(null, '记录', 1), isNull);
    });
  });
}

/// 单响应桩：记录最近一次请求的路径 / 鉴权 / 模型 / 温度 / 双提示词。
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
