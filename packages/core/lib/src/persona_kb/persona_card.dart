import 'dart:convert';

/// A persona note (a contact's persona, or the global config fallback),
/// optionally written as a small key/value card:
///
/// ```
/// 称呼：先生
/// 关系：主奴
/// 语气：克制、短句，不解释
/// 语域：亲密
/// 硬边界：不要提家人、不要留痕
/// 避谈：稳赚
/// 安全词：红灯
/// 示例：
/// 我：今天想你了
/// 对方：嗯，等着
/// ```
///
/// Why a card rather than free text: the reply prompt's register bans (no
/// role-play lines, no 「主人」/「爸爸」/「殿下」) exist because an unbanned drafter
/// once answered a flirting thread with "主人不要伤害我？". Those bans must not be
/// liftable by accident, so they go away ONLY when this card carries an
/// explicit `语域`/`register` key that asks for it. Everything the card writes
/// down is also the source of truth for SafetyGate's hard limits.
///
/// Backwards compatible by construction: text with no recognised key parses to
/// `structured == false` and [promptText] returns it verbatim — byte-for-byte
/// what the app sent before cards existed.
///
/// The field set follows the parts of the Character Card V2 spec that map onto
/// this app (description / personality / scenario / example dialogue /
/// boundary instructions). `{{user}}` / `{{char}}` example lines are accepted
/// so a card copied from that ecosystem parses.
class PersonaCard {
  const PersonaCard({
    this.raw = '',
    this.address = '',
    this.relation = '',
    this.tone = '',
    this.scene = '',
    this.topic = '',
    this.boundaries = const [],
    this.avoid = const [],
    this.safeword = '',
    this.yellow = '',
    this.examples = const [],
    this.extra = const [],
    this.registerOpen = false,
    this.structured = false,
  });

  /// Kept verbatim, so a free-form note round-trips unchanged.
  final String raw;
  final String address;
  final String relation;
  final String tone;
  final String scene;

  /// 这几段对话在聊什么（「主题：网调」）。
  ///
  /// 和 [scene] 分开是因为两者要治的病不一样：`情境` 说的是「此刻在什么场合」，
  /// `主题` 说的是「这件事整体属于哪一类」。`主题` 会逐字进提示词，用来把回复
  /// 钉在这个领域上。
  final String topic;

  /// Hard limits, already split and expanded — see [_splitBoundaries].
  final List<String> boundaries;

  /// 避谈词：**不许出现在我的回复里**，但和 [boundaries] 是两种东西——
  /// 硬边界是「对方一提就停整轮」（SafetyGate 逐字拦对方的消息），避谈只是
  /// 约束我方措辞（比如销售的「稳赚」「保证收益」）。混在一个键里时，避谈词会
  /// 被当成硬边界去拦对方——恰好在最需要回复的一轮把候选掐掉。
  final List<String> avoid;
  final String safeword;

  /// 交通灯里的黄灯：对方打出时要**减速确认**，不是停止——红灯仍然只归
  /// [safeword]。
  final String yellow;
  final List<String> examples;
  final List<String> extra;

  /// An explicit opt-in to the register the default prompt bans. False for a
  /// free-form note: free text may never open it, only a recognised key.
  final bool registerOpen;

  /// False for free text: nothing was recognised, so nothing may be lifted.
  final bool structured;

  /// What the drafting prompt is handed as the user's persona. Free text comes
  /// back verbatim; a card comes back as a delimited block so the model can
  /// tell the fields apart.
  String promptText() {
    if (!structured) return raw.trim();
    final sb = StringBuffer('<persona_card>\n');
    if (address.isNotEmpty) sb.write('称呼：$address\n');
    if (relation.isNotEmpty) sb.write('关系：$relation\n');
    if (tone.isNotEmpty) sb.write('语气：$tone\n');
    if (topic.isNotEmpty) {
      sb.write('主题：$topic（这段对话整体就在这个领域里：回复要具体到这个语境的规矩、'
          '步骤和说法，不要给脱离语境的通用安慰或说明书式的建议）\n');
    }
    if (scene.isNotEmpty) sb.write('情境：$scene\n');
    if (registerOpen) {
      sb.write('语域：已按人设卡放开（可在本卡约定范围内使用角色化称呼与描写）\n');
    }
    if (boundaries.isNotEmpty) {
      sb.write('硬边界（这些内容绝不可以出现在回复里）：${boundaries.join('、')}\n');
    }
    if (avoid.isNotEmpty) {
      sb.write('避谈（这些词不要出现在我的回复里，也不许换种说法向对方许诺；'
          '对方主动提到时照常回应这件事，只是不替对方展开、不顺着写）：'
          '${avoid.join('、')}\n');
    }
    if (safeword.isNotEmpty) sb.write('安全词：$safeword\n');
    if (yellow.isNotEmpty) {
      sb.write('黄灯：$yellow（对方打出黄灯时这一轮要先减速确认：接住对方、降低强度、'
          '确认状态和边界，不要加码或开启新动作；黄灯不是停止，停止只归安全词）\n');
    }
    if (examples.isNotEmpty) {
      sb.write('示例（这是我本人真实的说话风格，只学语气和称呼，不是当前对话内容）：\n');
      for (final e in examples) {
        sb.write('$e\n');
      }
    }
    if (extra.isNotEmpty) sb.write('补充：${extra.join('；')}\n');
    sb.write('</persona_card>');
    return sb.toString();
  }

