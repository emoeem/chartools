import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// A3 说话方式画像的挑选规则 —— 与 docs/p0-plan.md「A3 说话方式画像
/// few-shot」一节对照。
///
/// 断言把当前的评分行为钉死（混合长度挑中位、口语密度排序、命令句/复读
/// 剔除、条数上限分工）：谁调整语气词表或权重，这里的期望值会立刻红，
/// 提醒他把计划里「长度中位、口语密度、非命令复读」三条标准重新对一遍。
void main() {
  // 固定池：一条对方发言（应被忽略）、一条单字应答（太短）、三条中位附近
  // 的口语发言（8/10/12 字）、一条 200 字离群长文。字数中位 = 12。
  List<Msg> mixedPool() => <Msg>[
        const Msg(side: 'other', text: '今天去不去'),
        const Msg(side: 'me', text: '嗯'),
        const Msg(side: 'me', text: '完全不想动啊今天'),
        const Msg(side: 'me', text: '我觉得这事儿有点悬啊'),
        const Msg(side: 'me', text: '算了就这样吧我也懒得管了'),
        Msg(side: 'me', text: '长' * 200),
      ];

  group('buildStyleSamples 正例', () {
    test('混合长度里挑中位附近、口语密度高的，长文落选', () {
      final notes = buildStyleSamples(mixedPool());

      expect(notes, hasLength(3));
      // 排序钉死：中位附近且口语密度最高的第一；200 字长文离中位最远，
      // 连前 3 都进不了。
      expect(notes.map((n) => n.content).toList(), [
        '我觉得这事儿有点悬啊', // 10 字，密度 0.5
        '算了就这样吧我也懒得管了', // 12 字 = 中位，密度 0.25
        '完全不想动啊今天', // 8 字，密度 0.125
      ]);
      expect(notes.map((n) => n.content), isNot(contains('长' * 200)));
      expect(notes.first.id, 'style_sample_0');
      expect(notes.map((n) => n.id).toSet().length, notes.length);
    });

    test('包成的 Note 带齐 style_sample 类型与固定题头', () {
      final notes = buildStyleSamples(mixedPool());

      for (final n in notes) {
        expect(n.type, noteTypeStyleSample);
        expect(n.title, '我的说话方式样例');
        expect(n.enabled, isTrue);
        expect(n.alwaysOn, isFalse);
        // 内容是原文，不截断——5000 字上限是 knowledgeBlock 的事。
        expect(n.content, isNot(contains('…')));
      }
    });

    test('同一份输入重复调用结果完全一致（确定性）', () {
      final a = buildStyleSamples(mixedPool());
      final b = buildStyleSamples(mixedPool());

      expect(a.map((n) => n.id).toList(), b.map((n) => n.id).toList());
      expect(
          a.map((n) => n.content).toList(), b.map((n) => n.content).toList());
    });

    test('混在里面的命令句被剔除，口语发言照常入选', () {
      final notes = buildStyleSamples([
        const Msg(side: 'me', text: '帮我查一下天气'),
        const Msg(side: 'me', text: '今天这天气简直离谱'),
        const Msg(side: 'me', text: '帮我写一份总结'),
        const Msg(side: 'me', text: '算了随便吃点吧'),
      ]);

      expect(notes.map((n) => n.content).toSet(),
          {'今天这天气简直离谱', '算了随便吃点吧'});
    });

    test('短促命令剔除、短应答保留', () {
      final notes = buildStyleSamples([
        const Msg(side: 'me', text: '快点'), // 短促命令
        const Msg(side: 'me', text: '好的好的'), // 应答
        const Msg(side: 'me', text: '闭嘴'), // 短促命令
        const Msg(side: 'me', text: '随便你吧'), // 口语
      ]);

      expect(notes.map((n) => n.content).toSet(), {'好的好的', '随便你吧'});
    });

    test('复读的同文只算一次（含尾随空格的变体）', () {
      final notes = buildStyleSamples([
        const Msg(side: 'me', text: '我觉得这事儿有点悬啊'),
        const Msg(side: 'me', text: '我觉得这事儿有点悬啊 '),
        const Msg(side: 'me', text: '算了就这样吧我也懒得管了'),
      ]);

      expect(notes, hasLength(2));
      expect(notes.map((n) => n.content).toSet().length, 2);
    });
  });

  group('条数参数', () {
    final pool = <Msg>[
      for (var i = 0; i < 8; i++)
        Msg(side: 'me', text: '这事儿我觉得有点悬啊$i吧'),
    ];

    test('默认 max=3，与 knowledgeBlock 的每轮 3 条对齐', () {
      expect(buildStyleSamples(pool), hasLength(3));
    });

    test('max 可调到 5；超出 5 的按计划上限砍回', () {
      expect(buildStyleSamples(pool, max: 5), hasLength(5));
      expect(buildStyleSamples(pool, max: 99), hasLength(5));
    });

    test('max=0 表示明确不要样例，返回空表', () {
      expect(buildStyleSamples(pool, max: 0), isEmpty);
    });
  });

  group('不足与降级', () {
    test('空输入返回空表', () {
      expect(buildStyleSamples(const []), isEmpty);
    });

    test('没有 me 侧发言返回空表', () {
      expect(buildStyleSamples([
        const Msg(side: 'other', text: '在吗'),
        const Msg(side: 'other', text: '出来吃饭'),
      ]), isEmpty);
    });

    test('合格发言不足两条返回空表（空白行不计）', () {
      expect(buildStyleSamples([
        const Msg(side: 'me', text: '行吧那就这样'),
        const Msg(side: 'me', text: '   '),
      ]), isEmpty);
      expect(
        buildStyleSamples([const Msg(side: 'me', text: '行吧那就这样')]),
        isEmpty,
      );
    });

    test('全是命令句时降级为空表，不硬凑', () {
      final notes = buildStyleSamples([
        const Msg(side: 'me', text: '帮我写一份周报'),
        const Msg(side: 'me', text: '总结一下上面的内容'),
        const Msg(side: 'me', text: '翻译成英文'),
        const Msg(side: 'me', text: '闭嘴'),
      ]);

      expect(notes, isEmpty);
    });
  });

  group('与 knowledgeBlock 的衔接', () {
    test('产出的 Note 原样进 <user_style_examples>，不二次截断', () {
      final notes = buildStyleSamples(mixedPool());
      final ctx = ChatContext(notes: [
        ...notes,
        const Note(id: 'addr', title: '称呼', content: '叫我小陈'),
      ]);

      final block = ReplyPrompt.knowledgeBlock('朋友', ctx, 0);
      expect(block, contains('<user_style_examples>'));
      for (final n in notes) {
        expect(block, contains(n.content));
      }
    });

    test('给满 5 条时通道仍只引用 3 条——上限在那边，不在这边重复', () {
      final pool = <Msg>[
        for (var i = 0; i < 8; i++)
          Msg(side: 'me', text: '这事儿我觉得有点悬啊$i吧'),
      ];
      final notes = buildStyleSamples(pool, max: 5);
      expect(notes, hasLength(5));

      final ctx = ChatContext(notes: [
        ...notes,
        const Note(id: 'addr', title: '称呼', content: '叫我小陈'),
      ]);
      final block = ReplyPrompt.knowledgeBlock('朋友', ctx, 0);

      expect('<user_style_examples>'.allMatches(block).length, 3);
      expect(block, isNot(contains(notes[3].content)));
      expect(block, isNot(contains(notes[4].content)));
    });
  });
}
