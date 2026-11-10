import '../persona_kb/persona_card.dart';

/// A pre-flight check on what the *other person* just wrote, run before any
/// API call. Three outcomes:
///
/// - allow (nothing to say),
/// - allow with a [Verdict.caution], which rides into the drafting prompt,
/// - [Verdict.blockReason], which stops the round and is shown to the user.
///
/// Deliberately conservative where being wrong is expensive and narrow where it
/// is not. "对方才15岁，想玩文爱" must block; a passing "未成年" in a message about
/// a game must not, which is why minor signals block only when the same thread
/// also carries intimate/role-play content. Free-text notes are not scanned —
/// only the hard limits the user wrote into their persona card, because
/// inventing limits for the user would just make the assistant refuse to help.
abstract final class SafetyGate {
  static const List<String> _illegalWords = [
    '强奸', '迷奸', '迷药', '下药', '偷拍', '勒索', '拐卖', '未成年性',
  ];

  static const List<String> _selfHarmWords = [
    '自杀', '自残', '割腕', '上吊', '跳楼', '安眠药',
  ];

  static const List<String> _minorWords = [
    '未成年', '小学生', '初中生', '高中生', '初一', '初二', '初三',
    '高一', '高二', '高三', '未满18', '未满十八', 'child', 'minor',
  ];

  /// A bare age, checked against 18 rather than pattern-matched per age.
  static final RegExp _age = RegExp(r'(\d{1,2})\s*(?:周?岁)');

  static const List<String> _intimateWords = [
    '文爱', '网调', '调教', '情趣', '主人', '奴隶', '性爱', '性欲', '性感', '性关系',
    '做爱', '上床', '裸', '情色', '色情', '舔', '爱抚', '亲我', '摸我', '睡我', '跪下',
  ];

  static const List<String> _coercionWords = [
    '强迫', '逼我', '威胁', '不情愿', '不愿意', '不同意', '醉', '喝多', '意识不清',
  ];

  /// Where the other person currently is. A scene that happens in a corridor, a
  /// stairwell or a car park is not the same as one behind a locked door, and
  /// the material in the role-play suite is explicit that planning for
  /// "someone walks past" is the dominant's job, not the submissive's.
  static const List<String> _placeWords = [
    '楼道', '走廊', '楼梯', '门外', '门口', '外面', '户外', '室外', '阳台', '天台',
    '公共', '电梯', '停车场', '公园', '街上', '路上', '车里', '公司', '教室', '宿舍',
  ];

  /// A boundary that is about *where* she is: only then is a place worth
  /// warning about.
  static const List<String> _placeBoundaryHints = [
    '有人', '别人', '公共', '安全', '露出', '外面', '户外', '楼道', '走廊', '门口', '窗户',
  ];

  /// A limit said another way.
  ///
  /// Boundaries are matched literally against the other side's words, and the
  /// settings hint tells the user to write the word itself. That holds right up
  /// to the moment the other person paraphrases: "不要留痕" is not matched by
  /// "我想把你刚说的那些录下来，就我自己留着", and the round drafted anyway —
  /// every candidate said yes. So for the families where a paraphrase is easy
  /// and the cost of missing it is high, the boundary is also matched against
  /// the move it is really about.
  static const List<BoundaryKind> _boundaryKinds = [
    BoundaryKind(
      name: '留痕',
      hints: ['留痕', '留存', '录音', '录像', '拍照', '照片', '截图', '存档', '备份'],
      reaches: [
        '录', '拍', '截图', '照片', '备份', '存档', '保存', '留着', '收好', '私藏', '删掉记录',
      ],
    ),
  ];

  static final RegExp _safewordSplit = RegExp(r'[/、,，;；|]+');
  static final RegExp _whitespace = RegExp(r'\s+');

  /// The agreed stop words, split on the separators a card actually uses
  /// (`红灯/黄灯`, `红灯、黄灯`) and flattened so spacing or punctuation inside a
  /// line cannot hide them.
  static List<String> safeWords(PersonaCard? card) =>
      _splitWords(card?.safeword);

  /// The agreed yellow-light words ([PersonaCard.yellow]): a signal to slow
  /// down and check in, NOT to stop — red keeps that job.
  static List<String> slowWords(PersonaCard? card) => _splitWords(card?.yellow);

  static List<String> _splitWords(String? raw) => (raw ?? '')
      .trim()
      .split(_safewordSplit)
      .map(flatten)
      .where((w) => w.isNotEmpty)
      .toList();

  static String flatten(String text) =>
      text.toLowerCase().replaceAll(_whitespace, '');

  /// A boundary of the given family, plus the paraphrase that reached it.
  static (BoundaryKind, String)? paraphrasedBoundary(
    String lower,
    PersonaCard? card,
  ) {
    final boundaries = card?.boundaries ?? const <String>[];
    if (boundaries.isEmpty) return null;
    for (final boundary in boundaries) {
      final written = boundary.toLowerCase();
      final kind = _boundaryKinds
          .where((k) => k.hints.any(written.contains))
          .firstOrNull;
      if (kind == null) continue;
      if (kind.reaches.any(lower.contains)) return (kind, boundary);
    }
    return null;
  }