  /// True when the card carries anything a draft could act on.
  bool hasContent() => structured || raw.trim().isNotEmpty;

  /// Recognised keys, normalised (case-folded, `-`/`_`/spaces removed). Both
  /// Chinese and English spellings so a Card V2-style note works unchanged.
  static final Map<String, String> _keyAliases = () {
    const pairs = <String, List<String>>{
      'address': ['称呼', '称谓', 'address', 'title'],
      'relation': ['关系', '身份', 'relation', 'relationship', 'role'],
      'tone': ['语气', '口吻', '风格', 'tone', 'style'],
      'scene': ['情境', '场景', '设定', 'scene', 'scenario', 'setting'],
      'topic': ['主题', '领域', '话题', 'topic', 'domain', 'subject'],
      'boundaries': ['边界', '硬边界', '底线', '禁忌', 'limits', 'hardlimits', 'limit'],
      'avoid': ['避谈', '回避', 'avoid'],
      'safeword': ['安全词', 'safeword'],
      'yellow': ['黄灯', 'yellow'],
      'extra': ['补充', '其他', '备注', 'extra', 'note', 'notes'],
      // Not a value: the example dialogue is picked up by line prefix below.
      // Listing it here only stops a bare 「示例：」 header from ending up in 补充.
      'examples': ['示例', '例子', 'example', 'examples'],
      'register': ['语域', '模式', 'register', 'mode'],
    };
    final m = <String, String>{};
    pairs.forEach((field, keys) {
      for (final k in keys) {
        m[_norm(k)] = field;
      }
    });
    return m;
  }();

  /// A boundary phrase is stripped of these to get a matchable keyword.
  // "不" sits last on purpose: alternation is tried left to right, so writing
  // it first would strip the "不" off "不要提家人" and leave "要提家人".
  // With it last, the bare negations users actually write ("不提家人",
  // "不聊前任") still reduce to the word the gate has to match.
  static final RegExp _boundaryPrefix =
      RegExp(r'^(不要|不准|不能|禁止|不许|不想|不接受|别|不)');
  static final RegExp _boundaryVerb = RegExp(r'^(叫我|喊我|说|提|碰|发|让|聊|做)');

  static const List<String> _registerOff = ['不开', '关闭', '禁用', '关掉', '默认', 'off'];
  static const List<String> _registerOn = [
    '亲密', '角色', '扮演', 'roleplay', 'intimate', 'bdsm', '调教', '文爱', '开放', '开启',
  ];

  static const List<String> _examplePrefix = [
    '我：', '我:', '对方：', '对方:', '他：', '他:', '她：', '她:', '{{user}}', '{{char}}',
  ];

  /// Never throws and never returns a null-structured card: a note that cannot
  /// be understood is a free-form note, which is the pre-card behaviour.
  static PersonaCard parse(String? raw) {
    final text = (raw ?? '').replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.trim().isEmpty) return PersonaCard(raw: text);

    final scalars = <String, String>{};
    final boundaries = <String>[];
    final avoid = <String>[];
    final examples = <String>[];
    final extra = <String>[];

    for (final line in text.split('\n')) {
      final t = line.trim();
      if (t.isEmpty || t == '---') continue;
      if (_examplePrefix.any(t.startsWith)) {
        examples.add(t);
        continue;
      }
      final cut = _splitKeyValue(t);
      if (cut == null) {
        extra.add(t);
        continue;
      }
      final field = _keyAliases[_norm(cut.$1)];
      if (field == null) {
        extra.add(t);
        continue;
      }
      final value = cut.$2.trim();
      switch (field) {
        case 'boundaries':
          boundaries.addAll(_splitBoundaries(value));
        case 'avoid':
          avoid.addAll(_splitBoundaries(value));
        case 'register':
          scalars[field] = value;
        case 'examples':
          break;
        default:
          final existing = scalars[field];
          scalars[field] =
              (existing == null || existing.isEmpty) ? value : '$existing $value';
      }
    }

