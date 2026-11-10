/// `org.json` 风格的容错读取助手。
///
/// 模型返回的 JSON 不可信：字段可能缺失、类型可能不对（score 给成字符串、
/// confidence 省略）。这里把「读取并且宽容」集中成一个文件，上层解析代码
/// 才能保持和旧仓库逐条对应的形状。
library;

import 'dart:convert';

/// 读取一个字符串值；数字/布尔按文本读，缺失返回空串（`optString` 语义）。
String optString(Map<String, dynamic>? m, String key, [String fallback = '']) {
  if (m == null) return fallback;
  final v = m[key];
  if (v == null) return fallback;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return fallback;
}

/// 读取一个 double；字符串能转则转，缺失返回 [fallback]（`optDouble` 语义）。
double optDouble(Map<String, dynamic>? m, String key, [double fallback = 0.0]) {
  if (m == null) return fallback;
  final v = m[key];
  if (v == null) return fallback;
  if (v is num) return v.toDouble();
  if (v is String) {
    final d = double.tryParse(v.trim());
    if (d != null) return d;
  }
  if (v is bool) return v ? 1.0 : 0.0;
  return fallback;
}

/// 读取一个 int；字符串能转则转，缺失返回 [fallback]。
int optInt(Map<String, dynamic>? m, String key, [int fallback = 0]) {
  if (m == null) return fallback;
  final v = m[key];
  if (v == null) return fallback;
  if (v is num) return v.toInt();
  if (v is String) {
    final i = int.tryParse(v.trim());
    if (i != null) return i;
  }
  return fallback;
}

/// 读取一个布尔；缺失返回 [fallback]（`optBoolean` 语义）。
bool optBool(Map<String, dynamic>? m, String key, [bool fallback = false]) {
  if (m == null) return fallback;
  final v = m[key];
  if (v == null) return fallback;
  if (v is bool) return v;
  if (v is String) {
    final s = v.trim().toLowerCase();
    if (s == 'true' || s == 'yes' || s == '1') return true;
    if (s == 'false' || s == 'no' || s == '0') return false;
  }
  return fallback;
}

Map<String, dynamic>? optMap(Map<String, dynamic>? m, String key) {
  final v = m?[key];
  return v is Map<String, dynamic> ? v : null;
}

List<dynamic>? optList(Map<String, dynamic>? m, String key) {
  final v = m?[key];
  return v is List<dynamic> ? v : null;
}

/// JSON 数组里的对象按 [Map<String, dynamic>] 读；坏元素跳过。
Map<String, dynamic>? optMapAt(List<dynamic>? list, int index) {
  if (list == null || index < 0 || index >= list.length) return null;
  final v = list[index];
  return v is Map<String, dynamic> ? v : null;
}

/// 大小写不敏感地取一个键（模型爱把 `choice` 写成 `Choice`）。
dynamic optAnyKey(Map<String, dynamic> m, String key) {
  if (m.containsKey(key)) return m[key];
  for (final k in m.keys) {
    if (k.toLowerCase() == key.toLowerCase()) return m[k];
  }
  return null;
}

/// 大小写不敏感地在字符串键的 map 里找 [key]，返回规范化后的真键；找不到返回 null。
String? findKeyCI(Map<String, dynamic> m, String key) {
  if (m.containsKey(key)) return key;
  for (final k in m.keys) {
    if (k.toLowerCase() == key.toLowerCase()) return k;
  }
  return null;
}

/// 把任意 JSON 值转成可遍历的 Map（顶层必须是对象），失败返回 null。
/// 语义与旧仓库 `JSONObject(text)` 的 catch 分支一致：不可解析就是「没有」。
Map<String, dynamic>? tryDecodeObject(String raw) {
  try {
    final v = const JsonDecoder().convert(raw);
    return v is Map<String, dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}

/// 把任意 JSON 值转成可遍历的 List（顶层必须是数组），失败返回 null。
List<dynamic>? tryDecodeList(String raw) {
  try {
    final v = const JsonDecoder().convert(raw);
    return v is List<dynamic> ? v : null;
  } catch (_) {
    return null;
  }
}