  /// A place worth a caution — but only when the user's own card already says
  /// her being somewhere public is a limit. Otherwise this would chirp at every
  /// ordinary "我在路上".
  static String? riskyPlace(String lower, PersonaCard? card) {
    final place = _placeWords.where(lower.contains).firstOrNull;
    if (place == null) return null;
    final declared = (card?.boundaries ?? const <String>[])
        .any((b) => _placeBoundaryHints.any(b.contains));
    return declared ? place : null;
  }

  /// [otherLines]: everything the other side said in the visible window. A side
  /// the capture step could not attribute must be included here too: "maybe the
  /// other person" is not a reason to skip the check.
  static Verdict check(List<String> otherLines, PersonaCard? card) {
    final text = otherLines.where((l) => l.trim().isNotEmpty).join('\n');
    if (text.trim().isEmpty) return const Verdict();
    final lower = text.toLowerCase();

    final illegal = _find(lower, _illegalWords);
    if (illegal != null) {
      return Verdict(
          blockReason: '对方这条里有涉嫌违法的内容「$illegal」。这类内容我不给候选。');
    }
    final selfHarm = _find(lower, _selfHarmWords);
    if (selfHarm != null) {
      return Verdict(
        blockReason: '对方这条里有自伤或自杀的字眼「$selfHarm」。这超出回复助手能处理的'
            '范围，我不给候选——先确认对方人是不是安全的。',
      );
    }

    // The stop word the two of them agreed on, before the softer heuristics
    // below. Once it has been said the scene is over: it stays a stop for the
    // rest of the visible window, because "she called it and then the
    // conversation moved on" is exactly the case where a draft does harm.
    final flat = flatten(text);
    final safeword = safeWords(card).where(flat.contains).firstOrNull;
    if (safeword != null) {
      return Verdict(
        blockReason: '对方这条里出现了你们约好的安全词「$safeword」。按约定这一刻要停下来，'
            '我不给候选——先确认对方的状态，别再往下推这一场。',
      );
    }

    final minor = _find(lower, _minorWords) ??
        _age.firstMatch(text)?.let((m) {
          final age = int.tryParse(m.group(1) ?? '');
          return (age != null && age < 18) ? m.group(0) : null;
        });
    final intimate = _find(lower, _intimateWords);
    if (minor != null && intimate != null) {
      return Verdict(
        blockReason: '对方这条同时出现了未成年人信号「$minor」和亲密或角色内容「$intimate」。'
            '涉及未成年人的这类内容我不给候选。',
      );
    }

    // The user's own hard limits, as written in the persona card.
    // 本地不能自带 firstOrNull(test) 扩展：库内扩展会压过 dart:core 的
    // firstOrNull getter，所有无参调用点全被解析成方法 tear-off。这里改成
    // where(...).firstOrNull，与 SDK 3.0 内置的语义一致。
    final boundary = (card?.boundaries ?? const <String>[])
        .where((b) => b.trim().isNotEmpty && lower.contains(b.toLowerCase()))
        .firstOrNull;
    if (boundary != null) {
      return Verdict(
        blockReason: '对方这条碰到了你写下的硬边界「$boundary」。按你的设定我不出候选，'
            '你可以自己回，或者去改联系人设定。',
      );
    }

    final cautions = <String>[];
    // 黄灯：约定里的减速信号。放在 caution 列表第一位——它比地点/换说法提醒
    // 更优先，因为这是双方明说过的约定，而下面的都只是启发式。
    final yellow = slowWords(card).where(flat.contains).firstOrNull;
    if (yellow != null) {
      cautions.add('对方打出了你们约好的黄灯信号「$yellow」。按约定这一刻要减速：先接住对方'
          '说的，降低强度，确认对方的状态和边界；不要加码、不要开启新的动作，也不要当成'
          '安全词把这一场直接停掉——停止只归红灯。');
    }
    final paraphrase = paraphrasedBoundary(lower, card);
    if (paraphrase != null) {
      final (kind, b) = paraphrase;
      cautions.add('对方碰到了你写下的硬边界「$b」，只是换了个说法（${kind.name}这一类）。'
          '这一条在这一点上只能拒绝或者先停下来确认：不要答应、不要给替代方案、'
          '不要换话题绕开。');
    }
    final place = riskyPlace(lower, card);
    if (place != null) {
      cautions.add('对方现在人可能在公共或半公共的地方（「$place」）。先确认环境——有没有别人、'
          '能不能马上回来——并给她留好退路，再谈指令。');
    }
    if (minor != null) {
      cautions.add('出现了未成年人信号「$minor」，先确认年龄再往下走');
    }
    final coercion = _find(lower, _coercionWords);
    if (coercion != null) {
      cautions.add('出现了「$coercion」，确认这是双方自愿、不是被推着走');
    }
    return Verdict(caution: cautions.join('；'));
  }

  static String? _find(String lower, List<String> words) =>
      words.where(lower.contains).firstOrNull;
}

/// [blockReason] non-null means do not draft; [caution] non-blank rides in the
/// prompt.
class Verdict {
  const Verdict({this.blockReason, this.caution = ''});

  final String? blockReason;
  final String caution;

  bool get blocked => blockReason != null;
}

/// A boundary of the given family, plus the paraphrase that reaches it.
class BoundaryKind {
  const BoundaryKind({required this.name, required this.hints, required this.reaches});
  final String name;
  final List<String> hints;
  final List<String> reaches;
}

extension on RegExpMatch {
  R? let<R>(R? Function(RegExpMatch) f) => f(this);
}
