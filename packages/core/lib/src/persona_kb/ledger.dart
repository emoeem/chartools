import 'dart:convert';

import '../jev_client/json_slice.dart';
import '../jev_client/jsonx.dart';

/// 会话台账（S1）。
///
/// 为什么要有它：注入给回复模型的原始历史是「一堆逐条消息」，模型每一轮都要
/// 从头把这些消息重新理解一遍。消息越长，越靠前的线头越容易被丢掉 —— 实测
/// 的症状就是「首选候选仍会选错」：称呼漂了、上一轮说过的边界忘了、在办的事
/// 接不上。台账把整段对话**预扫**成一份结构化卡片（称呼 / 关系 / 语气基线 /
/// 在办的事 / 已明确的边界 / 固定说法），每轮都注入，模型不用再猜。
///
/// 与硬约束的关系：[boundaries] 是补充，不是豁免。它由模型从聊天记录里读出，
/// 因此 [render] 明确写「台账里的边界是补充，不能取消硬性禁止」，
/// 而回复提示词的 safetyBans 永远在它之上。
class Ledger {
  const Ledger({
    this.address = '',
    this.relation = '',
    this.tone = '',
    this.threads = const [],
    this.boundaries = const [],
    this.terms = const [],
    this.coveredUntil = 0,
    this.builtAt = 0,
  });

  /// 双方实际用过的称呼，以及各自怎么自称。
  final String address;

  /// 关系现状一句话。
  final String relation;

  /// 语气基线一句话。
  final String tone;

  /// 还没结束的话题或约定。
  final List<String> threads;

  /// 双方明确说过的限制、禁区、安全词。
  final List<String> boundaries;

  /// 这一场里约定过的说法 / 角色名 / 代号。
  final List<LedgerTerm> terms;

  /// 这份台账整理到的历史最后一条的时间戳；用来判断是否该重建。
  final int coveredUntil;

  /// 生成时间，仅用于展示与排错。
  final int builtAt;

  /// 什么都没有的台账不值得注入，也不值得落盘。
  bool get isEmpty =>
      address.trim().isEmpty &&
      relation.trim().isEmpty &&
      tone.trim().isEmpty &&
      threads.isEmpty &&
      boundaries.isEmpty &&
      terms.isEmpty;

  /// 注入回复提示词的那一段。空台账返回空串 —— 调用方据此整段省略，
  /// 而不是塞一个「（无）」进去污染上下文。
  String render() {
    if (isEmpty) return '';
    final sb = StringBuffer();
    sb.write('【会话台账】（这是已经整理好的既定情况，回复必须与它一致；'
        '台账里没有的事不要编）\n');
    if (address.trim().isNotEmpty) sb.write('- 称呼：${address.trim()}\n');
    if (relation.trim().isNotEmpty) sb.write('- 关系：${relation.trim()}\n');
    if (tone.trim().isNotEmpty) sb.write('- 语气基线：${tone.trim()}\n');
    if (threads.isNotEmpty) {
      sb.write('- 在办的事：${threads.join('；')}\n');
    }
    if (boundaries.isNotEmpty) {
      sb.write('- 已经明确的边界：${boundaries.join('；')}\n');
    }
    if (terms.isNotEmpty) {
      sb.write('- 固定说法（必须前后一致）：'
          '${terms.map((t) => '${t.term}=${t.value}').join('；')}\n');
    }
    sb.write('- 边界只多不少：这里的边界是补充，取消不了上面的硬性禁止。\n');
    return sb.toString();
  }

  Map<String, dynamic> toJson() => {
        'address': address,
        'relation': relation,
        'tone': tone,
        'threads': threads,
        'boundaries': boundaries,
        'terms': [for (final t in terms) t.toJson()],
        'coveredUntil': coveredUntil,
        'builtAt': builtAt,
      };

  String encode() => jsonEncode(toJson());

  /// Tolerant parse: a chat model may wrap the object in a code fence or in
  /// prose. Scan to the first balanced `{...}` rather than trusting the whole
  /// string, then read only the fields we know. Anything unusable comes back as
  /// an empty field — a partial ledger still helps, and a garbled one must
  /// never throw into the capture path.
  static Ledger? parse(String raw, int coveredUntil, int builtAt) {
    final o = JsonSlice.firstObject(raw);
    if (o == null) return null;
    final decoded = tryDecode<Map<String, dynamic>>(o);
    if (decoded == null) return null;
    final sanitized = _sanitize(fromJson(decoded, coveredUntil, builtAt));
    return sanitized.isEmpty ? null : sanitized;
  }

