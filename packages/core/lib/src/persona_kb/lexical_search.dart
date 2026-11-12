/// 词法检索（BM25 超越版）—— 思路来自旧仓库 `core/retrieve/LexicalSearch.kt`，
/// 在三处超越 legacy：
///
///  1. **单字 + 二元组粗分词**：legacy 只切 Han 二元组，单字查询（如「机」）
///     切不出任何 token、永远空手而归；这里 Han 单字也成词，单字查询可命中。
///  2. **per-term 得分分解**：legacy 只回总分；每篇命中带 [TermContribution]
///     列表（tf / idf / 分项得分），「为什么命中」可追溯（来源追踪的一半）。
///  3. **命中评测钩子**：调用方把人工确认的相关 id 传入 [LexicalSearch.search]
///     的 `relevantIds`，评测器输出 precision@k / recall@k —— 后续数据说话
///     再决定是否升级向量检索，而不是拍脑袋。
///
/// 零依赖：无分词库、无模型、无字典。个人知识库是几十到几百条笔记，每次检索
/// 对候选文档线性重分词就是正确的形状（与 legacy 同判）；换缓存得引入失效管理，
/// 这个量级不值得。
library;

import 'dart:math' as math;

/// BM25 饱和 / 长度归一化常数（标准取值，与 legacy 一致）。公开给评测器复算。
const double bm25K1 = 1.2;
const double bm25B = 0.75;

/// 功能字停用表 —— 沿用 legacy LexicalSearch.kt 的字符级思路：含功能字的 Han
/// 二元组是语法不是主题（「我其」「有点」跨词界，「其实」是虚词），只在**查询**
/// 侧过滤、文档侧保留 —— 文档里的垃圾二元组只有查询点名才会抬分。刻意字符级
/// 而非语料级：语料级「高频即停用」会把罕见但切题的词一起删掉（legacy 实测
/// 翻过的车），而这里的失败方向相反 —— 罕见跨词界垃圾被 IDF 奖励成最高分。
const String lexicalStopChars = '的了是我你他她它们不在这有就都也吗呢吧啊哦嗯呀哈哇嘛'
    '和与跟对把被给让从到会要能可什么怎因所以但而且或如'
    '若虽然却之其没过多着来去做说想还再又才只很太个些样'
    '谁哪啥得地时候现上下里中前后一二三四五六七八九十';

final Set<String> _stopChars = lexicalStopChars.split('').toSet();

/// 参与检索的一份文档。[id] 是业务主键（如 Note.id），调用方保证唯一；
/// [tags] 与 [type] **不参与打分**，只参与过滤（见 [LexicalSearch.search] 的
/// anyTag / anyType）。
class LexDoc {
  const LexDoc({
    required this.id,
    required this.text,
    this.tags = const [],
    this.type = '',
  });

  final String id;
  final String text;
  final List<String> tags;
  final String type;
}

/// 一个词项对总分值的贡献 —— 「为什么命中」的最小单位。
class TermContribution {
  const TermContribution({
    required this.term,
    required this.tf,
    required this.idf,
    required this.score,
  });

  final String term;

  /// 该文档中此词项出现次数。
  final int tf;

  /// 逆文档频率 ln(1 + (N - df + 0.5) / (df + 0.5))。
  final double idf;

  /// 分项得分 = idf * tf * (k1 + 1) / (tf + k1 * (1 - b + b * len / avg))。
  /// 一篇文档全部分项之和恰等于该文档的 [ScoredDoc.score]。
  final double score;
}

/// 一篇文档的检索得分。[terms] 按分项贡献降序 —— 最能解释命中的词排最前。
class ScoredDoc {
  const ScoredDoc({
    required this.index,
    required this.id,
    required this.score,
    required this.terms,
  });

  /// 在传入文档列表中的下标（指向原始列表，与过滤无关）。
  final int index;

  /// 业务主键，透传 [LexDoc.id]。
  final String id;
  final double score;
  final List<TermContribution> terms;
}

/// 命中评测结果 —— 仅当调用方传入 `relevantIds` 才产出（[LexSearchResult.eval]）。
class RetrievalEval {
  const RetrievalEval({
    required this.k,
    required this.relevantTotal,
    required this.relevantInTopK,
    required this.hitsReturned,
    required this.precisionAtK,
    required this.recallAtK,
    required this.hitIsRelevant,
  });

  /// 请求的截断数。
  final int k;

  /// 人工标注的相关文档总数。
  final int relevantTotal;

  /// top-k 里命中的相关数。
  final int relevantInTopK;

