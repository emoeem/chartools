/// 快照与判断结果的领域模型 —— 与旧仓库 `core/ChatModels.kt` 一一对应。
///
/// 采集层（capture_*）产出 [ChatSnapshot]，流水线（pipeline）产出 [Analysis]；
/// UI 层只消费这两个，谁也不越过谁。
library;

/// 一条快照是从哪一层读到的 —— 能力阶梯的层号。
///
/// 存在的理由是**可对拍**：同一个聊天页用不同层读出来的东西必须能逐条比。
/// 每一层都在 Trace 里留一行，降级（注入失败 → 无障碍）不是静默的。
abstract final class Provenance {
  /// L0：无障碍节点树。默认路径，任何手机上都在。
  static const a11y = 'a11y';

  /// L0'：截屏 + OCR。树里读不到正文时用（微信/飞书自己画字）。
  static const ocr = 'ocr';

  /// L1：注入层直接读到的会话数据。**可选**，默认关。
  static const inject = 'inject';

  /// 桌面端（Windows）的采集来源，标记在快照上以便对拍与排错。
  static const desktop = 'desktop';
}

/// One captured chat bubble. side is "me" (right) or "other" (left);
/// anything else reads as "发言人不明" downstream.
///
/// [id] / [at] / [sender] 只有注入层填得出来（无障碍节点树不提供消息身份，OCR
/// 更不提供）。默认值让 L0 路径一个字都不用改。
class Msg {
  const Msg({
    required this.side,
    required this.text,
    this.id,
    this.at = 0,
    this.sender,
  });

  final String side;
  final String text;
  final String? id;
  final int at;
  final String? sender;

  /// A side the capture step could not read is neither "me" nor "other".
  bool get sideKnown => side == 'me' || side == 'other';

  Map<String, dynamic> toJson() => {
    'side': side,
    'text': text,
    if (id != null) 'id': id,
    if (at != 0) 'at': at,
    if (sender != null) 'sender': sender,
  };

  factory Msg.fromJson(Map<String, dynamic> j) => Msg(
    side: j['side'] as String? ?? '',
    text: j['text'] as String? ?? '',
    id: j['id'] as String?,
    at: (j['at'] as num?)?.toInt() ?? 0,
    sender: j['sender'] as String?,
  );
}

/// A snapshot of the currently-open conversation in whichever app is
/// foreground (see the capture adapters).
///
/// Adapter contract: `extract` returning null means "not in a chat window".
/// Returning a snapshot whose [messages] is empty means "in a chat window, but
/// nothing could be read" — that is the OCR fallback's cue.
///
/// [note] is a caveat about how this snapshot was produced, shown verbatim in
/// the analysis panel (OCR captures cannot tell who said what).
class ChatSnapshot {
  const ChatSnapshot({
    this.title,
    this.messages = const [],
    this.note,
    this.provenance = Provenance.a11y,
    this.history = const [],
  });

  final String? title;
  final List<Msg> messages;
  final String? note;
  final String provenance;

  /// 这一屏之外能看到的更早消息（注入层/桌面历史源给得出，无障碍给不出）。
  final List<Msg> history;

  String? get latestFrom => messages.isEmpty ? null : messages.last.side;

  /// A stable signature of the last few messages, to detect real changes.
  ///
  /// 对齐 Kotlin 的 `takeLast(6)`（不足六条全取）：该方法在 package:collection
  /// 里，core 零依赖，用 skip 等价实现。
  String signature() {
    final from = messages.length > 6 ? messages.length - 6 : 0;
    return messages
        .skip(from)
        .map((m) => '${m.side}:${m.text}')
        .join('|');
  }
}

/// Jev's judgment result for one snapshot, plus the ranked candidate replies.
class Analysis {
  const Analysis({
    this.trueIntent,
    this.dangerLevel,
    this.sheNeeds,
    this.shouldReplyNow,
    this.bestAction,
    this.tensionResolved,
    this.literalQuestion,
    this.rankedReplies = const [],
    required this.latencyMs,
    this.error,
  });

  final Choice? trueIntent;
  final Score? dangerLevel;
  final Choice? sheNeeds;
  final double? shouldReplyNow;
  final Choice? bestAction;
  final double? tensionResolved;
  final double? literalQuestion;
  final List<RankedReply> rankedReplies;
  final int latencyMs;
  final String? error;

  Analysis copyWith({
    Choice? trueIntent,
    Score? dangerLevel,
    Choice? sheNeeds,
    double? shouldReplyNow,
    Choice? bestAction,
    double? tensionResolved,
    double? literalQuestion,
    List<RankedReply>? rankedReplies,
    int? latencyMs,
    String? error,
    bool clearError = false,
  }) =>
      Analysis(
        trueIntent: trueIntent ?? this.trueIntent,
        dangerLevel: dangerLevel ?? this.dangerLevel,
        sheNeeds: sheNeeds ?? this.sheNeeds,
        shouldReplyNow: shouldReplyNow ?? this.shouldReplyNow,
        bestAction: bestAction ?? this.bestAction,
        tensionResolved: tensionResolved ?? this.tensionResolved,
        literalQuestion: literalQuestion ?? this.literalQuestion,
        rankedReplies: rankedReplies ?? this.rankedReplies,
        latencyMs: latencyMs ?? this.latencyMs,
        error: clearError ? null : (error ?? this.error),
      );
}

class Choice {
  const Choice({
    required this.choice,
    required this.confidence,
    this.probabilities = const {},
  });

  final String choice;
  final double confidence;
  final Map<String, double> probabilities;
}

class Score {
  const Score({
    required this.score,
    required this.confidence,
    required this.maxLevel,
  });

  final double score;
  final double confidence;
  final int maxLevel;
}

class RankedReply {
  const RankedReply({
    required this.text,
    this.prob = 0.0,
    this.strategy = '',
    this.ranked = true,
    this.reviewNote = '',
  });

  final String text;
  final double prob;
  final String strategy;
  final bool ranked;

  /// S1 证据复查给出的理由：这条是从原候选重写来的，以及当初为什么站不住。
  /// 复查没开时永远是空串。
  final String reviewNote;

  RankedReply copyWith({
    String? text,
    double? prob,
    String? strategy,
    bool? ranked,
    String? reviewNote,
  }) =>
      RankedReply(
        text: text ?? this.text,
        prob: prob ?? this.prob,
        strategy: strategy ?? this.strategy,
        ranked: ranked ?? this.ranked,
        reviewNote: reviewNote ?? this.reviewNote,
      );
}