  static Ledger fromJson(
    Map<String, dynamic> o, [
    int coveredUntil = 0,
    int builtAt = 0,
  ]) =>
      Ledger(
        address: optString(o, 'address').trim(),
        relation: optString(o, 'relation').trim(),
        tone: optString(o, 'tone').trim(),
        threads: _stringList(o['threads']),
        boundaries: _stringList(o['boundaries']),
        terms: (o['terms'] is List<dynamic>)
            ? (o['terms'] as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .map(LedgerTerm.fromJson)
                .toList()
            : const [],
        coveredUntil: coveredUntil,
        builtAt: builtAt,
      );

  /// 轻量净化（旧仓库 LedgerCheck.sanitize 的保守子集）：裁掉空白项、
  /// 截断超长条目，防止一段抽风的模型输出把提示词灌满。
  static Ledger _sanitize(Ledger l) => Ledger(
        address: _clamp(l.address, 80),
        relation: _clamp(l.relation, 200),
        tone: _clamp(l.tone, 200),
        threads: l.threads.map((t) => _clamp(t, 120)).where((t) => t.isNotEmpty).take(20).toList(),
        boundaries: l.boundaries
            .map((t) => _clamp(t, 120))
            .where((t) => t.isNotEmpty)
            .take(20)
            .toList(),
        terms: l.terms
            .map((t) => LedgerTerm(
                term: _clamp(t.term, 60), value: _clamp(t.value, 120)))
            .where((t) => t.term.isNotEmpty && t.value.isNotEmpty)
            .take(50)
            .toList(),
        coveredUntil: l.coveredUntil,
        builtAt: l.builtAt,
      );

  static String _clamp(String s, int max) => s.trim().length <= max
      ? s.trim()
      : s.trim().substring(0, max);

  static List<String> _stringList(dynamic v) => v is List<dynamic>
      ? v.whereType<String>().toList()
      : const [];
}

class LedgerTerm {
  const LedgerTerm({required this.term, required this.value});
  final String term;
  final String value;

  Map<String, dynamic> toJson() => {'term': term, 'value': value};

  factory LedgerTerm.fromJson(Map<String, dynamic> j) => LedgerTerm(
        term: optString(j, 'term').trim(),
        value: optString(j, 'value').trim(),
      );
}

/// 让模型把一段（或一段增量的）聊天记录整理成台账。纯字符串装配，不碰网络，
/// 于是提示词能在单测里断言。与旧仓库 Ledger.kt 里的 `object LedgerPrompt`
/// 同位同名，文案逐字一致。
abstract final class LedgerPrompt {
  /// 输出格式固定，字段名与 [Ledger] 的 JSON 一一对应。最后三条规则是针对
  /// 上一次踩到的坑：模型爱把空字段写成「无」「暂无」，爱把没发生过的事
  /// 「合理推断」出来 —— 而台账是会被当成既定事实注入的，编造就直接变成
  /// 回复里的假记忆。
  static String system() =>
      '你是聊天记录的整理助手。把给到的一段聊天记录整理成一份供后续回复使用的「会话台账」。\n'
      '只输出一个 JSON 对象，不要解释，不要代码块围栏。字段固定为这六个：\n'
      '{"address":"","relation":"","tone":"","threads":[],'
      '"boundaries":[],"terms":[{"term":"","value":""}]}\n'
      '规则：\n'
      '- address（称呼）：双方实际用过的称呼，以及各自怎么自称。\n'
      '- relation（关系）：一句话说清现在是什么关系、进行到哪一步。\n'
      '- tone（语气基线）：一句话说清两人说话的语气、节奏和亲密程度。\n'
      '- threads（在办的事）：还没结束的话题或约定，每条一句话，最多 6 条。\n'
      '- boundaries（边界）：双方明确说过的限制、禁区、安全词、不能碰的话题，最多 6 条。\n'
      '- terms（固定说法）：这一场里约定过的角色名、代号、专有说法；term 是词，'
      'value 是它的含义或用法。最多 12 条。\n'
      '- 只写记录里真实出现过的东西，不要推断、不要补全、不要写泛泛的好话。\n'
      '- 空的内容必须是空字符串或空数组，不要写「无」「暂无」「没有」。\n'
      '- 台账是给回复模型看的，用陈述句，不要写建议、不要写分析、不要评论。';

  /// [previousJson] 上一版台账的 JSON（可为空）。增量更新：模型拿到旧台账
  /// 加新记录，输出**完整**的新台账，旧的线头不会因为滚出窗口而丢。
  static String user(String? previousJson, String transcript) {
    final prev = (previousJson ?? '').trim();
    final sb = StringBuffer()
      ..write(prev.isEmpty
          ? '上一版台账：无（这是第一次整理）\n'
          : '上一版台账（在此基础上补充，不要丢掉仍然有效的条目）：\n$prev\n');
    sb.write('\n本轮要整理的新增聊天记录（越靠下越新）：\n');
    sb.write(transcript.trim());
    sb.write('\n');
    sb.write('\n请输出更新后的完整台账 JSON。');
    return sb.toString();
  }
}
