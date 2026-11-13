/// 检索注入链路测试（capture_session.dart 的知识参考注入，超越点）。
///
/// 钉住四条主契约 + 边界：启用笔记进 prompt（带来源标注）、禁用不进、
/// 无命中不进、坏档不炸；另钉：未注入 store、无对方消息、top-k=3、G1
/// 预览列行、构造注入字段。全部走静态入口 [CaptureSession.knowledgeRefsOf]
/// 与 [CaptureSession.buildContext]/[CaptureSession.buildSendPreview]，
/// 不发网络请求。
///
/// 本文件为新增（不改 capture_session_scenario_test.dart 等既有测试）。
/// CaptureSession 的字段初始化器会构造 CaptureAndroid()（注册通道
/// handler），与既有 app 测试同一节奏先初始化 binding。
library;

import 'package:chartools_app/application/capture_session.dart';
import 'package:chartools_core/chartools_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// 故障注入库：检索一炸到底，模拟「坏档把检索路径炸穿」的极端情形。
class _ExplodingStore extends KbStore {
  @override
  LexSearchResult search(
    String query, {
    int k = 5,
    double minScore = 0.0,
    Iterable<String>? anyTag,
    Iterable<String>? anyType,
    Iterable<String>? relevantIds,
    bool includeDisabled = false,
    bool logSearch = true,
  }) {
    throw StateError('存档损坏（测试注入）');
  }
}

