import 'kb_models.dart';
import 'persona_card.dart';

/// 人设主题 ↔ 知识库的联动规则。
///
/// 用户的诉求原话是「我设置里面先选择人设，比如网调人设，然后这个时候加载
/// 我给你的那些知识库里面的内容」。这句话落到代码里是两件事：
///
///  1. 人设卡里的 `主题` 声明**这是哪个领域**（网调 / 装修 / 带娃）；
///  2. 只有标了这个主题的笔记参与检索 —— 于是**换人设就等于换知识库**。
///
/// 规则写成一个类、而不是散在界面里和检索里，是因为界面要**预告**检索会取
/// 哪些笔记（「参与检索 679 / 679 条」）。两边必须是同一条规则，否则预告就是
/// 骗人的。
abstract final class TopicScope {
  /// 当前人设卡的主题；没填人设、或人设没写 `主题` 键时为空白。
  static String topicOfStyle(String style) =>
      PersonaCard.parse(style).topic.trim();

  /// 按主题收窄候选笔记。
  ///
  /// 两条**退回全库**的路，都是有意的：
  ///  - [topic] 为空：用户没填人设（也是老行为），知识库照旧全量参与；
  ///  - [topic] 非空但一条都没标：用户刚写了个新主题、笔记还没打标，这时收窄
  ///    只会让知识库**突然闭嘴** —— 那比"两个领域混着用"更坏。
  /// 只有真的命中过，收窄才生效。
  static List<Note> narrow(List<Note> notes, String topic) {
    final hit = _tagged(notes, topic);
    return hit.isEmpty ? notes : hit;
  }

  /// 供界面预告用：收窄后有多少条、总共多少条、收窄到底生没生效。
  static Scope scopeOf(List<Note> notes, String topic) {
    final t = topic.trim();
    final matched = _tagged(notes, t).length;
    return Scope(
      topic: t,
      matched: matched,
      total: notes.length,
      active: t.isNotEmpty && matched > 0,
    );
  }

  /// 给笔记补上主题标签（不重复加、不改动其它标签）。
  ///
  /// 导入时自动打标用的是它，界面上的「补标」按钮用的也是它 —— 一条已经属于
  /// 「网调」的笔记再补一次必须原样返回，否则 repeated 补标会把标签越攒越多。
  static Note tagged(Note note, String topic) {
    final t = topic.trim();
    if (t.isEmpty) return note;
    if (note.tags.any((tag) => tag.trim().toLowerCase() == t.toLowerCase())) {
      return note;
    }
    return note.copyWith(tags: [...note.tags, t]);
  }

  static List<Note> _tagged(List<Note> notes, String topic) {
    final t = topic.trim();
    if (t.isEmpty) return const [];
    return notes
        .where((n) => n.tags.any((tag) => tag.trim().toLowerCase() == t.toLowerCase()))
        .toList();
  }
}

/// 一次作用域判定的结果。
///
/// [active] 为 false 意味着这轮按全库检索，界面必须照实说，不能让用户以为
/// 自己选了主题、实际没生效。
class Scope {
  const Scope({
    required this.topic,
    required this.matched,
    required this.total,
    required this.active,
  });

  /// 当前人设卡的主题；空白表示这份人设没有指定领域。
  final String topic;
  final int matched;
  final int total;
  final bool active;
}
