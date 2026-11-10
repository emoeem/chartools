import 'json_slice.dart';

/// Makes an opt-in streaming reply watchable.
///
/// Two shapes have to be unwrapped before a human sees anything:
///
/// 1. **Transport.** Each SSE `data:` payload is an OpenAI-style envelope —
///    `{"choices":[{"delta":{"content":"你"}}]}` — so [delta] pulls the sentence
///    fragment out of it. DashScope's compatible mode and DeepSeek both use this
///    shape; a payload carrying no content (the final `finish_reason` chunk)
///    yields null so the caller does not have to special-case it.
/// 2. **Format.** The reply prompt asks for a JSON array of
///    `{"strategy":"safe","text":"…"}` objects, so the *accumulated* text is
///    JSON. Showing that verbatim would put `[{"strategy":"safe","text":"` on
///    the card, so [visible] returns just the `text` values, decoded, as plain
///    text.
///
/// Both run on every partial chunk, so both must tolerate input that stops in
/// the middle of a string, an escape sequence or a key name. Neither throws — a
/// half-finished sentence on the card beats a crash in the middle of a reply.
abstract final class StreamText {
  /// The content fragment in one SSE payload, or null when the chunk carries none.
  static String? delta(String data) {
    final trimmed = data.trim();
    if (trimmed.isEmpty) return null;
    final obj = tryDecode<Map<String, dynamic>>(trimmed);
    if (obj == null) return null;
    final choices = obj['choices'];
    if (choices is! List<dynamic> || choices.isEmpty) return null;
    final first = choices.first;
    if (first is! Map<String, dynamic>) return null;
    final delta = (first['delta'] ?? first['message']);
    if (delta is! Map<String, dynamic>) return null;
    final content = delta['content'];
    if (content is String && content.isNotEmpty) return content;
    return null;
  }

  /// The readable part of an accumulated (possibly incomplete) reply: every
  /// `"text"` value found so far, on its own line.
  ///
  /// Falls back to the raw text when no `"text"` field has appeared yet, so a
  /// model that ignores the JSON format and streams prose still previews.
  static String visible(String raw) {
    final parts = <String>[];
    var i = 0;
    var sawTextField = false;
    while (true) {
      final key = raw.indexOf('"text"', i);
      if (key < 0) break;
      final colon = raw.indexOf(':', key + 6);
      if (colon < 0) break;
      var q = colon + 1;
      while (q < raw.length && _isWhitespace(raw.codeUnitAt(q))) {
        q++;
      }
      if (q >= raw.length || raw[q] != '"') {
        i = colon + 1;
        continue;
      }
      sawTextField = true;
      final r = _readString(raw, q + 1);
      if (r.text.isNotEmpty) parts.add(r.text);
      if (!r.closed) break;
      i = r.next;
    }
    if (sawTextField) return parts.join('\n');
    // 对齐 Kotlin 的两步回退（StreamText.kt:66-67）：先 substringAfter 第一个
    // '['（没有就原样），再剥掉残留的 JSON 脚手架字符，散文原样通过。
    final bracket = raw.indexOf('[');
    final afterBracket = bracket < 0 ? raw : raw.substring(bracket + 1);
    return _trimStartChars(
      afterBracket,
      const {' ', '\n', '\r', '\t', '{', '"', ',', '[', ']'},
    );
  }

  /// dart:core 的 [String.trimLeft] 只认空白；这里要对齐 Kotlin `trimStart` 的
  /// 「按字符集合剥前缀」语义，剥到第一个不在集合里的字符为止。
  static String _trimStartChars(String raw, Set<String> chars) {
    var i = 0;
    while (i < raw.length && chars.contains(raw[i])) {
      i++;
    }
    return raw.substring(i);
  }

  static bool _isWhitespace(int code) =>
      code == 0x20 || code == 0x09 || code == 0x0A || code == 0x0D;

  /// Reads one JSON string body starting after its opening quote.
  /// Returns the decoded text, where scanning stopped, and whether it was closed.
  static _StringRead _readString(String raw, int from) {
    final sb = StringBuffer();
    var j = from;
    while (j < raw.length) {
      final c = raw[j];
      if (c == '"') return _StringRead(sb.toString(), j + 1, true);
      if (c != r'\') {
        sb.write(c);
        j++;
        continue;
      }
      // A trailing lone backslash means the escape has not arrived yet.
      if (j + 1 >= raw.length) break;
      final e = raw[j + 1];
      switch (e) {
        case 'n':
          sb.write('\n');
        case 't':
          sb.write('\t');
        case 'r':
          sb.write('\r');
        case 'b':
          sb.write('\b');
        case 'f':
          sb.write('\x0C');
        case '"':
          sb.write('"');
        case r'\':
          sb.write(r'\');
        case '/':
          sb.write('/');
        case 'u':
          if (j + 6 > raw.length) return _StringRead(sb.toString(), raw.length, false);
          final code = int.tryParse(raw.substring(j + 2, j + 6), radix: 16);
          if (code == null) return _StringRead(sb.toString(), raw.length, false);
          sb.write(String.fromCharCode(code));
          j += 6;
          continue;
        default:
          sb.write(e);
      }
      j += 2;
    }
    return _StringRead(sb.toString(), raw.length, false);
  }
}

class _StringRead {
  const _StringRead(this.text, this.next, this.closed);
  final String text;
  final int next;
  final bool closed;
}
