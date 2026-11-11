import 'dart:math' as math;

/// 一条 AI 腔特征的命中记录：哪条规则（[rule]）、在文本里看到了什么（[evidence]）。
class FlavorHit {
  const FlavorHit(this.rule, this.evidence);

  /// 规则 id，取值见 [AiFlavorLinter] 的各 `ruleXxx` 常量。
  final String rule;

  /// 证据：命中的原文片段或计数描述。给人看，也供出错时定位。
  final String evidence;

  @override
  bool operator ==(Object other) =>
      other is FlavorHit && other.rule == rule && other.evidence == evidence;

  @override
  int get hashCode => Object.hash(rule, evidence);

  @override
  String toString() => 'FlavorHit($rule: $evidence)';
}

/// 中文 AI 腔本地 linter（p0-plan 人味增强包 A2）。
///
/// 纯规则、零模型调用：每条特征都是确定性判定，输入不变输出就不变。特征清单
/// 按规格取聊天域子集（参照 cn-humanizer / qu-ai-wei 的中文 AI 腔特征）：
/// 排比堆叠、总结升华尾句、书面语高频词、「不是…而是…」句式、句长方差过小
/// （整组）、每条都以问号结尾（整组）、emoji/语气词滥用。
///
/// 两层入口：
///  - [lint] 查一条文本自己的特征；
///  - [lintGroup] 查一组候选——整组特征（长度过度均匀、每条问号结尾）只有把
///    几条放在一起才看得出来，命中时挂在**每一条**上（每条都是这个「整齐
///    模子」的一部分）；单条特征照常逐条挂，唯独短于 [_uniformMinLength]
///    的候选整组跳过单条规则（DS-7 短文本早退，见 [lintGroup] 注释）。
///
/// 调用方（`JevClient.draftAndRank`）拿每条候选的命中数做门槛：≥
/// [rewriteThreshold] 条才进 refineReply 重写。单一特征不动手——一次误伤的
/// refine 是真金白银和延迟；两个独立特征叠加才基本坐实「这条像 AI 写的」。
abstract final class AiFlavorLinter {
  /// 排比堆叠：连续 ≥3 个同构短句。
  static const String ruleParallelStack = 'parallel_stack';

  /// 总结升华尾句：「总之 / 说到底」一类收尾。
  static const String ruleSummaryTail = 'summary_tail';

  /// 书面语高频词：「然而 / 因此 / 此外」出现在口语流里。
  static const String ruleWrittenWord = 'written_word';

  /// 「不是…而是…」句式。
  static const String ruleNotBut = 'not_but';

  /// 句长方差过小：整组候选长度过度均匀（整组特征）。
  static const String ruleUniformLength = 'uniform_length';

  /// 每条都以问号结尾（整组特征）。
  static const String ruleAllQuestion = 'all_question';

  /// emoji / 语气词滥用。
  static const String ruleEmojiAbuse = 'emoji_abuse';

  /// 进 refineReply 重写的门槛：一条候选命中的特征数达到它才改写。
  static const int rewriteThreshold = 2;

  /// 排比段里单个短句的长度上限：超过它更像正常行文的长句，不算「短句堆叠」。
  static const int _maxParallelClause = 12;

  /// emoji 或语气词各自达到这个次数算「滥用」。
  static const int _abuseThreshold = 3;

  /// 句长方差过小的门槛：整组每条都不短于这个字数才参与比较——短回复
  /// （「好」「嗯」这类）本来就该差不多长，不在此列。
  static const int _uniformMinLength = 10;

  /// 变异系数（标准差 / 均值）低于它判「过度均匀」。取 0.12：三条 10/11/12 字
  /// 的候选（0.08）算一个模子，10/12/14（0.14）算正常参差。
  static const double _uniformMaxCv = 0.12;

  /// 句读切分：中英文的逗号、顿号、句末标点、省略号、分号、换行都算边界。
  static final RegExp _clauseBreak = RegExp(r'[，,、。！!？?\n；;…]+');

  /// 「不是…而是…」：中间允许逗号停顿（不是我不想帮，而是帮不了），
  /// 不允许跨句（句末标点后另起的话不是同一个句式），跨度上限 24 字防误连。
  static final RegExp _notBut = RegExp(r'不是[^。！!？?\n]{0,24}而是');

  /// emoji 的粗略码段。不含变体选择符 U+FE0F：「❤️」这类组合只数基础字符
  /// 一次，否则一个 emoji 会被计成两个。
  static final RegExp _emoji = RegExp(
      '[\u{1F1E6}-\u{1F1FF}\u{1F300}-\u{1F5FF}\u{1F600}-\u{1F64F}'
      '\u{1F680}-\u{1F6FF}\u{1F900}-\u{1F9FF}\u{1FA00}-\u{1FAFF}'
      '\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{2934}\u{2935}\u{3030}\u{303D}]',
      unicode: true);

  /// 书面语高频词。规格点名「然而/因此/此外」，余下是同一族的常见书面腔；
  /// 刻意不含「不过/可是/所以」——口语里它们完全正常。
  static const List<String> _writtenWords = [
    '然而',
    '因此',
    '此外',
    '与此同时',
    '值得注意的是',
    '不可否认',
    '众所周知',
  ];

