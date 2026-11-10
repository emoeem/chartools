import 'package:chartools_core/chartools_core.dart';
import 'package:test/test.dart';

/// 人设主题 ↔ 知识库联动 —— 对照旧仓库 `core/kb/TopicScopeTest.kt`。
///
/// 这组测试守的是一条**用户看不见**的规则：收窄在什么时候生效、什么时候必须
/// 退回全库。退回的两条路都不是礼貌，是防线——少一条就会让「知识库突然闭嘴」
/// 这种最坏的失败悄悄发生（用户选了主题、笔记还没打标 → 一条笔记都不进提示词，
/// 界面上却什么都没说）。
void main() {
  Note note(String id, [List<String> tags = const []]) =>
      Note(id: id, title: '笔记$id', content: '内容$id', tags: tags);

  group('narrow 收窄', () {
    test('没有主题时不收窄', () {
      final notes = [
        note('a', ['网调']),
        note('b', ['装修'])
      ];
      // 主题为空：用户没填人设（也是老行为），知识库照旧全量参与。
      expect(TopicScope.narrow(notes, ''), same(notes));
      expect(TopicScope.narrow(notes, '   '), same(notes));
    });

    test('主题命中时只留标了这个主题的笔记', () {
      final notes = [
        note('a', ['网调']),
        note('b', ['装修']),
        note('c', ['文档导入', '网调']),
      ];
      final kept = TopicScope.narrow(notes, '网调');
      expect(kept.map((n) => n.id).toList(), ['a', 'c']);
    });

    test('主题一条都没标过时必须退回全库', () {
      // 最坏的一种失败：用户刚写了「主题：带娃」，笔记还没打标。这时收窄
      // 会把整个知识库关掉——比两个领域混着用坏得多，所以必须退回全库。
      final notes = [
        note('a', ['网调']),
        note('b')
      ];
      expect(TopicScope.narrow(notes, '带娃'), same(notes));
    });

    test('标签匹配忽略大小写与首尾空白', () {
      final notes = [
        note('a', [' BDSM ']),
        note('b', ['网调'])
      ];
      expect(TopicScope.narrow(notes, 'bdsm').map((n) => n.id).toList(), ['a']);
    });
  });

  group('scopeOf 预告', () {
    test('空主题不激活', () {
      final notes = [
        note('a', ['网调']),
        note('b', ['装修'])
      ];
      final scope = TopicScope.scopeOf(notes, '');
      expect(scope.topic, '');
      expect(scope.active, isFalse);
      expect(scope.total, 2);
    });

    test('命中时 active 且给出命中数', () {
      final notes = [
        note('a', ['网调']),
        note('b', ['装修']),
        note('c', ['文档导入', '网调']),
      ];
      final scope = TopicScope.scopeOf(notes, '网调');
      expect(scope.topic, '网调');
      expect(scope.active, isTrue);
      expect(scope.matched, 2);
      expect(scope.total, 3);
    });

    test('未命中也必须如实说没生效', () {
      // active=false 意味着这轮按全库检索，界面必须照实说「这轮仍按全部
      // N 条检索」，不能让用户以为自己选了主题、实际没生效。
      final notes = [
        note('a', ['网调']),
        note('b')
      ];
      final scope = TopicScope.scopeOf(notes, '带娃');
      expect(scope.topic, '带娃');
      expect(scope.active, isFalse);
      expect(scope.matched, 0);
      expect(scope.total, 2);
    });

    test('大小写命中的标签同样算 active', () {
      final notes = [
        note('a', [' BDSM '])
      ];
      expect(TopicScope.scopeOf(notes, 'bdsm').active, isTrue);
      expect(TopicScope.scopeOf(notes, '网调').active, isFalse);
    });
  });

  group('tagged 补标', () {
    test('补上主题标签且不改动其它标签', () {
      final a = note('a', ['文档导入', 'book.pdf']);
      final once = TopicScope.tagged(a, '网调');
      expect(once.tags, ['文档导入', 'book.pdf', '网调']);
      // 原笔记不动：补标返回新实例。
      expect(a.tags, ['文档导入', 'book.pdf']);
    });

    test('重复补标幂等：标签不能越攒越多', () {
      // 导入时自动打标用的是它，界面上的「补标」按钮用的也是它——
      // 那个按钮可以连点。
      final a = note('a', ['文档导入', 'book.pdf']);
      final once = TopicScope.tagged(a, '网调');
      expect(TopicScope.tagged(once, '网调').tags, once.tags);
    });

    test('大小写不同的同主题同样幂等', () {
      // 已标「bdsm」再补「BDSM」是同一个主题，不许存出第二个标签。
      final a = note('a', ['bdsm']);
      expect(TopicScope.tagged(a, 'BDSM').tags, ['bdsm']);
    });

    test('空主题不动任何东西', () {
      final a = note('a', ['文档导入']);
      expect(TopicScope.tagged(a, '').tags, ['文档导入']);
      expect(TopicScope.tagged(a, '   ').tags, ['文档导入']);
    });
  });

  group('topicOfStyle', () {
    test('主题键读出主题，自由文本与空串都是空白', () {
      // 人设卡里的「主题」声明这是哪个领域；换人设就等于换知识库。
      expect(TopicScope.topicOfStyle('称呼：叫我主人\n主题：网调\n语气：短句'), '网调');
      expect(TopicScope.topicOfStyle('我们在暧昧期，喜欢互怼'), '');
      expect(TopicScope.topicOfStyle(''), '');
      expect(TopicScope.topicOfStyle('主题：   '), '');
    });
  });
}
