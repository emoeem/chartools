/// Carries the route, the HTTP status (null = transport failure) and the first
/// 120 chars of the response body so the settings page can show the real reason.
class ApiException implements Exception {
  ApiException(this.route, this.status, this.snippet)
      : message = buildMessage(route, status, snippet);

  final String route;
  final int? status;
  final String snippet;
  final String message;

  static String buildMessage(String route, int? status, String snippet) =>
      status != null
          ? '$route HTTP $status：${snippet.take(120)}'
          : '$route 请求失败：${snippet.take(120)}';

  @override
  String toString() => message;
}

/// Kotlin `String.take(n)` 的等价物：前 n 个字符，长度不足时全取。
extension on String {
  String take(int n) => length <= n ? this : substring(0, n);
}

/// [SafetyGate] 拦下一轮时抛出，而不是调用模型。调用方把 [message] 原样展示：
/// 「没有候选」但不给原因是区分不出网络故障的，用户必须能看出是助手主动拒绝。
class SafetyBlockedException implements Exception {
  SafetyBlockedException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 取消一种请求时抛出的轻量异常：不是失败，不值得重试或上报。
class RequestCancelledException implements Exception {
  RequestCancelledException(this.route);
  final String route;

  @override
  String toString() => '$route 请求已取消';
}
