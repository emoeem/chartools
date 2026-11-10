import 'dart:convert';

import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// S1 会话台账 —— 对照旧仓库 `core/kb/LedgerTest.kt` 的思路钉三件事：
///
///  1. 台账会被**当成既定事实**注入提示词，所以模型编出来的东西必须进不来、
///     空字段也不能变成「无」；
///  2. 台账是**增量**重建的（上一版 + 新记录），coveredUntil 不能在往返里丢失
///     —— 丢了就会每轮重扫一遍整段历史；
///  3. 模型的答复不可信（围栏、杂文、截断），解析与净化兜得住所有这些。
///
/// 净化是旧仓库 `LedgerCheck.sanitize` 的**保守子集**（上限与字段数不同）：
/// 这里钉的是 Dart 侧自己的上限——address 80、条目 120、threads/boundaries
/// 各 20 条、terms 50 条（term 60 / value 120）。
void main() {
  Ledger ledger({
    String address = '',
    String relation = '',
    String tone = '',
    List<String> threads = const [],
    List<String> boundaries = const [],
    List<LedgerTerm> terms = const [],
  }) =>
      Ledger(
        address: address,
        relation: relation,
        tone: tone,
        threads: threads,
        boundaries: boundaries,
        terms: terms,
      );

  group('render', () {
    test('空台账渲染为空串，提示词不被污染', () {
      // 调用方据此整段省略，而不是塞一个「（无）」进去。
      expect(ledger().render(), '');
      expect(const Ledger().render(), '');
      // 六个字段全空的答复等于「什么都没整理出来」，不是一份台账。
      expect(
        Ledger.parse(
          '{"address":"","relation":"","tone":"","threads":[],"boundaries":[],"terms":[]}',
          1,
          2,
        ),
        isNull,
      );
    });

    test('每个字段都进渲染块，列表用「；」连接', () {
      final block = ledger(
        address: '他叫我先生，自称小狗',
        relation: '主奴，已经线下见过两次',
        tone: '短句、命令式、带一点哄',
        threads: ['周末的项圈还没挑', '上一条语音还没回'],
        boundaries: ['不提家人', '安全词「红灯」'],
        terms: [const LedgerTerm(term: '项圈', value: '上一轮说好要买的那个')],
      ).render();

      expect(block, contains('【会话台账】'));
      expect(block, contains('- 称呼：他叫我先生，自称小狗'));
      expect(block, contains('- 关系：主奴，已经线下见过两次'));
      expect(block, contains('- 语气基线：短句、命令式、带一点哄'));
      expect(block, contains('- 在办的事：周末的项圈还没挑；上一条语音还没回'));
      expect(block, contains('- 已经明确的边界：不提家人；安全词「红灯」'));
      expect(block, contains('- 固定说法（必须前后一致）：项圈=上一轮说好要买的那个'));
    });

    test('边界行自己声明不能取消硬性禁止，且空字段不渲染', () {
      // 台账里的边界是**从聊天记录里读出来的**，不是用户写的硬边界。注入
      // 提示词时它必须自己说清这一点，否则模型会以为「台账里没写」等于
      // 「可以做」。
      final block = ledger(boundaries: ['不提家人']).render();
      expect(block, contains('取消不了上面的硬性禁止'));
      expect(block, contains('边界只多不少'));
      expect(block, contains('台账里没有的事不要编'));

      // 只有一个字段的台账，其余行整段缺席——不出「称呼：（无）」。
      final onlyAddress = ledger(address: '宝宝').render();
      expect(onlyAddress, contains('- 称呼：宝宝'));
      expect(onlyAddress, isNot(contains('- 关系：')));
      expect(onlyAddress, isNot(contains('- 语气基线：')));
      expect(onlyAddress, isNot(contains('- 在办的事：')));
    });
  });

  group('parse', () {
    test('围栏与前后杂文都不碍事', () {
      const raw = '''
好的，我整理好了：

```json
{"address":"宝宝","relation":"暧昧期","tone":"互相调侃",
 "threads":["约了周五看展"],"boundaries":[],"terms":[]}
```

需要我再补别的吗？
''';
      final l = Ledger.parse(raw, 100, 200);
      expect(l, isNotNull);
      expect(l!.address, '宝宝');
      expect(l.threads, ['约了周五看展']);
      // coveredUntil / builtAt 来自调用方：台账是增量重建的，时间戳丢了
      // 就会每轮重扫整段历史。
      expect(l.coveredUntil, 100);
      expect(l.builtAt, 200);
    });

    test('字符串字面量里的花括号不会让扫描提前收尾', () {
      // 括号计数忽略字符串里的花括号，否则一句「他说{别走}」会切出残缺对象。
      final l = Ledger.parse(
        '{"address":"先生","relation":"他说{别走}这句话","tone":"","threads":[],"boundaries":[],"terms":[]}',
        0,
        0,
      );
      expect(l, isNotNull);
      expect(l!.relation, '他说{别走}这句话');
    });

    test('垃圾输入返回 null 而不是抛进采集路径', () {
      expect(Ledger.parse('', 0, 0), isNull);
      expect(Ledger.parse('我无法完成这个请求。', 0, 0), isNull);
      expect(Ledger.parse('[1,2,3]', 0, 0), isNull);
      expect(Ledger.parse('{这不是 JSON}', 0, 0), isNull);
    });

    test('净化后一无所获也回 null', () {
      // 模型爱把空字段写成「无」「暂无」——空白条目被裁掉之后，剩下的
      // 仍然是一份空台账，不值得注入。
      expect(Ledger.parse('{"address":"  ","threads":["   "]}', 0, 0), isNull);
    });
  });

  group('encode / fromJson 往返', () {
    test('存盘再读回来字段与时间戳都不丢', () {
      final original = ledger(
        address: '先生',
        relation: '主奴',
        tone: '命令式',
        threads: ['挑项圈'],
        boundaries: ['不提家人'],
        terms: [const LedgerTerm(term: '项圈', value: '要买的那个')],
      );
      const coveredUntil = 1700000000123;
      const builtAt = 1700000000999;

      final back = Ledger.fromJson(
        jsonDecode(original.encode()) as Map<String, dynamic>,
        coveredUntil,
        builtAt,
      );

      expect(back.address, original.address);
      expect(back.relation, original.relation);
      expect(back.tone, original.tone);
      expect(back.threads, original.threads);
      expect(back.boundaries, original.boundaries);
      expect(back.terms.length, 1);
      expect(back.terms.first.term, '项圈');
      expect(back.terms.first.value, '要买的那个');
      // coveredUntil 丢了就等于每轮重扫整段历史，这条是「增量」的地基。
      // 它不随 JSON 走：fromJson 由调用方传入（与 parse 的参数一致）。
      expect(back.coveredUntil, coveredUntil);
      expect(back.builtAt, builtAt);
    });

    test('fromJson 对缺键宽容：缺的落回空值', () {
      final l = Ledger.fromJson(const {
        'address': '宝宝',
        'threads': '不是数组',
        'terms': [
          {'term': '代号', 'value': '小夜'},
          '坏元素',
        ],
      }, 5, 6);
      expect(l.address, '宝宝');
      expect(l.relation, '');
      expect(l.threads, isEmpty);
      expect(l.boundaries, isEmpty);
      // 非对象的 term 元素跳过，不炸。
      expect(l.terms.length, 1);
      expect(l.terms.first.term, '代号');
      expect(l.coveredUntil, 5);
      expect(l.builtAt, 6);
    });

    test('toJson 覆盖全部八个字段', () {
      expect(ledger().toJson().keys.toList(), hasLength(8));
    });
  });

  group('sanitize 截断（经 parse 走私有净化）', () {
    test('超长字段截断，列表裁到上限，空白条目丢弃', () {
      final raw = jsonEncode({
        'address': 'a' * 130, // 上限 80
        'threads': [
          for (var i = 1; i <= 25; i++) '事情$i', // 上限 20 条
          '   ', // 空白项先裁掉，不占名额
          '',
        ],
        'boundaries': [for (var i = 1; i <= 25; i++) '边界$i'],
        'terms': [
          for (var i = 1; i <= 55; i++)
            {'term': '词$i', 'value': '值$i'}, // 上限 50 条
        ],
      });

      final l = Ledger.parse(raw, 0, 0);
      expect(l, isNotNull);
      expect(l!.address, hasLength(80));
      expect(l.threads, hasLength(20));
      // 留下的是**最先**的 20 条：净化只裁数量，不重排。
      expect(l.threads.first, '事情1');
      expect(l.threads.last, '事情20');
      expect(l.threads.every((t) => t.trim().isNotEmpty), isTrue);
      expect(l.boundaries, hasLength(20));
      expect(l.terms, hasLength(50));
      expect(l.terms.first.term, '词1');
    });

    test('单条 term/value 也有各自的上限，空 term 或空 value 整条丢弃', () {
      final l = Ledger.parse(
        jsonEncode({
          'terms': [
            {'term': 't' * 80, 'value': 'v' * 130}, // term ≤ 60，value ≤ 120
            {'term': '', 'value': '没有词'},
            {'term': '空值', 'value': '   '},
          ],
        }),
        0,
        0,
      );
      expect(l, isNotNull);
      expect(l!.terms, hasLength(1));
      expect(l.terms.first.term, hasLength(60));
      expect(l.terms.first.value, hasLength(120));
    });
  });
}