  /// 实际返回的命中数（≤ k；命中不足 k 时调用方可据此自行换算教科书口径
  /// P@k = relevantInTopK / k）。
  final int hitsReturned;

  /// precision@k。分母刻意取**实际命中数**而非 k：库里只有两条相关时，
  /// 除以 k 会把完美召回错报成低分；要教科书口径就用上面的公开字段自己算。
  final double precisionAtK;

  /// recall@k = relevantInTopK / relevantTotal。
  final double recallAtK;

  /// 与 [LexSearchResult.hits] 一一对应的逐命中相关性。
  final List<bool> hitIsRelevant;
}

/// 一次检索的结果：命中列表 best-first；传了 relevantIds 时附带评测。
class LexSearchResult {
  const LexSearchResult({required this.hits, required this.eval});

  final List<ScoredDoc> hits;
  final RetrievalEval? eval;
}

/// BM25 词法检索。全部静态，无状态。
class LexicalSearch {
  LexicalSearch._();

  /// Han 字形判定：CJK 统一表意 + 扩展 A + 兼容表意（legacy 同范围）。
  static bool isHan(int rune) =>
      (rune >= 0x4E00 && rune <= 0x9FFF) ||
      (rune >= 0x3400 && rune <= 0x4DBF) ||
      (rune >= 0xF900 && rune <= 0xFAFF);

  static bool _isAsciiWordChar(int rune) =>
      (rune >= 0x30 && rune <= 0x39) || // 0-9
      (rune >= 0x41 && rune <= 0x5A) || // A-Z
      (rune >= 0x61 && rune <= 0x7A); // a-z

  /// 分词：Han 单字 + 相邻 Han 重叠二元组；ASCII 字母数字连续段一枚小写
  /// token；其余皆分隔符。二元组重叠是有意的：「知识库」切成 知识/识库，
  /// 无论查询从哪半边记起都能接上；单字是为了一字查询不再空手（超越 legacy）。
  static List<String> tokenize(String text) {
    final out = <String>[];
    final word = StringBuffer();
    var prevHan = false;
    var lastHan = 0;

    void flushWord() {
      if (word.isNotEmpty) {
        out.add(word.toString().toLowerCase());
        word.clear();
      }
    }

    for (final rune in text.runes) {
      if (_isAsciiWordChar(rune)) {
        // 拉丁段只在进入/离开时 flush，否则每个字母都会被拆成单字 token。
        word.writeCharCode(rune);
        prevHan = false;
      } else if (isHan(rune)) {
        flushWord();
        out.add(String.fromCharCode(rune)); // 单字
        if (prevHan) {
          out.add(String.fromCharCodes([lastHan, rune])); // 重叠二元组
        }
        lastHan = rune;
        prevHan = true;
      } else {
        flushWord();
        prevHan = false;
      }
    }
    flushWord();
    return out;
  }

  /// 查询侧噪音判定：功能字单字，或含功能字的 Han 二元组。只过滤查询不过滤
  /// 文档（文档里的垃圾二元组不点名就抬不了分）。
  static bool isNoise(String term) {
    if (term.isEmpty) return false;
    if (term.length == 1) {
      final rune = term.runes.first;
      return isHan(rune) && _stopChars.contains(term);
    }
    if (term.length != 2) return false;
    final a = term.codeUnitAt(0);
    final b = term.codeUnitAt(1);
    return isHan(a) &&
        isHan(b) &&
        (_stopChars.contains(String.fromCharCode(a)) ||
            _stopChars.contains(String.fromCharCode(b)));
  }