  /// 总结升华的收尾标记。出现在**最后一个句读**才算尾句，句中不带。
  static const List<String> _summaryMarkers = [
    '总之',
    '说到底',
    '总而言之',
    '归根结底',
    '归根到底',
    '综上所述',
    '由此可见',
  ];

  /// 句尾语气词。刻意不含 吗/呢/吧/啊——这几个在真人聊天里太常见，算进去
  /// 会把正常语气也判成滥用；「哈」同理（哈哈哈哈是真人笑）。
  static const List<String> _particles = [
    '呀',
    '啦',
    '哦',
    '呗',
    '嘛',
    '哟',
    '咯',
    '喔',
    '哇',
    '捏',
    '嘿',
  ];

  /// 查单条文本的特征（不含整组特征）。返回顺序固定，同一规则至多一条。
  static List<FlavorHit> lint(String text) {
    final hits = <FlavorHit>[];
    final parallel = _parallelStack(text);
    if (parallel != null) hits.add(parallel);
    final tail = _summaryTail(text);
    if (tail != null) hits.add(tail);
    final written = _writtenWord(text);
    if (written != null) hits.add(written);
    final notBut = _notButHit(text);
    if (notBut != null) hits.add(notBut);
    final abuse = _emojiAbuse(text);
    if (abuse != null) hits.add(abuse);
    return hits;
  }

  /// 查一组候选（draftAndRank 的终榜）。返回与 [texts] 等长的命中列表；
  /// 整组特征命中时挂在每一条上。与 [lint] 一样纯函数。
  ///
  /// fix(#8 DS-7) 短文本早退：短于 [_uniformMinLength] 的候选在入口处跳过
  /// 全部单条规则（不切句、不跑正则），只挂整组特征。阈值直接沿用
  /// [_uniformMinLength] 的既有口径——句长方差规则已经把短回复（「好」「嗯」
  /// 这类）排除在判定之外（见其注释），单条规则取同一条线，理由：
  ///  - 低于 10 字的回复不值得为它发一次改写模型调用——[rewriteThreshold]
  ///    门槛设计本来就是省这笔钱，改写一条几个字的短回复更是无从改起；
  ///  - 这是 DS-7 有意的行为口径收窄（<10 字不再上报单条特征），不是纯性能
  ///    重构。这些文本即使凑满 2 条单点命中（最短的组合是 4 字的「总之然而」
  ///    ：summary_tail + written_word），改写也是花真金白银换一句短话。
  /// 整组特征不受影响：每次调用只各扫一遍长度/结尾，本来就轻，且
  /// [_uniformLength] 自带同款短文本早退。单条入口 [lint] 不做早退——它是
  /// 「明确要求判定这一条」的公开 API，语义保持完整；早退只放在消费方
  /// （JevClient.draftAndRank）实际走的批量入口上。
  static List<List<FlavorHit>> lintGroup(List<String> texts) {
    final groupHits = <FlavorHit>[];
    final uniform = _uniformLength(texts);
    if (uniform != null) groupHits.add(uniform);
    final allQ = _allQuestion(texts);
    if (allQ != null) groupHits.add(allQ);
    return [
      for (final t in texts)
        // fix(#8 DS-7) 短文本早退：只挂整组特征，不跑单条规则（阈值口径见
        // 方法注释）。
        if (t.length < _uniformMinLength)
          [...groupHits]
        else
          [...groupHits, ...lint(t)],
    ];
  }

  /// 把命中的规则翻成 refineReply 的改写指令：每条规则一句人话描述。
  /// 指令只说「怎么改」，不引用原文的反例句子——把坏例句放进提示词反而可能
  /// 被模型原样抄回来。
  static String refineInstruction(List<FlavorHit> hits) {
    final advice = <String>[];
    for (final h in hits) {
      final say = switch (h.rule) {
        ruleParallelStack => '别把结构一样的短句连着排比，一句话说一个重点就好',
        ruleSummaryTail => '删掉「总之」「说到底」这类总结腔的收尾，说完该说的就停',
        ruleWrittenWord => '把「然而」「因此」「此外」这类书面词换成平时说话的说法',
        ruleNotBut => '别用「不是…而是…」的对比句式，直接把意思说出来',
        ruleUniformLength => '这条和另外几条长短太齐了，改得有长有短、像随手打的',
        ruleAllQuestion => '别和另外几条一样都用问号收尾，改成有的用陈述句',
        ruleEmojiAbuse => '少堆 emoji 和「呀、啦、哦」这类语气词',
        _ => '',
      };
      if (say.isNotEmpty && !advice.contains(say)) advice.add(say);
    }
    final body = advice.isEmpty ? '' : '：${advice.join('；')}';
    return '去掉 AI 腔，改得更像真人随手打的字$body。意思和事实不变，称呼不变。';
  }

  // ------------------------------------------------------------------ 单条

