import 'package:chartools_core/chartools_core.dart';

/// 桌面「粘贴分析」的行解析结果。
class ParsedTranscript {
  const ParsedTranscript({required this.messages, this.unattributed = 0});

  /// 按行解析出的消息（顺序即粘贴顺序，越靠下越新）。
  final List<Msg> messages;

  /// 行首没有 我：/对方： 前缀、无法归属说话人的行数（空行不计）。
  /// 这些行的 side 是 [TranscriptParser.sideUnknown]，UI 与快照 note 要注明。
  final int unattributed;

  bool get isEmpty => messages.isEmpty;
}

/// 把粘贴来的聊天记录按行解析成 [Msg] 列表。
///
/// 行前缀决定 side：`我：`/`我:` → me，`对方：`/`对方:` → other（全半角冒号
/// 都认）。无法识别的行**不归属**——side 用 [sideUnknown]：
///
/// - 旧仓库 OcrGrouping.kt:17-20 的注释原话：「Not "other": an unknown side
///   must stay unknown, or a screen full of my own messages reads as an
///   incoming conversation」——无前缀的行（多行消息的续行、时间戳、系统提示）
///   被硬算成对方会污染判断，所以沿用 OCR 的 SIDE_UNKNOWN 值 `'?'`；
/// - 任何非 me/other 的 side 在下游都渲染成「发言人不明」（models.dart 的
///   [Msg.sideKnown]），判断载荷据此带 sides_unclear=N（jev_questions.dart）。
///
/// 调用方（桌面助手页）负责把 [ParsedTranscript.unattributed] 写进快照 note
/// 并展示给用户。
abstract final class TranscriptParser {
  /// 无法归属说话人时的 side 值，与旧仓库 OcrGrouping.SIDE_UNKNOWN 同值。
  static const String sideUnknown = '?';

  /// Windows 剪贴板常见 \r\n，老 Mac 的裸 \r 也顺带吃掉。
  static final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');

  /// [raw] 按行拆开解析。空行与纯空白行跳过；行先 trim 再认前缀，
  /// 消息正文同样 trim（半角冒号后常跟一个空格）。
  static ParsedTranscript parse(String raw) {
    final messages = <Msg>[];
    var unattributed = 0;
    for (var line in raw.split(_lineBreak)) {
      line = line.trim();
      if (line.isEmpty) continue; // 空行跳过
      if (line.startsWith('我：') || line.startsWith('我:')) {
        messages.add(Msg(side: 'me', text: line.substring(2).trim()));
      } else if (line.startsWith('对方：') || line.startsWith('对方:')) {
        messages.add(Msg(side: 'other', text: line.substring(3).trim()));
      } else {
        unattributed++;
        messages.add(Msg(side: sideUnknown, text: line));
      }
    }
    return ParsedTranscript(messages: messages, unattributed: unattributed);
  }
}
