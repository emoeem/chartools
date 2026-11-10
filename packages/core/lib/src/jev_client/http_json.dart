import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'api_exception.dart';
import 'http_scope.dart';
import 'jsonx.dart';

/// Shared POST-JSON helper: UTF-8 body, exponential backoff on 429/5xx/transport,
/// no retry on other 4xx, and every failure normalized to [ApiException]. Keys
/// are passed in per call and never logged, and are redacted out of error text.
///
/// Runs on `dart:io` [HttpClient] so that an abandoned request can be *cut*
/// (via `abort()`) rather than merely abandoned — one wedged request used to
/// hold its round's thread for good in the Kotlin original.
abstract final class HttpJson {
  static const int maxAttempts = 3;
  static const int connectTimeoutMs = 15 * 1000;
  static const int readTimeoutMs = 40 * 1000;

  /// Backoff between attempts. Mutable so a unit test can collapse the three
  /// attempts from ~1.5 s of sleeping to ~3 ms; production never writes it.
  static int retryBackoffMs = 500;

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: connectTimeoutMs);

  /// One authenticated POST shape every route uses: UTF-8 JSON body, bearer key,
  /// caller extras. Shared with the SSE path so a streaming request cannot drift
  /// from the non-streaming one.
  static Map<String, String> jsonRequestHeaders(
    String key,
    Map<String, String> extraHeaders,
  ) =>
      {
        'Authorization': 'Bearer $key',
        'Content-Type': 'application/json; charset=utf-8',
        ...extraHeaders,
      };

  /// POST 一段 JSON，返回解码后的 JSON 对象。每个 HTTP 或传输层失败都归一成
  /// [ApiException]；[route] 只用于组错误文案。
  static Future<Map<String, dynamic>> post(
    String url,
    String key,
    Map<String, dynamic> body,
    String route, {
    Map<String, String> extraHeaders = const {},
    HttpScope? scope,
  }) async {
    var attempt = 0;
    ApiException? last;
    while (attempt < maxAttempts) {
      if (_isAborted(scope)) throw RequestCancelledException(route);
      try {
        return await _once(url, key, body, route, extraHeaders, scope);
      } on RequestCancelledException {
        rethrow;
      } on ApiException catch (e) {
        if (_isAborted(scope)) throw RequestCancelledException(route);
        // Client errors are final — except 429 (rate limit) and 529
        // (overloaded), which are the two that mean "come back later".
        // 5xx 与传输失败按服务端问题重试。
        final status = e.status;
        if (status != null && status >= 400 && status < 500 && status != 429) {
          throw e;
        }
        last = e;
        attempt++;
        if (attempt < maxAttempts) await _sleep(attempt);
      } catch (e) {
        if (_isAborted(scope)) throw RequestCancelledException(route);
        last = ApiException(route, null, describe(e));
        attempt++;
        if (attempt < maxAttempts) await _sleep(attempt);
      }
    }
    throw last ?? ApiException(route, null, '请求失败');
  }

  /// One Server-Sent-Events round trip (opt-in streaming, off by default).
  ///
  /// Runs until the server closes the stream, a `data: [DONE]` sentinel lands,
  /// an error occurs, or [scope] is cancelled. Returns the concatenated `data:`
  /// payloads; [onData] sees each payload as it lands, which is the whole point
  /// (the card can show text while the model is still writing).
  ///
  /// Deliberately NOT retried: a half-delivered stream that restarts would show
  /// the same sentence twice. The caller falls back to the buffered path instead.
  static Future<String> stream(
    String url,
    String key,
    Map<String, dynamic> body,
    String route, {
    Map<String, String> extraHeaders = const {},
    HttpScope? scope,
    required void Function(String data) onData,
  }) async {
    HttpClientRequest? request;
    final cancel = () => request?.abort(RequestCancelledException(route));
    scope?.attach(cancel);
    try {
      final req = await _client.openUrl('POST', Uri.parse(url));
      request = req;
      // Kotlin 的 `forEach(req.headers::set)` 写法在 Dart 里不存在（`::` 不是
      // Dart 语法）；等价物是实例方法 tear-off `req.headers.set`。
      jsonRequestHeaders(key, extraHeaders).forEach(req.headers.set);
      req.headers.set('Accept', 'text/event-stream');
      req.write(jsonEncode(body));

      final resp = await req.close();
      if (resp.statusCode < 200 || resp.statusCode > 299) {
        final text = await resp.transform(utf8.decoder).join();
        final safeText =
            key.isBlank() ? text : text.replaceAll(key, '[key]');
        throw ApiException(
            route, resp.statusCode, safeText.ifBlank('（响应体为空）'));
      }

      final buffer = StringBuffer();
      // [_ssePayloads] 在 [DONE] 处自己结束事件流，await for 在这里自然走完，
      // 不需要中途 break：中途取消一个正停在底层响应流上的 async* 生成器，
      // 其取消要等到生成器从那个 await 上醒来才完成，客户端就会被不关连接
      // 的服务器拖到超时。流走完后 abort() 把连接收掉，不等服务器关。
      await for (final payload in _ssePayloads(resp)) {
        buffer.write(payload);
        buffer.write('\n');
        onData(payload);
      }
      request.abort(); // 与 Kotlin 的 source.cancel() 对齐：读完即收线。
      return buffer.toString();
    } on RequestCancelledException {
      rethrow;
    } on ApiException {
      rethrow;
    } catch (e) {
      if (_isAborted(scope)) throw RequestCancelledException(route);
      throw ApiException(route, null, describe(e));
    } finally {
      scope?.detach(cancel);
    }
  }

  /// 把一条 SSE 响应体拆成一个个事件负载（多行 data 以 '\n' 连接）。
  ///
  /// 注释行（`: keep-alive` 心跳）与 `data: [DONE]` 都不是事件；读到 [DONE]
  /// 时事件流就地正常结束。这个终止必须发生在生成器内部（return），而不是
  /// 让调用方 break——后者对 async* 生成器是「取消」，要等生成器从底层响应
  /// 流的下一个事件上醒来才完成，服务器不关连接客户端就得干等。
  static Stream<String> _ssePayloads(HttpClientResponse resp) async* {
    final dataLines = <String>[];
    await for (final line
        in resp.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          final payload = dataLines.join('\n');
          dataLines.clear();
          // [DONE] 只是结束哨兵，不作为事件交给调用方。
          if (payload.trim() == '[DONE]') return;
          yield payload;
        }
        continue;
      }
      if (line.startsWith(':')) continue; // SSE 注释/心跳
      if (line.startsWith('data:')) {
        var value = line.substring(5);
        if (value.startsWith(' ')) value = value.substring(1);
        dataLines.add(value);
      }
      // event:/id:/retry: 等字段 OpenAI 兼容流里不承载内容，忽略。
    }
    if (dataLines.isNotEmpty) {
      final payload = dataLines.join('\n');
      // 服务器在 [DONE] 后没有收尾空行就直接关流，同样不上抛哨兵。
      if (payload.trim() != '[DONE]') yield payload;
    }
  }

  /// One attempt. Throws [ApiException] for every HTTP or transport outcome.
  static Future<Map<String, dynamic>> _once(
    String url,
    String key,
    Map<String, dynamic> body,
    String route,
    Map<String, String> extraHeaders,
    HttpScope? scope,
  ) async {
    HttpClientRequest? request;
    final cancel = () => request?.abort(RequestCancelledException(route));
    scope?.attach(cancel);
    Timer? readTimer;
    try {
      final req = await _client.openUrl('POST', Uri.parse(url));
      request = req;
      jsonRequestHeaders(key, extraHeaders).forEach(req.headers.set);
      req.write(jsonEncode(body));

      readTimer = Timer(const Duration(milliseconds: readTimeoutMs), () {
        // 有意为之：缓冲路径有读超时（推理模型的长流式走 stream()，无超时）。
        req.abort(SocketException('Read timed out'));
      });
      final resp = await req.close();
      final code = resp.statusCode;
      final text = await resp.transform(utf8.decoder).join();
      if (code == 429 || code == 529) {
        throw ApiException(route, code, '服务繁忙，已重试');
      }
      // Branch on the status code FIRST: reading the body must never be able to
      // lose it. A truncated or empty error body still has to surface as the
      // real status, otherwise a 401 gets retried as a transport failure.
      if (code < 200 || code > 299) {
        final safeText = key.isBlank() ? text : text.replaceAll(key, '[key]');
        throw ApiException(route, code, safeText.ifBlank('（响应体为空）'));
      }
      if (text.isBlank()) throw ApiException(route, code, '响应体为空');
      final decoded = tryDecodeObject(text);
      if (decoded == null) {
        throw ApiException(route, code, '响应不是 JSON 对象：${text.take(120)}');
      }
      return decoded;
    } finally {
      readTimer?.cancel();
      scope?.detach(cancel);
    }
  }

  static Future<void> _sleep(int attempt) =>
      Future.delayed(Duration(milliseconds: retryBackoffMs << attempt));

  static bool _isAborted(HttpScope? scope) => scope?.isCancelled ?? false;

  /// OpenRouter wants attribution headers; other hosts reject unknown ones
  /// politely.
  static Map<String, String> headersFor(String url) =>
      url.toLowerCase().contains('openrouter.ai')
          ? const {
              'HTTP-Referer': 'https://jev-assistant.local',
              'X-Title': 'Jev Assistant',
            }
          : const {};

  /// Human-readable transport failures (no key material ever appears here).
  static String describe(Object e) {
    final m = '${e.toString()} ${e.runtimeType}';
    return switch (e) {
      SocketException() when m.contains('timed out') =>
        '网络超时，请检查连接',
      SocketException() when m.contains('Failed host lookup') =>
        '域名解析失败，地址填错或无网络',
      SocketException() when m.contains('Connection refused') =>
        '无法连接该地址',
      HandshakeException() => 'HTTPS 证书校验失败',
      _ when m.toLowerCase().contains('timeout') => '网络超时，请检查连接',
      _ when m.contains('Failed host lookup') => '域名解析失败，地址填错或无网络',
      _ when m.contains('Connection refused') => '无法连接该地址',
      _ => e.toString(),
    };
  }
}

extension on String {
  // isBlank 写成方法而不是 getter：本文件里的调用点都是 Kotlin 习惯的
  // `isBlank()`，getter 会被当成 tear-off 之外的属性误用报错。
  bool isBlank() => trim().isEmpty;
  String ifBlank(String fallback) => trim().isEmpty ? fallback : this;
  String take(int n) => length <= n ? this : substring(0, n);
}
