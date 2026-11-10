import '../models/models.dart';
import 'kb_models.dart';

/// 样例笔记共用的题头：界面上好认，提示词里也成一组。
const String styleSampleTitle = '我的说话方式样例';

/// 挑选条数的硬上限。A3 计划定的是 3-5 条；`ReplyPrompt.knowledgeBlock` 一轮
/// 最多引用 3 条 `<user_style_examples>`（reply_prompt.dart 的既有规则），所以
/// [buildStyleSamples] 的默认 max=3 与它对齐——默认不多选引用不走的条目。想
/// 多备几条换着用可以调到 5，再大也砍回 5。分工是：条数截断只在这里发生，
/// 内容截断只在 knowledgeBlock 发生（每条 5000 字），两边不重复干活。
const int styleSamplesHardMax = 5;

/// 合格发言少于这个数不构成「说话方式」：一条只能算孤立表态，成不了画像；
/// 复读判定也需要至少两条互相对照。低于它返回空表。
const int styleSamplesMinPool = 2;

/// 单条超过这个长度按文章/粘贴语料处理，挑选时**整条排除**——这是挑前过滤，
/// 不是截断：选中的样例原文多长给多长，每条 5000 字的引用上限是
/// knowledgeBlock 的既有规则，这里不重复做。聊天里一条近千字的发言多半是
/// 粘贴的段子或文档，拿它教「我怎么说话」会把画像带偏。
const int styleSampleMaxRunes = 1000;

/// 命令句/任务指令的起始词，保守清单。宁可漏放一条口语命令，也不把「别这样
/// 啦」这类正常反应错杀：style_sample 教的是「我怎么说话」，混进指令只会教
/// 模型发号施令——起草提示词里本来就明确说过，自己历史里的指令不要复读。
const List<String> _commandPrefixes = [
  '帮我', '帮忙', '请帮', '请你', '请给我', '给我', '替我', '翻译', '总结',
  '概括', '改写', '润色', '扩写', '续写', '生成', '列出', '列举', '搜索',
  '搜一下', '搜一搜', '查一下', '查查', '查一查', '写一', '回答一下', '告诉我',
  '来一份', '来一个', '来点', '跑一下', '执行',
];

/// 短促命令白名单之外的例外：这些应答/缩写虽然又短又没有语气词，但是正常
/// 回话，不是命令。中文名词（好的/收到/懂了）多半靠语气词和「了/的」兜住，
/// 这里只收兜不住的那几个。
const Set<String> _shortAcks = {
  '收到', '收到收到', '明白', '了解', '晓得', '知道', '好滴', 'ok', 'okk',
  '6', '66', '666', '233', 'hhh', 'hhhh', 'xswl', 'awa',
};

/// 以这些人称开头的短句通常是陈述（「我到了」「你在哪」），不按短促命令算。
const List<String> _pronounStarts = [
  '我', '你', '他', '她', '它', '咱', '俺', '人家', '大家', '我们', '你们', '他们',
];

/// 口语语气词/助词（单字，按出现次数计）。挑的是在书面语里极少出现的字，
/// 「哈」连打会按次数自然多计。
const List<String> _oralParticles = [
  '吧', '呢', '啊', '呀', '啦', '嘛', '哦', '哈', '嘿', '嗯', '哇', '哟', '咯',
  '呗', '唉', '哎', '诶', '喔', '噢', '哒', '嘞', '咩', '啧', '吗',
];

/// 口头禅与口语词组（按出现次数计、每次权重 2——整词命中比单个语气词更能
/// 说明这是「说话」不是「写作」）。刻意不收「搞/整/弄」这类单字：它们在
/// 书面词里也常见，误报会把正式发言错标成口语。
const List<String> _oralPhrases = [
  '我觉得', '我感觉', '我寻思', '好像', '其实', '然后', '就是说', '反正',
  '大概', '估计', '可能', '应该', '说真的', '说实话', '讲真', '咋', '啥',
  '算了', '没事', '随便', '无所谓', '好滴', '好嘞', '得嘞', '笑死', '乐死',
  '绝了', '离谱', '无语', '服了', '有点', '什么', '怎么', '为什么', '干嘛',
  '干啥', '好家伙', '完蛋', '麻了',
];