ChatSnapshot _snapshot(List<Msg> messages) => ChatSnapshot(messages: messages);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CaptureSession.knowledgeRefsOf（检索注入）', () {
    test('启用笔记命中 → 注入「知识参考（来源：知识库笔记《标题》）」段', () {
      final store = KbStore();
      store.saveNote(
        const Note(id: 'n1', title: '项目代号', content: '凤凰项目的内部代号是蓝鲸'),
        source: KbSource.manual,
      );
      final refs = CaptureSession.knowledgeRefsOf(
        store,
        _snapshot([const Msg(side: 'other', text: '蓝鲸是什么项目的代号来着？')]),
      );
      expect(refs, hasLength(1));
      expect(refs.single.id, 'kb_ref_n1');
      expect(refs.single.title, '知识参考（来源：知识库笔记《项目代号》）');
      expect(refs.single.content, '凤凰项目的内部代号是蓝鲸');
      // type 用默认 'note'：随 ctx.notes → background 进判断/写作两路。
      expect(refs.single.type, 'note');
    });

    test('禁用笔记不进（与 KnowledgeController 启用开关同一口径：读启用位）', () {
      final store = KbStore();
      store.saveNote(
        const Note(
            id: 'n2', title: '项目代号', content: '凤凰项目的内部代号是蓝鲸',
            enabled: false),
        source: KbSource.manual,
      );
      final refs = CaptureSession.knowledgeRefsOf(
        store,
        _snapshot([const Msg(side: 'other', text: '蓝鲸是什么项目的代号来着？')]),
      );
      expect(refs, isEmpty, reason: '停用的笔记不进检索与注入（KbStore.search 缺省口径）');
    });

    test('无命中不进：查询词与库里内容零重叠', () {
      final store = KbStore();
      store.saveNote(
        const Note(id: 'n3', title: '泡茶', content: '如何泡好一壶茶'),
        source: KbSource.manual,
      );
      final refs = CaptureSession.knowledgeRefsOf(
        store,
        _snapshot([const Msg(side: 'other', text: '周末去爬山怎么样')]),
      );
      expect(refs, isEmpty);
    });

    test('坏档不炸：检索路径抛异常 → 静默返回空表，绝不外抛', () {
      final refs = CaptureSession.knowledgeRefsOf(
        _ExplodingStore(),
        _snapshot([const Msg(side: 'other', text: '随便说点什么')]),
      );
      expect(refs, isEmpty);
    });

    test('未注入 KbStore（null）→ 静默跳过，与接入前逐字节一致', () {
      final refs = CaptureSession.knowledgeRefsOf(
        null,
        _snapshot([const Msg(side: 'other', text: '蓝鲸项目')]),
      );
      expect(refs, isEmpty);
    });

    test('没有对方消息（只有我方/发言人未知）→ 跳过，不拿我方消息当 query', () {
      final store = KbStore();
      store.saveNote(
        const Note(id: 'n4', title: '爬山', content: '周末去爬山'),
        source: KbSource.manual,
      );
      expect(
        CaptureSession.knowledgeRefsOf(store, _snapshot([
          const Msg(side: 'me', text: '周末去爬山'),
        ])),
        isEmpty,
        reason: '我方消息不是对方语境，不能当检索线头',
      );
      expect(
        CaptureSession.knowledgeRefsOf(store, _snapshot([
          const Msg(side: 'unknown', text: '周末去爬山'),
        ])),
        isEmpty,
      );
      // 对方消息为空白文本同样跳过。
      expect(
        CaptureSession.knowledgeRefsOf(store, _snapshot([
          const Msg(side: 'other', text: '   '),
        ])),
        isEmpty,
      );
    });

    test('top-k = 3：库里五条全命中也只注入三条（kbRefTopK）', () {
      final store = KbStore();
      for (var i = 1; i <= 5; i++) {
        store.saveNote(
          Note(id: 'k$i', title: '蓝鲸笔记$i', content: '蓝鲸项目的第 $i 条备忘'),
          source: KbSource.manual,
        );
      }
      final refs = CaptureSession.knowledgeRefsOf(
        store,
        _snapshot([const Msg(side: 'other', text: '蓝鲸项目进展如何')]),
      );
      expect(refs, hasLength(CaptureSession.kbRefTopK));
      expect(CaptureSession.kbRefTopK, 3);
    });

    test('取「最后一条」对方消息作 query：多轮对话以最新为准', () {
      final store = KbStore();
      store.saveNote(
        const Note(id: 'a', title: '爬山计划', content: '周日上午去爬北山'),
        source: KbSource.manual,
      );
      // b 与最终 query（那礼拜天上午去爬北山）零重叠：电影笔记不该被牵出来。
      store.saveNote(
        const Note(id: 'b', title: '电影之夜', content: '周五晚上一起看电影'),
        source: KbSource.manual,
      );
      final refs = CaptureSession.knowledgeRefsOf(store, _snapshot(const [
        Msg(side: 'other', text: '周五晚上看电影吗'),
        Msg(side: 'me', text: '好呀'),
        Msg(side: 'other', text: '那礼拜天上午去爬北山'),
      ]));
      expect(refs, hasLength(1));
      expect(refs.single.id, 'kb_ref_a', reason: 'query 是最后一条对方消息（爬山），不是更早的电影');
    });
  });

  group('注入进起草链路（buildContext / G1 预览）', () {
    final store = KbStore();
    store.saveNote(
      const Note(id: 'n1', title: '项目代号', content: '凤凰项目的内部代号是蓝鲸'),
      source: KbSource.manual,
    );
    final snapshot = _snapshot(const [
      Msg(side: 'other', text: '蓝鲸是什么项目的代号来着？'),
    ]);
    final refs = CaptureSession.knowledgeRefsOf(store, snapshot);

    test('refs 进 ctx.notes；来源标注与正文随段出门', () {
      final ctx = CaptureSession.buildContext(knowledgeRefs: refs);
      expect(ctx, isNotNull);
      expect(ctx!.notes, hasLength(1));
      expect(ctx.notes.single.id, 'kb_ref_n1');
      expect(ctx.notes.single.title, '知识参考（来源：知识库笔记《项目代号》）');
      // background 渲染「标题: 正文」（半角冒号+空格，kb_models 的既定形状）——
      // 来源标注作为段名进入两路提示词。
      expect(ctx.background('朋友'),
          contains('知识参考（来源：知识库笔记《项目代号》）: 凤凰项目的内部代号是蓝鲸'));
    });

    test('G1 预览按条列出知识参考（判断/写作两列同源列出）', () {
      final ctx = CaptureSession.buildContext(knowledgeRefs: refs);
      final preview = CaptureSession.buildSendPreview(
        snapshot: snapshot,
        ctx: ctx,
        relationship: '朋友',
      );
      const needle = '知识参考：1 条';
      expect(preview.judge.any((s) => s.startsWith(needle)), isTrue,
          reason: '判断路 background 带 ctx.notes，预览如实列出');
      expect(preview.writer.any((s) => s.startsWith(needle)), isTrue,
          reason: '写作路 knowledgeBlock 带 ctx.notes，预览如实列出');
    });

    test('refs 为空时 buildContext 与不传逐字节一致（回归护栏）', () {
      // ctx 是否非空只看各来源有没有货：refs 空 + 其他输入也空 → null。
      expect(CaptureSession.buildContext(), isNull);
      // 同输入下传空表与不传：同样的 ctx 形状。
      final withoutRefs = CaptureSession.buildContext(
        extra: '今天是她生日',
      );
      final withEmptyRefs = CaptureSession.buildContext(
        extra: '今天是她生日',
        knowledgeRefs: const <Note>[],
      );
      expect(withoutRefs!.notes.length, withEmptyRefs!.notes.length);
      expect(
        withoutRefs.background('朋友'),
        withEmptyRefs.background('朋友'),
      );
    });
  });

  group('构造注入（knowledgeBase 可选注入）', () {
    test('不传：字段为 null，行为与接入前一致（旧构造方逐参兼容）', () {
      final session = CaptureSession(
        config: ValueNotifier<JevConfig>(JevConfig()),
        relationship: ValueNotifier<String>('朋友'),
        overlayEnabled: ValueNotifier<bool>(true),
      );
      expect(session.knowledgeBase, isNull);
      session.dispose();
    });

    test('传入：同一份 KbStore 引用被会话只读持有', () {
      final store = KbStore();
      final session = CaptureSession(
        config: ValueNotifier<JevConfig>(JevConfig()),
        relationship: ValueNotifier<String>('朋友'),
        overlayEnabled: ValueNotifier<bool>(true),
        knowledgeBase: store,
      );
      expect(session.knowledgeBase, same(store));
      session.dispose();
    });
  });
}
