import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 守住「哪段正文进提示词」这件事 —— 对照旧仓库 `core/kb/StyleSourceTest.kt`。
///
/// 重点不是 StyleSource 自己好不好看，而是它和**改造前那行代码**逐字等价：
/// 起草与复查原来各写了一遍
/// `persona?.trim().takeUnless { isNullOrBlank() } ?: style`，现在两处都走这里。
/// 等价性用 [legacy] 当对照物写死 —— 以后谁想「顺手 trim 一下专家正文」，
/// 提示词的字节会变，这里立刻红。
void main() {
  /// 改造前的原文表达式，只作对照，不参与生产。
  String legacy(String expert, String? persona) {
    final t = persona?.trim();
    return (t == null || t.isEmpty) ? expert : t;
  }

  const cases = <(String, String?)>[
    ('专家正文', null),
    ('专家正文', ''),
    ('专家正文', '   '),
    ('专家正文', '\n\t '),
    ('专家正文', '对这个人客气点'),
    ('专家正文', '  对这个人客气点  '),
    ('', null),
    ('', ''),
    ('', '只有联系人'),
    ('   ', null),
    ('   ', ''),
    ('带尾随空格的正文 ', null),
    (' 带前导空格的正文', null),
    ('多行\n正文', null),
    ('含\u001e分隔符', null),
  ];

  group('StyleSource.resolve', () {
    test('text 与改造前那行代码逐字等价', () {
      for (final (expert, persona) in cases) {
        expect(
          StyleSource.resolve(expert, persona).text,
          legacy(expert, persona),
          reason: 'expert=[$expert] persona=[$persona]',
        );
      }
    });

    test('专家正文不 trim', () {
      // 目录里有正文带尾随空格；trim 一下提示词就变了，而「换了风格回复不变」
      // 是最难查的一类回归 —— 它不报错，只是静默等价。
      expect(StyleSource.resolve('带尾随空格的正文 ', null).text,
          '带尾随空格的正文 ');
      expect(StyleSource.resolve(' 带前导空格的正文', null).text,
          ' 带前导空格的正文');
    });

    test('联系人专用人设压过专家正文', () {
      final r = StyleSource.resolve('专家正文', '对这个人客气点');
      expect(r.text, '对这个人客气点');
      expect(r.from, StyleSourceFrom.contact);
      expect(r.shadowed, isTrue);
      expect(r.shadowedExpert, '专家正文');
    });

    test('联系人写的是空白时回落到专家正文', () {
      for (final blank in const ['', '   ', '\n\t ']) {
        final r = StyleSource.resolve('专家正文', blank);
        expect(r.text, '专家正文', reason: '[$blank]');
        expect(r.from, StyleSourceFrom.expert);
        expect(r.shadowed, isFalse);
      }
    });

    test('联系人那句话会被 trim', () {
      expect(StyleSource.resolve('专家正文', '  对这个人客气点  ').text,
          '对这个人客气点');
    });

    test('两边都空时没有人设', () {
      final r = StyleSource.resolve('', null);
      expect(r.text, '');
      expect(r.from, StyleSourceFrom.none);
      expect(r.shadowed, isFalse);
    });

    test('没有专家正文时谈不上被盖住', () {
      // 用户没套用过专家，只在联系人里写了人设：这不是「专家没生效」。
      final r = StyleSource.resolve('', '只写了联系人');
      expect(r.text, '只写了联系人');
      expect(r.shadowed, isFalse);
      expect(r.shadowedExpert, '');
    });

    test('专家正文只剩空白时也谈不上被盖住', () {
      // 界面拿 shadowed 决定要不要多讲一句「专家没生效」：空白的专家正文
      // 不是被盖住，不误报。
      final r = StyleSource.resolve('   ', '联系人');
      expect(r.from, StyleSourceFrom.contact);
      expect(r.shadowed, isFalse);
    });

    test('被盖住的专家正文原样保留', () {
      // 界面只拿它判断「有没有」，不改写、不进提示词。
      final r = StyleSource.resolve(' 专家 ', '联系人');
      expect(r.shadowedExpert, ' 专家 ');
      expect(r.text, '联系人');
    });

    test('解析结果能直接喂给人设卡', () {
      // 下游是 PersonaCard.parse(text)：解析不能抛，结构化与否都不影响消费。
      for (final (expert, persona) in cases) {
        final r = StyleSource.resolve(expert, persona);
        final card = PersonaCard.parse(r.text);
        expect(card.raw, r.text, reason: 'expert=[$expert] persona=[$persona]');
      }
    });
  });
}
