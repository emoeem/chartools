/// G7 反馈学习（结构化个人表达偏好）。
///
/// 用户对候选回复标注「太正式 / 太热情 / 不够直接 / 事实对但表达不合适 /
/// 不该承诺 / 这类先问我」后，这里把它们累积成可持久化的结构化记录
/// （docs/p0-plan.md「G7 反馈学习结构化」）。四条设计边界来自 p0-plan 的
/// 核心原则，改代码前后都要对着检查：
///
///  1. 反馈是结构化的（每类一个计数 + 最近样例），不是往提示词里拼一句话；
///     [styleAddendum] 输出的每一句都能在 [PreferenceTag] 的字段里找到出处。
///  2. 用户可查看/修改/删除：计数与样例全部可读（[count]/[examplesOf]/[tags]），
///     [clear]/[clearAll] 随时删掉，删除后持久化里也不再出现。
///  3. 候选原文**只存本地给用户看，永不进提示词**。候选文本来自模型输出、
///     间接来自聊天内容，属不可信数据（G6 信任边界）；[styleAddendum] 因此
///     只写「次数 + 方向」，不引用任何一条 [record] 传进来的原文——这也是
///     「浏览信息与进提示词的正文分离」在本类里的落点。
///  4. 不覆盖人设与事实记忆：本类是独立对象，不写 PersonaCard/Ledger/联系人
///     资料；G8 的「确认后入库」由 app 侧负责，与本类无关。
///
/// 方向短语（[PreferenceTag.direction]）是用户标注本身的直译，六个常量全部
/// 写死在枚举里、可逐字审阅——模型不参与措辞，所以这里没有「编造规则」的
/// 通道。
///
/// 本包不落盘：[toJson] 交给 app 层存（shared_preferences/文件均可），
/// [fromJson] 容错解析——坏档降级成空档案或丢字段，绝不抛异常打断 UI
/// （与 ledger.dart 的 parse 同一哲学）。
library;

/// 每类标注在本地保留的最近样例条数。样例只为「用户查看自己标记过什么」
/// 服务（原则②），环形保留最近几条即可，避免长期使用后无限膨胀。
const int preferenceExamplesPerTag = 5;

/// [PreferenceProfile.styleAddendum] 的字数上限（runes 计）。六类标注全记满
/// 的自然输出约 130 字，正常到不了这个数；它是安全网，防止将来扩词汇表时
/// 附言悄悄吃掉回复提示词的预算（本任务规格：上限 300 字）。
const int styleAddendumMaxChars = 300;

/// 持久化形状版本。目前只有 v1；app 层落盘时建议连同版本一起存，将来改
/// 形状好做迁移。
const int preferenceProfileVersion = 1;

/// 一类用户标注。六类与 G7 名单逐字对应；[wire] 名即持久化与 UI 用的
/// snake_case 名（`too_formal` 等），改它等于改 JSON 契约。
enum PreferenceTag {
  /// 「太正式」。
  tooFormal('too_formal', '回复偏正式', '应更口语'),

  /// 「太热情」。
  tooEnthusiastic('too_enthusiastic', '过度热情', '应更克制'),

  /// 「不够直接」。
  notDirectEnough('not_direct_enough', '不够直接', '应更直接'),

  /// 「事实对但表达不合适」。
  expressionMismatch('expression_mismatch', '事实对但表达不合适', '应换一种说法'),

  /// 「不该承诺」。
  unwantedCommitment('unwanted_commitment', '出现用户不要的承诺', '不要替用户答应'),

  /// 「这类先问我」。
  askFirst('ask_first', '这类事没先问用户', '先问过用户再写');

  const PreferenceTag(this.wire, this.fact, this.direction);

  /// 持久化与跨端用的稳定名称。
  final String wire;

  /// [styleAddendum] 里的统计事实：只描述「用户标过什么」，不评价对错。
  final String fact;

  /// 该标注隐含的调整方向——用户标注的直译，不是新规则。
  final String direction;

  /// 按持久化名称反查；不认识的名称（旧档/新版本/脏数据）返回 null，
  /// 由调用方决定跳过。
  static PreferenceTag? tryParse(String wire) {
    for (final v in values) {
      if (v.wire == wire) return v;
    }
    return null;
  }
}

/// 结构化个人表达偏好：每类标注一个计数，外加最近几条候选原文（只给用户
/// 看）。用法：候选卡上用户点某类标注 → [record]；设置页展示与删除 →
/// [tags]/[count]/[examplesOf]/[clear]/[clearAll]；起草前 → [styleAddendum]
/// 由 app 侧拼在 `ReplyPrompt.styleBlock` 之后（core 不改 reply_prompt，
/// 这里只产出字符串）。
class PreferenceProfile {
  /// 计数表；只存正数，[clear] 直接移除键。
  final Map<PreferenceTag, int> _counts = {};

  /// 每类最近的候选原文（环形，[preferenceExamplesPerTag] 条）。只进设置页，
  /// 不进 [styleAddendum]。
  final Map<PreferenceTag, List<String>> _examples = {};

  /// 记一次标注。候选原文裁剪后存进环形样例；空/纯空白文本只计数不存样例
  /// （UI 可能只传 tag）。永不抛异常。
  void record(PreferenceTag tag, String candidateText) {
    _counts[tag] = (_counts[tag] ?? 0) + 1;
    final text = candidateText.trim();
    if (text.isEmpty) return;
    final list = _examples.putIfAbsent(tag, () => <String>[])..add(text);
    if (list.length > preferenceExamplesPerTag) {
      list.removeRange(0, list.length - preferenceExamplesPerTag);
    }
  }