  /// 排比堆叠：句读切开后，连续 ≥3 个短句同头（前两字相同）或同长。
  /// 两种同构各扫一遍，命中即给证据。
  static FlavorHit? _parallelStack(String text) {
    final clauses = _clauses(text);
    // 同头游程：如「我懂你的累，我懂你的难，我懂你的委屈」。
    final byHead = _uniformRun(
        clauses, (c) => _isShortClause(c) ? c.substring(0, 2) : '');
    if (byHead != null) return byHead;
    // 同长游程：如「早起一杯水，饭后百步走，睡前泡个脚」。
    return _uniformRun(
        clauses, (c) => _isShortClause(c) ? '长度${c.length}' : '');
  }

  /// 短句判据：2–12 字才参与排比。
  static bool _isShortClause(String c) =>
      c.length >= 2 && c.length <= _maxParallelClause;

  /// 找最长的「相邻同键」游程，≥3 才算排比。键函数把短句归一成可比较的键，
  /// 返回空串表示这一条不参与。
  static FlavorHit? _uniformRun(
      List<String> clauses, String Function(String) keyOf) {
    var i = 0;
    while (i < clauses.length) {
      final key = keyOf(clauses[i]);
      if (key.isEmpty) {
        i++;
        continue;
      }
      var j = i + 1;
      while (j < clauses.length && keyOf(clauses[j]) == key) {
        j++;
      }
      final runLen = j - i;
      if (runLen >= 3) {
        final run = clauses.sublist(i, j);
        return FlavorHit(ruleParallelStack, '「${run.join('／')}」$runLen 个同构短句连排');
      }
      i = j;
    }
    return null;
  }

  /// 总结升华尾句：最后一个句读以总结标记开头。
  static FlavorHit? _summaryTail(String text) {
    final clauses = _clauses(text);
    if (clauses.isEmpty) return null;
    final last = clauses.last;
    for (final m in _summaryMarkers) {
      if (last.startsWith(m)) {
        return FlavorHit(ruleSummaryTail, '尾句「$last」用「$m」收尾');
      }
    }
    return null;
  }

  /// 书面语高频词：出现任意一个即命中（短消息里出现一次书面腔已经很扎眼）。
  static FlavorHit? _writtenWord(String text) {
    final found = [for (final w in _writtenWords) if (text.contains(w)) w];
    if (found.isEmpty) return null;
    return FlavorHit(ruleWrittenWord, '书面语高频词：${found.join('、')}');
  }

  /// 「不是…而是…」句式。
  static FlavorHit? _notButHit(String text) {
    final m = _notBut.firstMatch(text);
    if (m == null) return null;
    return FlavorHit(ruleNotBut, '句式「${m.group(0)}」');
  }

  /// emoji / 语气词滥用：两者各自达到 [_abuseThreshold] 就算。
  static FlavorHit? _emojiAbuse(String text) {
    final emojiCount = _emoji.allMatches(text).length;
    final particles = <String>[];
    for (final p in _particles) {
      final n = p.allMatches(text).length;
      for (var i = 0; i < n; i++) {
        particles.add(p);
      }
    }
    if (emojiCount < _abuseThreshold && particles.length < _abuseThreshold) {
      return null;
    }
    final parts = <String>[
      if (emojiCount >= _abuseThreshold) 'emoji 出现 $emojiCount 次',
      if (particles.length >= _abuseThreshold)
        '语气词「${particles.join()}」出现 ${particles.length} 次',
    ];
    return FlavorHit(ruleEmojiAbuse, parts.join('；'));
  }

  // ------------------------------------------------------------------ 整组

  /// 句长方差过小：≥3 条候选、每条都不短于 [_uniformMinLength]，且长度的变异
  /// 系数低于 [_uniformMaxCv]。命中时每条候选各挂一条（每条都是模子的一部分）。
  static FlavorHit? _uniformLength(List<String> texts) {
    if (texts.length < 3) return null;
    final lens = [for (final t in texts) t.length];
    if (lens.any((l) => l < _uniformMinLength)) return null;
    final mean = lens.fold<int>(0, (a, b) => a + b) / lens.length;
    final variance = lens.fold<double>(
            0, (a, l) => a + (l - mean) * (l - mean)) /
        lens.length;
    final cv = math.sqrt(variance) / mean;
    if (cv >= _uniformMaxCv) return null;
    return FlavorHit(
        ruleUniformLength, '${texts.length} 条候选长度 ${lens.join('/')}，过度均匀');
  }

  /// 每条都以问号结尾：≥2 条候选全部以 ？/? 收尾才判——单条用问号是正常语气，
  /// 整组清一色问号才是模子。
  static FlavorHit? _allQuestion(List<String> texts) {
    if (texts.length < 2) return null;
    final every = texts.every((t) {
      final s = t.trim();
      return s.endsWith('？') || s.endsWith('?');
    });
    if (!every) return null;
    return FlavorHit(ruleAllQuestion, '${texts.length} 条候选都以问号结尾');
  }

  /// 按句读切开并去掉空段。
  static List<String> _clauses(String text) => [
        for (final c in text.split(_clauseBreak))
          if (c.trim().isNotEmpty) c.trim(),
      ];
}