  /// 对 [docs] 按 [query] 打 BM25 分，best-first 返回 top-[k]。
  ///
  ///  - [minScore]：低于此分的文档不出场，调用方可以问「有没有命中」而不是
  ///    拿到一份按存储序排列的假排名。
  ///  - [anyTag] / [anyType]：检索范围过滤，OR 语义（命中任一 tag / 任一
  ///    type 即入围）；空/null 不设限。被过滤掉的文档不参与 df 统计 ——
  ///    看不见的文档不该稀释 idf。
  ///  - [relevantIds]：人工确认的相关文档 id（评测钩子）。传入则结果带
  ///    [RetrievalEval]（precision@k / recall@k），不传则 eval 为 null。
  static LexSearchResult search(
    String query,
    List<LexDoc> docs, {
    int k = 5,
    double minScore = 0.0,
    Iterable<String>? anyTag,
    Iterable<String>? anyType,
    Set<String>? relevantIds,
  }) {
    final hits = <ScoredDoc>[];

    final Set<String> tagFilter;
    if (anyTag == null) {
      tagFilter = const <String>{};
    } else {
      tagFilter = Set<String>.of(anyTag);
    }
    final Set<String> typeFilter;
    if (anyType == null) {
      typeFilter = const <String>{};
    } else {
      typeFilter = Set<String>.of(anyType);
    }

    final candidates = <int>[];
    for (var i = 0; i < docs.length; i++) {
      final d = docs[i];
      if (tagFilter.isNotEmpty && !d.tags.any(tagFilter.contains)) {
        continue;
      }
      if (typeFilter.isNotEmpty && !typeFilter.contains(d.type)) {
        continue;
      }
      candidates.add(i);
    }

    if (candidates.isNotEmpty && k > 0) {
      final rawTerms = tokenize(query).toSet().toList();
      final filtered = [for (final t in rawTerms) if (!isNoise(t)) t];
      // 字符级停用表对真词有误伤（「一个」「会议」只是恰好含功能字）。短查询
      // 没有冗余词可回退：滤到全空时退回原词。单字+二元组下 1~2 个 Han 字的
      // 查询至多 3 个 token，所以阈值是 3（legacy 二元组-only 时代是 2）。
      final terms =
          (filtered.isEmpty && rawTerms.length <= 3) ? rawTerms : filtered;

      if (terms.isNotEmpty) {
        final docsTokens = [for (final c in candidates) tokenize(docs[c].text)];
        final n = docsTokens.length;
        final avg = docsTokens.fold<int>(0, (sum, t) => sum + t.length) / n;
        if (avg > 0) {
          final tfMaps = [for (final tokens in docsTokens) _tfMap(tokens)];

          // df 只在候选范围内统计。
          final df = <String, int>{};
          for (final term in terms) {
            var seen = 0;
            for (final m in tfMaps) {
              if (m.containsKey(term)) seen++;
            }
            df[term] = seen;
          }

          for (var c = 0; c < n; c++) {
            if (docsTokens[c].isEmpty) continue;
            final tf = tfMaps[c];
            var score = 0.0;
            final contribs = <TermContribution>[];
            for (final term in terms) {
              final termTf = tf[term];
              if (termTf == null || termTf == 0) continue;
              final d = df[term] ?? 0;
              final idf = math.log(1.0 + (n - d + 0.5) / (d + 0.5));
              final denom = termTf +
                  bm25K1 *
                      (1.0 - bm25B + bm25B * docsTokens[c].length / avg);
              final part = idf * (termTf * (bm25K1 + 1.0)) / denom;
              score += part;
              contribs.add(TermContribution(
                term: term,
                tf: termTf,
                idf: idf,
                score: part,
              ));
            }
            if (score > minScore) {
              // per-term 分解按贡献降序：最能解释命中的词排最前。
              contribs.sort((a, b) => b.score.compareTo(a.score));
              hits.add(ScoredDoc(
                index: candidates[c],
                id: docs[candidates[c]].id,
                score: score,
                terms: contribs,
              ));
            }
          }
        }
      }
    }

    hits.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      // 同分按原始下标，保证排序确定性（可对拍）。
      return byScore != 0 ? byScore : a.index.compareTo(b.index);
    });
    if (hits.length > k) hits.removeRange(k, hits.length);

    return LexSearchResult(
      hits: hits,
      eval: relevantIds == null ? null : _evaluate(hits, k, relevantIds),
    );
  }

  static Map<String, int> _tfMap(List<String> tokens) {
    final m = <String, int>{};
    for (final t in tokens) {
      m[t] = (m[t] ?? 0) + 1;
    }
    return m;
  }

  static RetrievalEval _evaluate(
    List<ScoredDoc> hits,
    int k,
    Set<String> relevantIds,
  ) {
    final flags = [for (final h in hits) relevantIds.contains(h.id)];
    var inTop = 0;
    for (final f in flags) {
      if (f) inTop++;
    }
    // 分母取实际命中数（hits 已截断到 k），口径见 [RetrievalEval.precisionAtK]。
    final precision = hits.isEmpty ? 0.0 : inTop / hits.length;
    final recall = relevantIds.isEmpty ? 0.0 : inTop / relevantIds.length;
    return RetrievalEval(
      k: k,
      relevantTotal: relevantIds.length,
      relevantInTopK: inTop,
      hitsReturned: hits.length,
      precisionAtK: precision,
      recallAtK: recall,
      hitIsRelevant: flags,
    );
  }
}
