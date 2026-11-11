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

  /// G3：来源层的中文展示名（采集页/桌面流的快照卡共用一份文案）。
  /// 未知层号原样返回——将来新增层号时不至于在 UI 上显示空白。
  static String labelOf(String provenance) => switch (provenance) {
        a11y => '无障碍',
        ocr => 'OCR',
        inject => '注入',
        desktop => '桌面',
        _ => provenance,
      };
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
    this.confidence = 1.0,
    this.uncertain = const [],
  });

  final String? title;
  final List<Msg> messages;
  final String? note;
  final String provenance;

  /// 这一屏之外能看到的更早消息（注入层/桌面历史源给得出，无障碍给不出）。
  final List<Msg> history;

  /// 通道契约（K/D 双方写死）：采集侧对这一屏「读得多可信」的自评，0.0..1.0。
  /// 口径：provenance==a11y 基线 1.0、ocr 基线 0.6；每条 unknown-speaker 消息
  /// -0.1；title 为空 -0.05；下限 0.2。旧 JSON 没有该字段时按缺省 1.0 处理
  /// （「采集侧没说不可靠」= 自动分析照旧）。app 侧 G3 门控：不高于阈值 0.5
  /// （≤，含 OCR 基线 0.6 恰扣一条 unknown-speaker 的精确 0.5）的快照不自动
  /// 分析，等用户确认后才起轮。
  final double confidence;

  /// 通道契约：置信度扣分的原因标签（如「发言人未知」「标题为空」），可省略。
  /// 展示在快照卡与门控提示上；旧 JSON 无字段时为空表。
  final List<String> uncertain;

  /// 通道契约的 Dart 侧解析：采集服务（CaptureService.snapshotJson）与
  /// manualOcr 事件发来的快照 JSON → [ChatSnapshot]。
  ///
  /// 对旧字段与 capture_android 门面的既有解析逐字段同义（title/note/
  /// provenance/messages），另加 G3 两个字段：`confidence`（数值，缺省 1.0，
  /// 越界值夹回 0.0..1.0）与 `uncertain`（字符串数组，可省略，非字符串项
  /// 丢弃）。旧 JSON 无新字段时解析结果与改前完全一致，不会破。通道没有
  /// history 字段（桌面快照在 Dart 侧直接构造），这里也不读它。
  factory ChatSnapshot.fromJson(Map<String, dynamic> j) => ChatSnapshot(
        title: j['title'] as String?,
        note: j['note'] as String?,
        provenance: j['provenance'] as String? ?? Provenance.a11y,
        messages: (j['messages'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(Msg.fromJson)
            .toList(),
        confidence: ((j['confidence'] as num?)?.toDouble() ?? 1.0)
            .clamp(0.0, 1.0)
            .toDouble(),
        uncertain: [
          for (final u in j['uncertain'] as List<dynamic>? ?? const <dynamic>[])
            if (u is String) u,
        ],
      );

  String? get latestFrom => messages.isEmpty ? null : messages.last.side;

  /// A stable signature of the last few messages, to detect real changes.
  ///
  /// 对齐 Kotlin 的 `takeLast(6)`（不足六条全取）：该方法在 package:collection
  /// 里，core 零依赖，用 skip 等价实现。
  ///
  /// 口径与 capture_android `Model.kt` 的 `ChatSnapshot.signature()` 逐字段
  /// 一致：末 6 条、每条 `side:text`、以 `|` 连接 —— 两端口径一致，允许跨端
  /// 对拍；金样契约测试在两侧钉死同一期望串（core/test/contract_golden_test.dart
  /// ↔ capture_android …/SignatureContractTest.kt）。
  // fix(kimi-review #21)：两端口径注释。实测 Kotlin 侧同为 `|`（Model.kt
  // signature()，git 全历史无 `join('/')`），格式无需改动，互指注释即为修复。
  String signature() {
    final from = messages.length > 6 ? messages.length - 6 : 0;
    return messages.skip(from).map((m) => '${m.side}:${m.text}').join('|');
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
