import 'dart:convert';

/// Pulls the first complete top-level JSON object out of a model's reply text.
///
/// A chat model asked for JSON regularly wraps it in a markdown fence or a
/// sentence ("好的，结果如下：{...}"), so the obvious slice — from the first `{`
/// to the LAST `}` — is wrong: a candidate reply quoted inside the object may
/// itself contain a brace, and that drags the cut past the real end.
///
/// This scans with brace depth instead, ignoring braces that sit inside string
/// literals. Pure string work on purpose, so it is unit-testable without any
/// server round trip.
abstract final class JsonSlice {
  /// The first balanced `{...}` block, or null when the text holds none.
  static String? firstObject(String text) {
    var depth = 0;
    var start = -1;
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final c = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      switch (c) {
        case '"':
          inString = true;
        case '{':
          if (depth == 0) start = i;
          depth++;
        case '}':
          if (depth > 0) {
            depth--;
            if (depth == 0 && start >= 0) return text.substring(start, i + 1);
          }
      }
    }
    return null;
  }
}

/// tolerant JSON decode helpers shared by the judge/review parsers.
T? tryDecode<T>(String raw) {
  try {
    final v = const JsonDecoder().convert(raw);
    if (v is T) return v;
    return null;
  } catch (_) {
    return null;
  }
}