/// 短促命令判定里「有它就算口语不算命令」的字：全部语气词，外加「了/的」——
/// 「吃了」「你的」是回话不是命令。
final Set<int> _softRunes = _shortRuleSoftChars();

Set<int> _shortRuleSoftChars() {
  final set = <int>{};
  for (final s in _oralParticles) {
    set.add(s.runes.first);
  }
  set
    ..add('了'.runes.first)
    ..add('的'.runes.first);
  return set;
}

/// 没有标点可判（短促命令一般不带标点；带问号的是提问不是命令）。
const String _punctChars = '，。、！？!?.~～…·,:;；：()（）【】[]<>《》—-_/';
final Set<int> _punctRunes = _punctChars.runes.toSet();

final RegExp _whitespace = RegExp(r'\s+');

/// A3 说话方式画像：从用户自己的历史发言里挑「这就是我怎么说话」的
/// few-shot 样例，包成 [noteTypeStyleSample] 类型的 [Note]。
///
/// 输入是历史里的「我」方消息；传整段对话也没关系，非 `side=='me'` 的行会被
/// 忽略（悬浮窗快照与桌面流粘贴文本两种来源都这样喂）。
///
/// 挑选按两条互补的线索打分（各占一半）：
///
///  - **长度接近中位数**：样例要代表典型发言，不是最长的长文，也不是两三个
///    字的应答。中位数取合格池按字数排序的中间值（偶数取右中位）。
///  - **口语密度高**：语气词、口头禅、连打、表情……密度高的更接近「说话」，
///    书面腔的段落教不会模型怎么开口。密度 = 口语信号加权次数 / 字数，封顶 1。
///
/// 两类内容一律不进候选：
///
///  - **命令句**：对 AI 的任务指令（见 [_commandPrefixes]）和四字以内的纯
///    短促命令（过来/闭嘴/快点）；「好的」「我到了」这类应答与陈述不在此列。
///    全部候选都是命令时整个降级为空表，而不是硬凑几条进去。
///  - **复读**：同一句话出现多次只保留首次——刷屏的重复不代表表达方式。
///    判重前折叠空白，不折大小写：中英混排里大小写本身也是表达方式。
///
/// 另外，短于 2 字的单字应答（嗯/哦）教不了风格，也排除。
///
/// **返回空表的情形**（调用方应按「本轮没有可用样例」处理，不要报错）：
///
///  - [myMessages] 为空，或没有任何 `side=='me'` 的非空发言；
///  - 过滤（复读/命令/长度）后剩下的合格发言不足 [styleSamplesMinPool] 条
///    ——「全是命令句」就是在这里降级的；
///  - [max] 被 clamp 后为 0。
///
/// 与 `ReplyPrompt.knowledgeBlock` 的既有规则互补、不重复：那边限「最多
/// 3 条、每条 5000 字」，这边默认 [max]=3 与条数上限对齐，内容一律不截断；
/// 超长候选在挑选时整条排除，选中的原文有多长给多长。
List<Note> buildStyleSamples(List<Msg> myMessages, {int max = 3}) {
  final limit = max.clamp(0, styleSamplesHardMax).toInt();
  if (limit == 0) return const [];

  // 复读判定用的已见集合；index 记原始出现顺序，并列时按它排（List.sort
  // 不保证稳定，必须显式写进比较器，同一份输入才永远选出同一批）。
  final seen = <String>{};
  final pool = <_Candidate>[];
  var index = 0;
  for (final m in myMessages) {
    index++;
    final text = m.text.trim();
    if (m.side != 'me' || text.isEmpty) continue;
    if (!seen.add(text.replaceAll(_whitespace, ' '))) continue;
    final runes = text.runes.length;
    if (runes < 2 || runes > styleSampleMaxRunes) continue;
    if (_isCommandLike(text, runes)) continue;
    pool.add(_Candidate(index, text, runes));
  }

  if (pool.length < styleSamplesMinPool) return const [];

  // 中位数：合格池按字数排序的中间值（偶数取右中位）。pool 里的字数都
  // ≥ 2，除法没有零除风险。
  final lengths = pool.map((c) => c.runes).toList()..sort();
  final median = lengths[lengths.length ~/ 2];

  for (final c in pool) {
    final span = (c.runes - median).abs() / median;
    c.closeness = 1.0 - _clamp01(span);
    c.density = _colloquialDensity(c.text);
    c.score = 0.5 * c.closeness + 0.5 * c.density;
  }

  pool.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.index.compareTo(b.index);
  });

  final notes = <Note>[];
  for (var i = 0; i < limit && i < pool.length; i++) {
    notes.add(Note(
      id: 'style_sample_$i',
      title: styleSampleTitle,
      content: pool[i].text,
      type: noteTypeStyleSample,
    ));
  }
  return notes;
}