    // A recognised *key* is what makes this a card. Example lines alone are
    // not enough, or a free-form note that happens to contain "我：..." would
    // silently change shape.
    final structured =
        scalars.isNotEmpty || boundaries.isNotEmpty || avoid.isNotEmpty;
    if (!structured) return PersonaCard(raw: text);

    return PersonaCard(
      raw: text,
      address: scalars['address'] ?? '',
      relation: scalars['relation'] ?? '',
      tone: scalars['tone'] ?? '',
      topic: scalars['topic'] ?? '',
      scene: scalars['scene'] ?? '',
      boundaries: boundaries,
      avoid: avoid,
      safeword: scalars['safeword'] ?? '',
      yellow: scalars['yellow'] ?? '',
      examples: examples,
      extra: extra,
      registerOpen: _registerOpen(scalars['register'] ?? ''),
      structured: true,
    );
  }

  /// `称呼：先生` / `address: sir` — a key must be short and at the line start.
  static (String, String)? _splitKeyValue(String line) {
    final cn = line.indexOf('：');
    final en = line.indexOf(':');
    final at = cn < 0 ? en : (en < 0 ? cn : (cn < en ? cn : en));
    if (at <= 0 || at > 12) return null;
    final key = line.substring(0, at).trim();
    if (key.isEmpty || (key.contains(' ') && key.length > 6)) return null;
    return (key, line.substring(at + 1));
  }

  /// Splits a limits line, then expands each phrase down to its keyword.
  static List<String> _splitBoundaries(String value) {
    if (value.trim().isEmpty) return const [];
    final out = <String>{};
    for (final part
        in value.split(RegExp('[、,，;；/| \\n]+'))) {
      final t = part.trim();
      if (t.length < 2) continue;
      out.add(t);
      var v = t;
      final p = _boundaryPrefix.firstMatch(v);
      if (p != null) {
        v = v.substring(p.end);
        if (v.length >= 2) out.add(v);
      }
      final verb = _boundaryVerb.firstMatch(v);
      if (verb != null) {
        v = v.substring(verb.end);
        if (v.length >= 2) out.add(v);
      }
    }
    return out.toList();
  }

  /// The explicit switch. Negatives are checked first because Chinese "不开"
  /// contains the "开" that would otherwise read as a yes.
  static bool _registerOpen(String value) {
    final s = value.trim().toLowerCase();
    if (s.isEmpty) return false;
    if (_registerOff.any(s.contains)) return false;
    if (s == '开' || s == 'on' || s == 'yes' || s == 'true') return true;
    return _registerOn.any(s.contains);
  }

  static String _norm(String key) => key
      .trim()
      .toLowerCase()
      .replaceAll('-', '')
      .replaceAll('_', '')
      .replaceAll(' ', '');

  /// JSON round trip（app 侧保存人设卡用）。
  Map<String, dynamic> toJson() => {
        'raw': raw,
        'address': address,
        'relation': relation,
        'tone': tone,
        'scene': scene,
        'topic': topic,
        'boundaries': boundaries,
        'avoid': avoid,
        'safeword': safeword,
        'yellow': yellow,
        'examples': examples,
        'extra': extra,
        'registerOpen': registerOpen,
        'structured': structured,
      };

  factory PersonaCard.fromJson(Map<String, dynamic> j) => PersonaCard(
        raw: j['raw'] as String? ?? '',
        address: j['address'] as String? ?? '',
        relation: j['relation'] as String? ?? '',
        tone: j['tone'] as String? ?? '',
        scene: j['scene'] as String? ?? '',
        topic: j['topic'] as String? ?? '',
        boundaries: (j['boundaries'] as List<dynamic>? ?? const [])
            .cast<String>(),
        avoid: (j['avoid'] as List<dynamic>? ?? const []).cast<String>(),
        safeword: j['safeword'] as String? ?? '',
        yellow: j['yellow'] as String? ?? '',
        examples: (j['examples'] as List<dynamic>? ?? const []).cast<String>(),
        extra: (j['extra'] as List<dynamic>? ?? const []).cast<String>(),
        registerOpen: j['registerOpen'] as bool? ?? false,
        structured: j['structured'] as bool? ?? false,
      );
}

/// 把 PersonaCard 编码进日志或调试输出（忽略原文，只给关键字段）。
String describeCard(PersonaCard card) =>
    jsonEncode(card.toJson()..remove('raw'));