  /// 某类标注的累计次数；没有记录返回 0。
  int count(PreferenceTag tag) => _counts[tag] ?? 0;

  /// 某类最近被标记的候选原文（最早的在前）。返回不可变副本，外部改不动
  /// 内部状态。样例只供用户查看，不要把它拼进任何提示词（类注释第 3 条）。
  List<String> examplesOf(PreferenceTag tag) =>
      List.unmodifiable(_examples[tag] ?? const <String>[]);

  /// 有记录的类别，按次数从多到少；平次按枚举声明序——List.sort 不保证
  /// 稳定，顺序必须显式写进比较器，同一份记录永远排出同一顺序（附言截断
  /// 的取舍也按这个顺序）。
  List<PreferenceTag> get tags {
    final list =
        _counts.entries.where((e) => e.value > 0).map((e) => e.key).toList();
    list.sort((a, b) {
      final byCount = count(b).compareTo(count(a));
      return byCount != 0 ? byCount : a.index.compareTo(b.index);
    });
    return list;
  }

  /// 没有任何记录（或全部清空后）为 true——app 层可据此跳过附言拼接与落盘。
  bool get isEmpty => _counts.isEmpty;

  /// 删除一类标注（计数与样例一起删）——「用户可删」的入口之一。
  void clear(PreferenceTag tag) {
    _counts.remove(tag);
    _examples.remove(tag);
  }

  /// 清空全部偏好记录。
  void clearAll() {
    _counts.clear();
    _examples.clear();
  }

  /// 持久化形状（v1）：`{"version":1,"counts":{"too_formal":3},
  /// "examples":{"too_formal":["…"]}}`。键用 [PreferenceTag.wire]；只写出
  /// count>0 的类别，样例只随有计数的类别落盘（不变式：样例 ⊆ 有计数的
  /// 类别，[fromJson] 维持同一不变式）。
  Map<String, dynamic> toJson() => {
        'version': preferenceProfileVersion,
        'counts': {
          for (final e in _counts.entries)
            if (e.value > 0) e.key.wire: e.value,
        },
        'examples': {
          for (final e in _examples.entries)
            if (e.value.isNotEmpty && count(e.key) > 0)
              e.key.wire: List<String>.of(e.value),
        },
      };

  /// 容错解析。不认识的 tag、非正数计数、非字符串样例、没有计数的孤儿样例
  /// 一律跳过；null/空 map/坏类型得到空档案。永不抛异常。
  static PreferenceProfile fromJson(Map<String, dynamic>? json) {
    final profile = PreferenceProfile();
    if (json == null) return profile;

    final counts = json['counts'];
    if (counts is Map) {
      for (final e in counts.entries) {
        final tag = PreferenceTag.tryParse('${e.key}');
        if (tag == null) continue;
        final n = e.value;
        if (n is int && n > 0) profile._counts[tag] = n;
      }
    }

    final examples = json['examples'];
    if (examples is Map) {
      for (final e in examples.entries) {
        final tag = PreferenceTag.tryParse('${e.key}');
        if (tag == null || profile.count(tag) == 0) continue;
        final raw = e.value;
        if (raw is! List) continue;
        final texts = raw
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList();
        if (texts.isEmpty) continue;
        profile._examples[tag] = texts.length > preferenceExamplesPerTag
            ? texts.sublist(texts.length - preferenceExamplesPerTag)
            : texts;
      }
    }
    return profile;
  }

  /// 把结构化偏好翻译成一段事实性风格附言，app 侧拼在
  /// `ReplyPrompt.styleBlock` 之后。单类别时的形状：
  ///
  ///     用户对历史候选的反馈统计：回复偏正式（3 次）——应更口语
  ///
  /// 多类别按 [tags] 顺序（次数降序）用「；」连接。只陈述统计事实与方向
  /// （都是 [PreferenceTag] 字段的直译），不引用候选原文、不编造规则。
  /// 无记录返回空串，调用方据此整段省略（与 ledger.render 同约定）。
  ///
  /// 上限 [styleAddendumMaxChars]（可用 [maxLength] 收紧——测试与调用方
  /// 自律用，不能放宽，计划定死 300 字）。装不下的整行丢弃，其后不再尝试：
  /// 附言按反馈次数从多到少排，留下的是证据最强的一段；也不写「…」截断
  /// 记号，提示词里不留半句话。连第一行都放不下时返回空串。
  String styleAddendum({int maxLength = styleAddendumMaxChars}) {
    final limit = maxLength.clamp(0, styleAddendumMaxChars).toInt();
    final ordered = tags;
    if (limit == 0 || ordered.isEmpty) return '';

    const lead = '用户对历史候选的反馈统计：';
    var out = lead;
    var appended = false;
    for (var i = 0; i < ordered.length; i++) {
      final tag = ordered[i];
      final piece = (i == 0 ? '' : '；') +
          '${tag.fact}（${count(tag)} 次）——${tag.direction}';
      if (_runes(out) + _runes(piece) > limit) break;
      out += piece;
      appended = true;
    }
    return appended ? out : '';
  }
}

/// 按字（Unicode rune）数长度，不按 UTF-16 码元——上限的「字」以 runes 计。
int _runes(String s) => s.runes.length;