/// 是否命令句/任务指令（两种判法，见 [_commandPrefixes] 与短促命令规则）。
bool _isCommandLike(String text, int runes) {
  for (final p in _commandPrefixes) {
    if (text.startsWith(p)) return true;
  }
  if (runes > 4) return false;
  // 短促命令：很短、没有语气词、没有任何标点、不以人称开头——「过来」「
  // 闭嘴」「快点」。 recall 让位给 precision：判不准的（「你过来」）宁可放行。
  if (_shortAcks.contains(text.toLowerCase())) return false;
  for (final p in _pronounStarts) {
    if (text.startsWith(p)) return false;
  }
  final soft = _softRunes.contains;
  if (text.runes.any(soft)) return false;
  final punct = _punctRunes.contains;
  if (text.runes.any(punct)) return false;
  return true;
}

/// 口语密度：口语信号加权次数 / 字数，封顶 1.0。加权只分两档——整词口头禅
/// 记 2、单字语气词/表情/波浪号记 1、同字符连打（哈哈哈、！！！）记 2。
double _colloquialDensity(String text) {
  final total = text.runes.length;
  if (total == 0) return 0;
  var hits = 0.0;
  for (final p in _oralParticles) {
    hits += _countNonOverlapping(text, p);
  }
  for (final p in _oralPhrases) {
    hits += 2 * _countNonOverlapping(text, p);
  }
  for (final r in text.runes) {
    // 增补平面字符基本是 emoji，聊天里带表情本身就是口语信号。
    if (r > 0xFFFF) hits += 1;
    if (r == 0x7E || r == 0xFF5E) hits += 1; // ~ 与 ～
  }
  var run = 1;
  var prev = -1;
  for (final r in text.runes) {
    if (r == prev) {
      run++;
    } else {
      if (run >= 3) hits += 2;
      run = 1;
      prev = r;
    }
  }
  if (run >= 3) hits += 2;
  final d = hits / total;
  return d > 1.0 ? 1.0 : d;
}

/// 统计 [needle] 在 [text] 里不重叠出现的次数。
int _countNonOverlapping(String text, String needle) {
  var count = 0;
  var from = 0;
  while (true) {
    final at = text.indexOf(needle, from);
    if (at < 0) break;
    count++;
    from = at + needle.length;
  }
  return count;
}

double _clamp01(double x) => x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);

/// 一条合格候选及其三项得分。分数在选出中位数后回填。
class _Candidate {
  _Candidate(this.index, this.text, this.runes);

  /// 原始出现顺序（并列时按它排，保证确定性）。
  final int index;
  final String text;
  final int runes;

  double closeness = 0;
  double density = 0;
  double score = 0;
}
